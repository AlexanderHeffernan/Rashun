# Issue #15 — Core-backed CLI tracking

## Review scope

This branch adds `rashun tracking start|stop|status|sessions|labels`. `start` accepts an existing, unarchived label by exact case-insensitive name or UUID; it never creates a label and fails when another session is active. `stop` persists the session even when no observations were captured.

The app and CLI use the same `trackedUsage.v1.json` Core payload. Core mutations reload and atomically update that payload under a sidecar interprocess lock. POSIX platforms use `flock` with deliberate `EINTR` retries; Windows uses `LockFileEx`. Directory creation, lock open, and lock acquisition are mandatory, so mutations never continue unlocked. Store reads refresh from disk so either process observes the other's latest state.

## Remediation completed

- App boundary refreshes append only to the session UUID that initiated them, and stop completes only that UUID. A stale app task cannot append to or stop a CLI replacement session.
- Malformed JSON and schema versions newer than v2 fail closed for reads, mutations, CLI commands, and sync. Existing durable bytes are not replaced or downgraded.
- Backend reads and mutations throw. Encoding, read, directory, lock, atomic write, and removal failures propagate; the tracked store updates its in-memory payload only after the backend commits.
- Active label names are unique under case-insensitive comparison for create, rename, unarchive, and sync merge. Legacy ambiguous names produce an explicit CLI error.
- A shared active session is authoritative for app observation collection even when the app tracking toggle is off. CLI `start` is independent of that toggle.
- App tracking views surface persistence failures inline. Background/menu refresh failures are logged and do not report a failed boundary as completed.

## Automated verification

```sh
swift test --filter 'TrackedUsageTests|CLIParsingTests|PersistenceMigrationSafetyTests|TrackedUsageAppPolicyTests'
# 62 tests, 0 failures

swift test
# 282 tests, 0 failures

./build.sh --test
# 282 tests, 0 failures

swift build -c release --product RashunCLI
# succeeded

swift build -c release --product Rashun
# succeeded

git diff --check
# clean
```

Focused coverage includes deterministic replacement-session append/stop races, stop-boundary failure ordering, exact malformed/future-schema byte preservation, read/write/encode/directory/lock failures, case-insensitive duplicate labels, CLI exit codes and JSON error codes, toggle-independent shared-session collection, in-process concurrent writers, and a real Python child process holding the sidecar lock.

## Manual app/CLI interoperability review

1. In Rashun **Settings → Tracking**, create a label named `Review`.
2. Run `swift run RashunCLI tracking labels` and confirm `Review` and its UUID appear.
3. Run `swift run RashunCLI tracking start Review`, then `swift run RashunCLI tracking status`.
4. Confirm the running app shows the same active label. Attempt a second `start` and confirm it exits with an error.
5. Let the app refresh once, run `swift run RashunCLI tracking stop`, and confirm the app stops tracking.
6. Run `swift run RashunCLI tracking sessions` and confirm the completed session appears.
7. Repeat representative commands with `--json` before the subcommand (for example `swift run RashunCLI --json tracking status`) and verify stable JSON output. An installed build uses the command name `rashun` instead.

## Limitations

- The running app observes external state when it next reads or mutates the Core store; no cross-process push notification was added.
- CLI `start` controls shared tracking state; usage observations still require the running app's normal refresh loop.
- The real child-process contention test uses macOS system Python and is skipped when that executable is unavailable. Windows `LockFileEx` is compile-time isolated and was not executable in this macOS review environment.
- Background tracking persistence failures are logged; tracking management views show inline errors, but the menu-bar app does not present a modal alert.

## Recommendation

**Approve after remediation.** The four objective durability/race blockers and both product decisions are implemented and covered. No known fix is required before review.
