Drop source logo files in this folder to render them in menu bar ring centers.

Convention:
- Only `.png` is supported.
- File name is derived from source name in lowercase, with non-alphanumeric characters removed.
- Examples:
  - `AMP` -> `amp.png`
  - `Copilot` -> `copilot.png`
  - `Codex` -> `codex.png`
  - `Gemini` -> `gemini.png`

Fallback behavior:
- In `Logo` center mode, if the PNG logo is missing, the ring center falls back to showing the numeric percentage.
Recommended:
- square canvas (64x64 or 128x128)
- transparent background
- visually simple mark that is legible at very small sizes
