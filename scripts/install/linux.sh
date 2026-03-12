#!/usr/bin/env bash
set -euo pipefail

REPO="alexanderheffernan/rashun"
RELEASE_BASE_URL="${RASHUN_RELEASE_BASE_URL:-https://github.com/$REPO/releases/latest/download}"
INSTALL_ROOT="${HOME}/.local"
BIN_DIR="$INSTALL_ROOT/bin"
TARGET="$BIN_DIR/rashun"
LIBEXEC_DIR="$INSTALL_ROOT/lib/rashun"

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

detect_linux_arch() {
  case "$(uname -m)" in
    x86_64|amd64)
      printf 'x86_64'
      ;;
    aarch64|arm64)
      printf 'aarch64'
      ;;
    *)
      printf 'unsupported'
      ;;
  esac
}

download_cli_archive() {
  local arch="$1"
  local out_file="$2"

  if [ "$arch" = "x86_64" ]; then
    # Keep compatibility with older releases that only published rashun-cli-linux.tar.gz.
    local primary_url="$RELEASE_BASE_URL/rashun-cli-linux-x86_64.tar.gz"
    local legacy_url="$RELEASE_BASE_URL/rashun-cli-linux.tar.gz"

    if curl -fsSL -o "$out_file" "$primary_url"; then
      return 0
    fi

    echo "x86_64 artifact not found; falling back to legacy Linux artifact..."
    curl -fsSL -o "$out_file" "$legacy_url"
    return 0
  fi

  if [ "$arch" = "aarch64" ]; then
    local arm_url="$RELEASE_BASE_URL/rashun-cli-linux-aarch64.tar.gz"
    curl -fsSL -o "$out_file" "$arm_url"
    return 0
  fi

  echo "Unsupported Linux architecture: $(uname -m)" >&2
  echo "Supported architectures: x86_64, aarch64/arm64" >&2
  exit 1
}

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

ARCH="$(detect_linux_arch)"
echo "Detected Linux architecture: $ARCH"
echo "Downloading Linux CLI artifact..."

if ! download_cli_archive "$ARCH" "$TMPDIR/rashun-cli-linux.tar.gz"; then
  if [ "$ARCH" = "aarch64" ]; then
    echo "No Linux aarch64 release artifact is available yet." >&2
    echo "You can build from source with: ./build.sh --cli-only --link-cli" >&2
  else
    echo "Failed to download Linux CLI artifact for architecture: $ARCH" >&2
  fi
  exit 1
fi

mkdir -p "$BIN_DIR"
EXTRACT_DIR="$TMPDIR/extracted"
mkdir -p "$EXTRACT_DIR"
tar -xzf "$TMPDIR/rashun-cli-linux.tar.gz" -C "$EXTRACT_DIR"

if [ -f "$EXTRACT_DIR/rashun" ] && [ -f "$EXTRACT_DIR/rashun-bin" ]; then
  rm -rf "$LIBEXEC_DIR"
  mkdir -p "$LIBEXEC_DIR"
  cp -a "$EXTRACT_DIR/rashun-bin" "$LIBEXEC_DIR/"
  if [ -d "$EXTRACT_DIR/lib" ]; then
    cp -a "$EXTRACT_DIR/lib" "$LIBEXEC_DIR/"
  fi

  cat > "$LIBEXEC_DIR/rashun" <<EOF
#!/usr/bin/env bash
set -euo pipefail
export LD_LIBRARY_PATH="$LIBEXEC_DIR/lib\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
exec "$LIBEXEC_DIR/rashun-bin" "\$@"
EOF
  chmod +x "$LIBEXEC_DIR/rashun"

  ln -sfn "$LIBEXEC_DIR/rashun" "$TARGET"
else
  mv "$EXTRACT_DIR/rashun" "$TARGET"
  chmod +x "$TARGET"
fi

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
