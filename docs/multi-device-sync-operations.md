# Multi-device sync operations and security

## Data ownership

`usage-sync.sqlite` is the immutable usage-history truth. Every accepted desktop provider metric receives a UUID and a transactionally allocated `(deviceID, epoch, sequence)`. Compressed JSON history is a derived compatibility cache only. Provider credentials, cookies, authentication files, provider configuration, raw responses, tracked sessions, forecasts, notification history, account identifiers, and arbitrary provider fields are excluded from the canonical schema and protocol DTOs.

The database uses SQLite WAL mode and a five-second busy timeout for concurrent desktop/CLI writers. Canonical retention is indefinite. A future retention implementation must advertise unavailable ranges; it may never silently advance a peer through missing data.

## Migration and recovery

On first canonical startup, decodable legacy history is copied to `Backups/sync-v1/<SHA-256>/ai.notificationHistory.v1.json`. Imported IDs and the legacy origin are deterministic for those exact source bytes. Plain source names, `Source::metricID`, and historical `Source - Metric title` aliases are recognized; unknown keys are written to `quarantine.json`. Repeating migration is safe because canonical IDs deduplicate.

Keep the backup through at least the next compatibility release. If SQLite reports corruption, stop Rashun, preserve the database plus WAL/SHM files, restore the legacy backup if necessary, and run `sqlite3 usage-sync.sqlite 'PRAGMA quick_check'`. Rashun must not replace a corrupt database with an empty one.

## Authentication and threat model

Desktop sync credentials are independent high-entropy secrets with explicit `desktopSync` or `mobileRead` scope. Requests are authenticated with HMAC-SHA-256 over method, path, body hash, credential ID, timestamp, and nonce. Verifiers enforce clock skew and one-use nonces. Desktop setup codes use an unambiguous eight-character alphabet, expire after 15 minutes, and are consumed once. Successful exchange issues an independent 256-bit credential. Revocation must be checked before processing authenticated request bodies.

Authenticated desktop credentials can be rotated atomically through `POST /v1/peers/rotate`. Rotation revokes the old credential immediately, creates a new 256-bit scoped secret, and transfers saved candidate addresses. The returned secret must be protected immediately and is not recoverable from diagnostics.

Discovery grants no authority. Bind only to selected private interfaces, cap batches at 500 observations/1 MiB, validate hashes and finite numeric bounds, and reject origin-sequence conflicts. Logs and discovery metadata must not contain usage values or secrets. Browser mutation endpoints require exact-origin CORS and CSRF tokens; the mobile client is read-only.

## Connectivity and pairing

The Preferences **Sync** tab is the normal control surface. Enable **Mobile app** to start Rashun on the local network. Rashun displays its IP address, current availability, a 15-minute setup password, a directly openable link, and a QR code. Opening the link exchanges the temporary password for a random read-only credential and removes the password from the browser address. Long-term credentials remain hidden from the user.

To pair another device, use **Add connection** in Preferences or run `rashun sync serve` on the accepting device and execute the printed `rashun sync connect …` command on the joining device. The same flow works between macOS, Linux, and Windows CLI installations. Removing a device revokes its credential.

The app listener binds port 8787 on local interfaces when enabled. Any private-network overlay may carry the same IP traffic; Rashun contains no overlay-specific setup or address type. Platform firewall requirements:

On macOS, Rashun silently checks for an installed Tailscale application or CLI and an active `100.64.0.0/10` interface address. When both are present, Preferences defaults the displayed link and QR code to that address and offers a **Use Tailscale address** toggle. No Tailscale control, authentication, or configuration is performed by Rashun, and no Tailscale UI appears when it is unavailable.

- macOS: allow inbound connections for the signed Rashun app when desktop sync is enabled.
- Linux: permit the configured TCP port only on the private interface; Avahi UDP 5353 is optional.
- Windows: create a Private-profile-only inbound rule; never enable the Public profile automatically.

## Mobile PWA

The enabled desktop serves one mobile view and its read-only API from the same origin. The mobile app has no connection-management screen and does not combine desktops. After its setup link is opened once, the credential is encrypted in IndexedDB using a non-extractable AES-GCM Web Crypto key. It loads usage immediately, refreshes once per minute while visible, and shows cached data as offline when the desktop cannot be reached. Clearing browser storage requires opening a newly generated setup link.

LAN HTTP supports the immediate browser experience but is not a secure context. Browsers may not register the service worker or enable push from that address. A fully installable PWA and Web Push require the same Rashun host to be presented through browser-trusted HTTPS; this transport concern is deliberately outside the Preferences setup flow.

iOS does not provide reliable service-worker background timers. Rashun makes no background polling claim. Web Push is disabled until installed-iOS delivery is demonstrated with the PWA closed, the device locked, and the PWA terminated.

## Diagnostics and validation

```sh
# Device A prints a one-use code and the exact command for Device B.
swift run RashunCLI sync serve

# Device B connects, performs the initial merge, then stays reachable in another terminal.
swift run RashunCLI sync connect http://device-a:8787 ABCD-2345
swift run RashunCLI sync serve

swift run RashunCLI sync devices
swift run RashunCLI sync sync-now
swift run RashunCLI sync remove '<device name or credential UUID>'
swift test
```

Manual release matrix:

1. Pair two physical desktops, stop either side during a multi-page backfill, restart it, and confirm origin ranges converge without duplicates.
2. Repeat with mDNS disabled using hostname/IP, then after DHCP address change.
3. Test macOS, Linux, and Windows CLI hosts with private firewall profiles and confirm public interfaces are closed.
4. Open the generated mobile link on current iOS and Android; test visible, hidden, resumed, offline, storage-cleared, and expired-link states.
5. Validate service-worker/PWA installation separately on a browser-trusted HTTPS presentation of the same host.
6. Inspect a database, export, discovery packet, API packet capture, and logs for credential/raw-response fields.
7. Web Push may only be enabled after locked/closed/terminated physical-iOS delivery, visible notification behavior, subscription expiry, and duplicate suppression pass.
