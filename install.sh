#!/usr/bin/env bash
set -euo pipefail

REPO="alexanderheffernan/rashun"
BASE_URL="https://raw.githubusercontent.com/$REPO/main/scripts/install"

run_remote_bash() {
  local script_name="$1"
  shift
  curl -fsSL "$BASE_URL/$script_name" | bash -s -- "$@"
}

case "$(uname -s)" in
  Darwin)
    run_remote_bash "macos.sh" "$@"
    ;;
  Linux)
    run_remote_bash "linux.sh" "$@"
    ;;
  *)
    cat <<EOF
Unsupported platform for this installer script.

For Windows, install with PowerShell:
  irm https://raw.githubusercontent.com/$REPO/main/scripts/install/windows.ps1 | iex
EOF
    exit 1
    ;;
esac
