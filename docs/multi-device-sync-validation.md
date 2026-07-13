# Multi-device sync validation record

This file distinguishes implementation evidence from physical-platform release gates. It does not treat an unavailable device test as a pass.

## Automated evidence

| Requirement | Evidence |
|---|---|
| Stable device, epoch, series, observation identity and canonical validation | `Models.swift`; `SyncRepositoryTests` validation, persistence, dedupe and conflict cases |
| Transactional sequence allocation and concurrent-safe persistence | GRDB `DatabasePool` in WAL mode; allocation and insert share one write transaction; reopen and 1,201-record tests |
| Safe legacy migration | Content-addressed backup, deterministic UUIDv5-style IDs, alias registry, quarantine, atomic journal transaction, retry/rollback/corruption tests |
| Deterministic projection | Total ordering and first/last plateau projection; order-independence test; display cap does not delete canonical observations |
| Canonical import/export | Schema 2 round trip, duplicate-safe reimport, schema 1 compatibility test |
| Authenticated sync | HMAC-SHA-256 method/path/body/ID/time/nonce signing; durable replay cache; scope, skew, replay, malformed and size tests |
| Pairing | 256-bit secret, two-minute expiry, five attempts, requester identity display, explicit approval, one-use completion and tests |
| Credential storage/lifecycle | AES-GCM at rest, Keychain or mode-0600 master key, plaintext migration, rotation and revocation tests |
| Complete/incremental backfill | Origin summaries/gaps, range planner, 500-record pages, durable per-page inserts, 1,201-record three-page convergence and address fallback tests |
| Current mobile API | Authenticated deterministic current projection; wrong-scope and replay rejection tests |
| Embedded service | Hummingbird bounded routes, exact CORS, optional trusted TLS, fail-closed non-loopback CLI configuration, static PWA route tests |
| Connectivity/fallback | Bonjour advertisement, manual/Tailscale HTTPS validation, persistent peer addresses, and address health tracking |
| Mobile PWA | Packaged offline shell; three screens; IndexedDB; non-extractable AES-GCM key; HMAC requests; deterministic multi-peer merge; stale cache; visible-only polling/backoff; Node vectors |
| Notification extraction | Injected clock, deterministic crossing event ID and state transition tests; existing macOS delivery retained |
| Existing behavior | Complete `swift test` suite and macOS product build |

## Deliberately disabled

Web Push is disabled. It is not production-ready because this environment cannot perform the required installed-iOS closed, locked and terminated delivery proof. No background iOS polling is implemented or claimed.

## Physical/external release gates still required

- macOS, Linux/Avahi and Windows physical desktop pair/restart/concurrent-writer/firewall validation.
- Trusted LAN certificate deployment and hostname-change/DHCP/mDNS-disabled tests.
- Tailscale Serve connection, disconnect and reconnect on a real tailnet.
- Installed iOS and Android PWA camera/install/storage/visibility/network behavior.
- Physical iOS locked/closed/terminated Web Push proof before enabling Web Push.
- Packet capture and public-network port scan confirming TLS, binding and absence of secret/raw-provider fields.
- Ninety-day performance backfill measurement and release security/SBOM review.

Follow the exact manual sequence in `multi-device-sync-operations.md`. A release must not mark these gates passed from simulator or unit-test evidence alone.
