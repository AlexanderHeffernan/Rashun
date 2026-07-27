# Issue #8 battery-performance baseline

This stage establishes the pre-optimization benchmark for candidates A, B, C, E, and I. It intentionally changes no application behavior.

## Reproduction

Branch and worktree:

```text
branch: issue-8-benchmark-baseline
worktree: /Users/alexanderheffernan/Documents/MyDocuments/Coding/AppDev/Rashun-issue8-baseline
baseline commit: 6176e0fedc6113b5c3d3a388cf1398d294ce2b26
```

Run the complete release fixture benchmark and host observation:

```bash
bash scripts/capture-battery-baseline.sh \
  --duration 185 \
  --output benchmarks/issue-8/baseline-host.json
```

The script builds tests with optimizations and testable imports, runs only the deterministic battery fixtures through `xctest`, and then observes the already-running installed app without changing its data or preferences:

```bash
swift build -c release --build-tests -Xswiftc -enable-testing
xcrun xctest \
  -XCTest RashunCoreTests.BatteryPerformanceBaselineTests \
  .build/arm64-apple-macosx/release/RashunPackageTests.xctest
```

`swift test -c release --filter BatteryPerformanceBaselineTests` was also attempted. The selected tests passed, but Swift 6.3 subsequently forwarded its `--test-bundle-path` runner option to the Rashun CLI and exited 1. Direct `xctest` avoids that unrelated runner/toolchain interaction.

## Environment and settings

Captured 2026-07-27 11:25 UTC:

- MacBookPro18,3, Apple M1 Pro, 16 GiB RAM
- macOS 26.5.2 (25F84), Swift 6.3.3, Xcode 26.6
- AC power, Low Power Mode off
- Installed app `/Applications/Rashun.app`, version 1.1.1
- AMP and Codex enabled; Codex Pro Weekly is the only enabled Codex metric
- Poll interval 60 seconds
- Sync enabled with a configured 1,200-second interval
- Tracking enabled, but no tracking session active during this capture
- Live history at capture start: 24,632 snapshots across 16 scopes, 2,790,847 bytes

The full sanitized settings and host metadata are in `benchmarks/issue-8/baseline-host.json`. No credentials, peer URLs, session contents, or history contents are captured.

## Baseline results

### A — fetch only enabled metrics

The disabled `codex-free-weekly` path examines the newest 20 Codex JSONL files. On this runner that set is **56,258,396 bytes (53.7 MiB)**. The current app fetch loop calls all three Codex metrics even though only `codex-pro-weekly` is enabled, so this is the pre-A scan exposure per refresh. This value is calculated from the exact file set selected by `CodexSource.newestSessionFiles`; it is not a kernel-level byte-read counter.

Acceptance comparison after A: with Free Weekly disabled, the scan set and actual Codex session-log reads should both be zero.

### B — batch history persistence

Deterministic 24,630-snapshot fixture, two enabled metric appends:

| Metric | Baseline |
| --- | ---: |
| Fixture encoded bytes | 1,547,057 |
| History persistence transactions | 2 |
| History bytes passed to backend | 3,094,367 |
| Sync-metadata persistence transactions | 2 |
| Sync-metadata bytes passed to backend | 337 |
| Total elapsed time | 421 ms |

The live 185-second observation also recorded **7 history replacements** and **7 history-sync-metadata replacements**, clustered as an initial in-progress refresh followed by paired writes around each 60-second poll boundary. Source health was replaced **6 times** (two writes around each of three complete boundaries).

Acceptance comparison after B: one history persistence transaction per completed refresh, one sync revision covering the complete changed-source set, and at least 90% fewer history bytes written for the same fixture.

### C — optimize and cache forecasting

The deterministic fixture has 1,500 points over 90 days. Each sample invokes the three independently used smart-mode consumers: forecast, pacing assessment, and pace guide.

```text
sample_ms=94,83,83,83,83
median_ms=83
```

Acceptance comparison after C: run this unchanged fixture in release mode, retain output-equivalence tests, and compare the median of five samples. The benchmark intentionally includes repeated profile construction because that is the current behavior to eliminate.

### E — fix synchronization retry behavior

`sync-state.json` changed at 17.448 and 137.068 seconds in the live observation: **119.620 seconds apart**, despite the configured 1,200-second sync interval. This matches the current failed-sync retry ceiling. The exact source-defined failure delays are 15, 30, 60, 120, then 120 seconds repeatedly.

Acceptance comparison after E: an unreachable peer must not continue writing/attempting every approximately 120 seconds when the configured cadence is 1,200 seconds.

### I — remove the 8.3 Hz tracking timer

The current timer interval is 0.12 seconds, deterministically **30,000 timer fires per tracked hour**. There was no active tracking session during the live capture, so this report does not claim a measured wakeup count.

Acceptance comparison after I: a static indicator should produce zero recurring tracking-animation timer fires; any retained animation must document and benchmark its lower frequency.

### Whole-process observation

Over 185.064 seconds, the installed app consumed **14.13 process CPU seconds** (**7.6352% of one core on average**). Sampled CPU was 0.4% median and 105.2% maximum, consistent with low activity between bursty refresh work. Median RSS was 195.4 MiB and maximum RSS was 209.1 MiB.

This aggregate includes polling, sync retries, networking, and any UI/background work. The observation started near a refresh boundary and is not a clean per-refresh CPU measurement; use it as the same-scenario whole-process comparison after changes, not as attribution to one candidate.

## Limitations

- The host was on AC power. These results characterize CPU, file activity, deterministic timer/retry frequency, and I/O exposure rather than battery discharge.
- `/usr/bin/powermetrics` is installed, but process-coalition sampling requires interactive sudo and was unavailable to this noninteractive run.
- The installed app was observed in place to preserve its real 24K-snapshot workload. The script reads metadata and file stats only; it does not modify or copy user data.
- Network responses and peer availability are not controlled in the live observation. The release fixtures are deterministic, but the whole-process result is not.
- One 185-second live window was captured. Repeat at least three alternating baseline/candidate windows and compare medians before making battery-impact claims.
- Candidate I was inactive. Capture an explicit tracked-session scenario later if wakeup instrumentation or privileged Instruments access is available.

## Recommended next step

Review and commit this baseline independently. Then implement **A only**, rerun the same command and settings, and verify zero Codex session-log scan exposure while Free Weekly remains disabled. Proceed in attributable increments B, C, E, then I, preserving this fixture and adding output-equivalence checks where behavior could change.

## Implemented comparison

The attributable A, B, C, E, and I commits were measured with the same optimized fixture bundle. Raw results are in `benchmarks/issue-8/after-optimized-xctest.log`.

| Candidate | Before | After | Result type |
| --- | ---: | ---: | ---: |
| A: fetched Codex metric IDs when only weekly is selected | 3 | 1 | Deterministic call-count reduction |
| A: modeled Free Weekly scan-set exposure | 56,258,396 bytes | 0 bytes | Source-derived, not measured file reads |
| B: history transactions / two-metric fixture | 2 | 1 | Measured fixture reduction: 50% |
| B: history bytes passed to backend | 3,094,367 | 1,547,242 | Measured fixture reduction: 50.0% |
| B: fixture persistence elapsed | 421 ms | 66 ms | Single-run observation; no percentage claim |
| C: three forecast consumers, median | 83 ms | 68 ms | Measured fixture reduction: 18.1% |
| E: steady failed-sync cadence with 1,200s setting | 120s | 1,200s | Source-derived: 90% fewer steady attempts |
| I: tracking animation timer fires/hour | 30,000 | 0 | Source-derived timer elimination, not measured wakeups |

Existing forecast behavior tests pass, and the 1,500-point Issue #8 fixture now checks forecast, pacing-assessment, and pace-guide outputs against values captured from the baseline implementation. C computes each point's cumulative active-time offset once for OLS, Theil–Sen, and weighted interval rates, and the app caches a metric's pacing status within the current minute/refresh. B also reuses the already-encoded sorted history bytes for its checksum instead of encoding the entire history a second time.

These are operation-count and release-fixture results, not battery-life or end-to-end process measurements. In particular, A's bytes are a modeled maximum candidate file set, E and I are derived from source-defined cadence/timer removal, and B's elapsed value is only a single before/after observation. Only B's fixture write count/bytes and C's recorded fixture median support measured percentage-reduction wording.

The candidate app was not installed over the user's running 1.1.1 app, so no candidate whole-process live window was captured. That preserves the no-real-data-mutation constraint and means the 7.6352%-of-one-core live baseline must be repeated manually after installing a review build before making an end-to-end energy claim.
