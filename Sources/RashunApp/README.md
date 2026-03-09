# RashunApp platform layout

- `macOS/` contains all macOS-specific app code (AppKit/SwiftUI app shell).
- `Resources/` contains app resources packaged by SwiftPM.

Future platform-specific app shells can live alongside `macOS/` at:

- `linux/`
- `windows/`

Cross-platform business logic should continue to live in `Sources/RashunCore/`.
