#!/bin/bash
#
# install-aur.sh — Install all AUR packages from aur-packages.txt
#
# Run as the primary user (not root) after yay is installed.
# Can be re-run safely — yay --needed skips already installed packages.
#
# Usage:
#   ./install-aur.sh
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [[ $EUID -eq 0 ]]; then
    echo "Run as the primary user, not root"
    exit 1
fi

if ! command -v yay &>/dev/null; then
    echo "yay not found — install it first:"
    echo "  git clone https://aur.archlinux.org/yay-bin.git /tmp/yay-bin"
    echo "  cd /tmp/yay-bin && makepkg -si"
    exit 1
fi

if [[ ! -f "${SCRIPT_DIR}/aur-packages.txt" ]]; then
    echo "aur-packages.txt not found in ${SCRIPT_DIR}"
    exit 1
fi

# shellcheck disable=SC2046 — word splitting is intentional, yay needs separate args
AUR_PKGS=$(grep -v '^#' "${SCRIPT_DIR}/aur-packages.txt" | grep -v '^$' | tr '\n' ' ')

echo "Installing AUR packages:"
echo "$AUR_PKGS" | tr ' ' '\n' | sed 's/^/  /'
echo ""

yay -S --needed $AUR_PKGS

echo ""
echo "Done."
