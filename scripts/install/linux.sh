#!/usr/bin/env bash
set -euo pipefail

REPO="alexanderheffernan/rashun"
DOWNLOAD_URL="https://github.com/$REPO/releases/latest/download/rashun-cli-linux.tar.gz"
INSTALL_ROOT="${HOME}/.local"
BIN_DIR="$INSTALL_ROOT/bin"
TARGET="$BIN_DIR/rashun"

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

echo "Downloading Linux CLI artifact..."
curl -fsSL -o "$TMPDIR/rashun-cli-linux.tar.gz" "$DOWNLOAD_URL"

mkdir -p "$BIN_DIR"
tar -xzf "$TMPDIR/rashun-cli-linux.tar.gz" -C "$TMPDIR"
mv "$TMPDIR/rashun" "$TARGET"
chmod +x "$TARGET"

echo "Installed: $TARGET"
case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *)
    echo "Add to PATH if needed: export PATH=\"$BIN_DIR:$PATH\""
    ;;
esac
