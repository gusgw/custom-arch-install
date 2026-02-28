#!/bin/bash
#
# stage3.sh — Post-reboot setup: AUR packages, ZFS, user services
#
# Run as the primary user (not root) after rebooting into the new system.
# Requires network connectivity and sudo access.
#
# Example:
#   ./stage3.sh
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ─── BUMP library ──────────────────────────────────────────────────────

# shellcheck disable=SC1091
. "${SCRIPT_DIR}/bump.sh"

set_stamp
trap handle_signal SIGINT SIGTERM

# ─── Helpers ────────────────────────────────────────────────────────────

confirm() {
    local prompt="${1:-Continue?}"
    local response=""
    read -r -p "${prompt} [y/N] " response || true
    if [[ ! "$response" =~ ^[Yy]$ ]]; then
        log_message "User aborted at: ${prompt}"
        cleanup "$UNSAFE"
    fi
}

step() {
    local description="$1"
    shift
    echo ""
    log_message "$description"
    for cmd in "$@"; do
        echo "  → $cmd"
    done
    echo ""
    confirm "Execute?"
}

phase() {
    echo ""
    print_rule
    log_message "Phase $1: $2"
    echo "  Phase $1: $2"
    print_rule
    echo ""
}

# ═══════════════════════════════════════════════════════════════════════
#  Validate environment
# ═══════════════════════════════════════════════════════════════════════

phase 9 "Validate environment"

if [[ $EUID -eq 0 ]]; then
    log_message "Run as the primary user, not root"
    cleanup "$UNSAFE"
fi

log_message "Checking network connectivity"
if ! ping -c 1 -W 5 archlinux.org >/dev/null 2>&1; then
    log_message "No network connection"
    cleanup "$MISSING_INPUT"
fi

check_dependency git
check_dependency makepkg
check_dependency sudo
check_exists "${SCRIPT_DIR}/aur-packages.txt"
check_exists "${SCRIPT_DIR}/user-services.txt"
check_exists "${SCRIPT_DIR}/services.txt"

# ═══════════════════════════════════════════════════════════════════════
#  Phase 10: Install AUR helper
# ═══════════════════════════════════════════════════════════════════════

phase 10 "Install AUR helper"

if command -v yay &>/dev/null; then
    log_message "yay already installed"
else
    step "Install yay AUR helper" \
        "git clone https://aur.archlinux.org/yay-bin.git /tmp/yay-bin" \
        "cd /tmp/yay-bin && makepkg -si" \
        "rm -rf /tmp/yay-bin"
    git clone https://aur.archlinux.org/yay-bin.git /tmp/yay-bin
    (cd /tmp/yay-bin && makepkg -si)
    rm -rf /tmp/yay-bin
fi

# ═══════════════════════════════════════════════════════════════════════
#  Phase 11: Install AUR packages
# ═══════════════════════════════════════════════════════════════════════

phase 11 "Install AUR packages"

# shellcheck disable=SC2046 — word splitting is intentional
AUR_PKGS=$(grep -v '^#' "${SCRIPT_DIR}/aur-packages.txt" | grep -v '^$' | tr '\n' ' ')

step "Install AUR packages" \
    "yay -S --needed ${AUR_PKGS}"
# shellcheck disable=SC2086 — word splitting is intentional, yay needs separate args
yay -S --needed $AUR_PKGS

# ═══════════════════════════════════════════════════════════════════════
#  Phase 12: Enable ZFS and AUR-dependent services
# ═══════════════════════════════════════════════════════════════════════

phase 12 "Enable ZFS and AUR-dependent services"

step "Enable ZFS and AUR-dependent system services from services.txt" \
    "sudo systemctl enable <commented services from services.txt>"
# Commented lines in services.txt that look like systemd units are
# AUR-dependent services to enable after AUR packages are installed.
grep -E '^# .*\.(service|timer|target|socket)$' "${SCRIPT_DIR}/services.txt" \
    | sed 's/^# //' \
    | while IFS= read -r service; do
        if sudo systemctl enable "$service" 2>/dev/null; then
            echo "  Enabled $service"
        else
            echo "  WARNING: $service not available"
        fi
    done

# ═══════════════════════════════════════════════════════════════════════
#  Phase 13: Enable user services
# ═══════════════════════════════════════════════════════════════════════

phase 13 "Enable user services"

step "Enable user services from user-services.txt" \
    "systemctl --user enable <each service>"
while IFS= read -r svc; do
    [[ -z "$svc" || "$svc" == \#* ]] && continue
    if systemctl --user enable "$svc" 2>/dev/null; then
        echo "  Enabled $svc"
    else
        echo "  WARNING: $svc not available"
    fi
done < "${SCRIPT_DIR}/user-services.txt"

# ═══════════════════════════════════════════════════════════════════════
#  Phase 14: Complete
# ═══════════════════════════════════════════════════════════════════════

phase 14 "Complete"

echo "Post-reboot setup complete."
echo ""
echo "Remaining manual steps:"
echo ""
echo "  1. Load ZFS and import pool:"
echo "       sudo modprobe zfs"
echo "       sudo zpool import <poolname>"
echo ""
echo "  2. Clone and set up dotfiles"
echo ""
echo "  3. Set up network configs from dotfiles"
echo "       (iwd, systemd-networkd, systemd-resolved)"
echo ""

cleanup 0
