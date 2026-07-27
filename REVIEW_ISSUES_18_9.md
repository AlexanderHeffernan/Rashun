# Issues #18 and #9 review

- Expected provider resets (within two minutes before through ten minutes after the prior reset timestamp, with an advanced new reset timestamp) bypass the second-sample delay.
- Unexpected upward jumps still require confirmation.
- Codex banked-reset notifications are source-level settings, separate from the Pro Weekly and Pro 5 Hour metric notification settings. Expanding the Codex source-row Notifications button displays these source notifications above the Usage Metrics list, while each metric retains its own notification panel. Each alert can be enabled independently, and the expiry lead time is configurable in days (default: two).
- Expiry warnings remain deduplicated once per expiration timestamp.
- This is notification-only: no reset redemption action or API is included.

Manual check: in Settings → Sources, enable Codex and expand the source-row Notifications button. Confirm Source Notifications appears immediately below the Codex header and above Usage Metrics; confirm the Pro Weekly and Pro 5 Hour rows still have independent Notifications buttons and panels. Enable the expiry warning, set its lead time, then use a fixture/debug response inside that window and confirm only one expiry notification is delivered.
