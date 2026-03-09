#!/usr/bin/env bash
set -euo pipefail

REPO="alexanderheffernan/rashun"
APP_NAME="Rashun.app"
INSTALL_DIR="/Applications"
DOWNLOAD_URL="https://github.com/$REPO/releases/latest/download/Rashun.zip"
CLI_BIN_IN_APP="$INSTALL_DIR/$APP_NAME/Contents/MacOS/RashunCLI"

link_cli_command() {
  if [ ! -x "$CLI_BIN_IN_APP" ]; then
    echo "CLI binary not found in app bundle at: $CLI_BIN_IN_APP"
    return
  fi

  local system_link_dir="/usr/local/bin"
  local system_link="$system_link_dir/rashun"
  local user_link_dir="$HOME/.local/bin"
  local user_link="$user_link_dir/rashun"

  if [ -d "$system_link_dir" ] && [ -w "$system_link_dir" ]; then
    ln -sfn "$CLI_BIN_IN_APP" "$system_link"
    echo "CLI command installed: $system_link"
    return
  fi

  mkdir -p "$user_link_dir"
  ln -sfn "$CLI_BIN_IN_APP" "$user_link"
  echo "CLI command installed: $user_link"
}

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

echo "Downloading macOS app..."
curl -fsSL -o "$TMPDIR/Rashun.zip" "$DOWNLOAD_URL"

echo "Extracting..."
unzip -q "$TMPDIR/Rashun.zip" -d "$TMPDIR"

if [ -d "$INSTALL_DIR/$APP_NAME" ]; then
  rm -rf "$INSTALL_DIR/$APP_NAME"
fi

mv "$TMPDIR/$APP_NAME" "$INSTALL_DIR/"
xattr -cr "$INSTALL_DIR/$APP_NAME"

echo "Rashun installed successfully."
link_cli_command

if [ "${1:-}" = "--update" ]; then
  osascript -e 'quit app "Rashun"' 2>/dev/null || true
  sleep 1
  open "$INSTALL_DIR/$APP_NAME"
fi
