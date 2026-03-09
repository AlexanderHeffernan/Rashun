#!/bin/bash
set -euo pipefail

REPO="alexanderheffernan/rashun"
APP_NAME="Rashun.app"
INSTALL_DIR="/Applications"
DOWNLOAD_URL="https://github.com/$REPO/releases/latest/download/Rashun.zip"
CLI_BIN_IN_APP="$INSTALL_DIR/$APP_NAME/Contents/MacOS/RashunCLI"

link_cli_command() {
    if [ ! -x "$CLI_BIN_IN_APP" ]; then
        echo "ℹ️  CLI binary not found in app bundle at: $CLI_BIN_IN_APP"
        return
    fi

    local system_link_dir="/usr/local/bin"
    local system_link="$system_link_dir/rashun"
    local user_link_dir="$HOME/.local/bin"
    local user_link="$user_link_dir/rashun"

    # Prefer a system-wide command when writable.
    if [ -d "$system_link_dir" ] && [ -w "$system_link_dir" ]; then
        ln -sfn "$CLI_BIN_IN_APP" "$system_link"
        echo "   CLI command installed: $system_link"
        return
    fi

    # Fallback to user-local command without sudo.
    mkdir -p "$user_link_dir"
    ln -sfn "$CLI_BIN_IN_APP" "$user_link"
    echo "   CLI command installed: $user_link"
    case ":$PATH:" in
        *":$user_link_dir:"*)
            ;;
        *)
            echo "   Add ~/.local/bin to PATH to use 'rashun' from anywhere:"
            echo "     echo 'export PATH=\"$HOME/.local/bin:$PATH\"' >> ~/.zshrc"
            echo "     source ~/.zshrc"
            ;;
    esac
}

echo "Installing Rashun..."
echo ""

# Create temp directory and clean up on exit
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

echo "Downloading latest build..."
if ! curl -fsSL -o "$TMPDIR/Rashun.zip" "$DOWNLOAD_URL"; then
    echo "Error: Failed to download. Please check https://github.com/$REPO/releases"
    exit 1
fi

echo "Extracting..."
unzip -q "$TMPDIR/Rashun.zip" -d "$TMPDIR"

# Remove existing install if present
if [ -d "$INSTALL_DIR/$APP_NAME" ]; then
    echo "Removing existing installation..."
    rm -rf "$INSTALL_DIR/$APP_NAME"
fi

echo "Installing to $INSTALL_DIR..."
mv "$TMPDIR/$APP_NAME" "$INSTALL_DIR/"

# Clear macOS quarantine flag so Gatekeeper doesn't block it
xattr -cr "$INSTALL_DIR/$APP_NAME"

echo ""
echo "✅ Rashun installed successfully!"
link_cli_command

# If --update flag is passed, quit the running app and relaunch
if [ "${1:-}" = "--update" ]; then
    osascript -e 'quit app "Rashun"' 2>/dev/null || true
    sleep 1
    open "$INSTALL_DIR/$APP_NAME"
    echo "   Rashun has been updated and relaunched."
else
    echo "   Run it with: open /Applications/Rashun.app"
    echo "   CLI usage: rashun --help"
fi
