#!/bin/bash
# television — one-line installer
# Usage: bash <(curl -fsSL https://raw.githubusercontent.com/J-L33T/television/main/install.sh)

set -e

REPO="https://raw.githubusercontent.com/J-L33T/television/main/television.sh"
DEST="/usr/local/bin/television"

# Colors
CYAN="\033[0;36m"; GREEN="\033[1;32m"; NC="\033[0m"

echo -e "${CYAN}"
echo "  ┌─────────────────────────────────────────────────────────┐"
echo "  │          TELEVISION — Telegram MTProxy Manager          │"
echo "  │    Powered by telemt (Rust/tokio) · J-L33T/television   │"
echo "  └─────────────────────────────────────────────────────────┘"
echo -e "${NC}"

if [[ "${EUID}" -ne 0 ]]; then
  echo "  [!] Re-running with sudo..."
  exec sudo bash "$0" "$@"
fi

echo -e "  ${CYAN}→${NC}  Downloading television.sh..."
curl -fsSL "${REPO}" -o "${DEST}"
chmod +x "${DEST}"

echo -e "  ${GREEN}✓${NC}  Installed to ${DEST}"
echo
echo -e "  ${CYAN}→${NC}  Launching..."
echo
exec "${DEST}"
