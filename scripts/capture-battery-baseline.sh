#!/usr/bin/env bash
set -euo pipefail

duration=185
output="benchmarks/issue-8/baseline-host.json"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --duration) duration="$2"; shift 2 ;;
        --output) output="$2"; shift 2 ;;
        *) echo "Unknown argument: $1" >&2; exit 2 ;;
    esac
done

mkdir -p "$(dirname "$output")"

echo "Running deterministic release benchmarks..."
swift build -c release --build-tests -Xswiftc -enable-testing
test_bundle="$(swift build -c release --show-bin-path)/RashunPackageTests.xctest"
xcrun xctest -XCTest RashunCoreTests.BatteryPerformanceBaselineTests "$test_bundle" 2>&1 \
    | tee "${output%.json}-xctest.log"

echo "Capturing the installed Rashun process for ${duration}s..."
python3 - "$duration" "$output" <<'PY'
import json
import plistlib
import statistics
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

duration = int(sys.argv[1])
output = Path(sys.argv[2])
home = Path.home()
support = home / "Library/Application Support/Rashun"
preferences_path = home / "Library/Preferences/com.alexanderheffernan.rashun.plist"

def command(*args):
    return subprocess.check_output(args, text=True).strip()

def parse_cpu_time(value):
    days = 0
    if "-" in value:
        day_text, value = value.split("-", 1)
        days = int(day_text)
    parts = value.split(":")
    if len(parts) == 3:
        hours, minutes, seconds = parts
    else:
        hours, minutes, seconds = 0, parts[0], parts[1]
    return days * 86400 + int(hours) * 3600 + int(minutes) * 60 + float(seconds)

def process_sample(pid):
    line = command("ps", "-p", str(pid), "-o", "time=", "-o", "rss=", "-o", "%cpu=")
    cpu_time, rss, cpu_percent = line.split()
    return {
        "monotonic_seconds": time.monotonic(),
        "cpu_seconds": parse_cpu_time(cpu_time),
        "rss_bytes": int(rss) * 1024,
        "cpu_percent": float(cpu_percent),
    }

def file_state(path):
    try:
        stat = path.stat()
        return (stat.st_mtime_ns, stat.st_size)
    except FileNotFoundError:
        return None

pid_text = command("pgrep", "-x", "Rashun").splitlines()[0]
pid = int(pid_text)
preferences = plistlib.load(preferences_path.open("rb"))

def decoded_preference(key, default=None):
    value = preferences.get(key, default)
    if isinstance(value, bytes):
        return json.loads(value)
    return value

codex_files = sorted(
    (path for path in (home / ".codex/sessions").rglob("*.jsonl")),
    key=lambda path: path.stat().st_mtime,
    reverse=True,
)[:20]
history_path = support / "ai.notificationHistory.v1.json"
history = json.loads(history_path.read_text())
tracked_path = support / "trackedUsage.v1.json"
tracked = json.loads(tracked_path.read_text()) if tracked_path.exists() else {}

watched = {
    "history": history_path,
    "history_sync_metadata": support / "ai.notificationHistory.sync.v1.json",
    "source_health": support / "ai.sourceHealth.v1.json",
    "sync_state": support / "sync-state.json",
}
previous_states = {name: file_state(path) for name, path in watched.items()}
changes = {name: [] for name in watched}
samples = []
started_at = datetime.now(timezone.utc)
deadline = time.monotonic() + duration
while time.monotonic() < deadline:
    samples.append(process_sample(pid))
    for name, path in watched.items():
        state = file_state(path)
        if state != previous_states[name]:
            changes[name].append({
                "elapsed_seconds": round(time.monotonic() - samples[0]["monotonic_seconds"], 3),
                "bytes": state[1] if state else None,
            })
            previous_states[name] = state
    time.sleep(1)
samples.append(process_sample(pid))

elapsed = samples[-1]["monotonic_seconds"] - samples[0]["monotonic_seconds"]
cpu_delta = samples[-1]["cpu_seconds"] - samples[0]["cpu_seconds"]
result = {
    "schema_version": 1,
    "captured_at_utc": started_at.isoformat(),
    "git_commit": command("git", "rev-parse", "HEAD"),
    "host": {
        "product_version": command("sw_vers", "-productVersion"),
        "build_version": command("sw_vers", "-buildVersion"),
        "model": command("sysctl", "-n", "hw.model"),
        "cpu": command("sysctl", "-n", "machdep.cpu.brand_string"),
        "memory_bytes": int(command("sysctl", "-n", "hw.memsize")),
        "power_source": command("pmset", "-g", "batt").splitlines()[0],
    },
    "app": {
        "path": "/Applications/Rashun.app",
        "version": command(
            "/usr/libexec/PlistBuddy", "-c", "Print :CFBundleShortVersionString",
            "/Applications/Rashun.app/Contents/Info.plist"
        ),
        "pid": pid,
        "poll_interval_seconds": decoded_preference("ai.pollIntervalSeconds.v1"),
        "sync_interval_seconds": decoded_preference("ai.syncIntervalSeconds.v1"),
        "sync_enabled": bool(decoded_preference("ai.syncServerEnabled.v1", False)),
        "tracking_enabled": bool(decoded_preference("ai.trackingEnabled.v1", False)),
        "active_tracking_session": "activeSession" in tracked,
        "enabled_sources": sorted(
            name for name, enabled in decoded_preference("ai.sourceSettings.v1", {}).items()
            if enabled
        ),
        "enabled_metrics": {
            source: sorted(name for name, enabled in metrics.items() if enabled)
            for source, metrics in decoded_preference("ai.sourceMetricSettings.v1", {}).items()
            if any(metrics.values())
        },
    },
    "fixture_exposure": {
        "history_snapshot_count": sum(len(items) for items in history.values()),
        "history_source_count": len(history),
        "history_bytes": history_path.stat().st_size,
        "codex_newest_20_session_file_count": len(codex_files),
        "codex_newest_20_session_bytes": sum(path.stat().st_size for path in codex_files),
        "tracking_timer_interval_seconds": 0.12,
        "tracking_timer_fires_per_hour_when_active": 30000,
        "failed_sync_retry_schedule_seconds": [15, 30, 60, 120, 120],
    },
    "observation": {
        "elapsed_seconds": round(elapsed, 3),
        "process_cpu_seconds_delta": round(cpu_delta, 3),
        "process_average_cpu_percent": round(cpu_delta / elapsed * 100, 4),
        "sampled_cpu_percent_median": statistics.median(s["cpu_percent"] for s in samples),
        "sampled_cpu_percent_max": max(s["cpu_percent"] for s in samples),
        "rss_bytes_median": int(statistics.median(s["rss_bytes"] for s in samples)),
        "rss_bytes_max": max(s["rss_bytes"] for s in samples),
        "file_changes": changes,
    },
    "limitations": [
        "Capture observes the installed app and does not mutate or copy user data.",
        "Host was on AC power; results characterize CPU and file activity, not battery drain.",
        "powermetrics process-coalition data is unavailable without interactive sudo.",
        "Codex bytes are the source-defined maximum scan set, not kernel-measured read bytes.",
        "Timer and retry rates are deterministic values derived from current source constants.",
    ],
}
output.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
print(f"Wrote {output}")
PY
