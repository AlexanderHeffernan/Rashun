#!/usr/bin/env bash
set -euo pipefail

REPO="alexanderheffernan/rashun"
DOWNLOAD_URL="https://github.com/$REPO/releases/latest/download/rashun-cli-linux.tar.gz"
INSTALL_ROOT="${HOME}/.local"
BIN_DIR="$INSTALL_ROOT/bin"
TARGET="$BIN_DIR/rashun"

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

ensure_path_persisted() {
  local line='export PATH="$HOME/.local/bin:$PATH"'
  local updated=false

  for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
    [ -f "$rc" ] || continue
    if ! grep -Fq "$line" "$rc"; then
      printf '\n%s\n' "$line" >> "$rc"
      updated=true
      echo "Updated PATH in: $rc"
    fi
  done

  if [ "$updated" = true ]; then
    echo "Open a new shell (or run: $line) to use 'rashun' globally."
  fi
}

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
    ensure_path_persisted
    if ! command -v rashun >/dev/null 2>&1; then
      echo "Add to PATH in this shell: export PATH=\"$BIN_DIR:$PATH\""
    fi
    ;;
esac

if ! "$TARGET" --help >/dev/null 2>&1; then
  echo "Installed binary failed validation: rashun --help" >&2
  exit 1
fi

echo "Validation passed: rashun --help"
