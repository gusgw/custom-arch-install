#!/bin/bash
#
# build-iso.sh — Build custom Arch ISO with installer
#
# Run on clovis as a regular user. Uses sudo where needed.
# Clones the setup repo into the ISO at /root/setup/ so
# the installer is available at /root/setup/install.sh.
#
# Usage:
#   ./build-iso.sh              # writes to /dev/sda
#   ./build-iso.sh /dev/sdb     # writes to specified device
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ─── BUMP library ──────────────────────────────────────────────────────

# shellcheck disable=SC1091
. "${SCRIPT_DIR}/bump.sh"

set_stamp
trap handle_signal SIGINT SIGTERM

# ─── Configuration ─────────────────────────────────────────────────────

WORK_DIR="/tmp/archlive"
BUILD_DIR="/tmp/archiso-tmp"
OUT_DIR="/tmp/archiso-out"
SETUP_REPO="${SCRIPT_DIR}"
USB_DEV="${1:-/dev/sda}"

log_setting "Work directory" "$WORK_DIR"
log_setting "Build directory" "$BUILD_DIR"
log_setting "Output directory" "$OUT_DIR"
log_setting "Setup repo" "$SETUP_REPO"
log_setting "USB device" "$USB_DEV"

# ─── Cleanup handler ───────────────────────────────────────────────────

function cleanup_build {
    local rc="$1"
    if [[ $rc -ne 0 ]]; then
        log_message "Cleaning up build artifacts..."
        sudo rm -rf "$WORK_DIR" "$BUILD_DIR" 2>/dev/null || true
    fi
}
cleanup_functions+=(cleanup_build)

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

# ─── Validate ───────────────────────────────────────────────────────────

check_dependency git
check_dependency mkarchiso
check_dependency dd
check_exists "$SETUP_REPO/.git"

# ─── Prerequisites ─────────────────────────────────────────────────────

log_message "Installing archiso if needed"
sudo pacman -S --needed --noconfirm archiso

# ─── Setup ──────────────────────────────────────────────────────────────

log_message "Cleaning previous build artifacts"
sudo rm -rf "$WORK_DIR" "$BUILD_DIR" "$OUT_DIR"

log_message "Copying releng profile"
cp -r /usr/share/archiso/configs/releng/ "$WORK_DIR"

# ─── Add setup repo to ISO ──────────────────────────────────────────

log_message "Cloning setup repo into ISO airootfs"
AIROOTFS="${WORK_DIR}/airootfs"
mkdir -p "${AIROOTFS}/root"
git clone "$SETUP_REPO" "${AIROOTFS}/root/setup/"

REMOTE_URL=$(git -C "$SETUP_REPO" remote get-url origin 2>/dev/null || true)
if [[ -n "$REMOTE_URL" ]]; then
    git -C "${AIROOTFS}/root/setup/" remote set-url origin "$REMOTE_URL"
    log_setting "Remote URL" "$REMOTE_URL"
fi

# ─── Add MOTD with install instructions ─────────────────────────────────

log_message "Adding login instructions to ISO"
mkdir -p "${AIROOTFS}/etc"
cat > "${AIROOTFS}/etc/motd" <<'MOTD'

  ┌──────────────────────────────────────────────────────────────┐
  │  Arch Linux Installer                                        │
  │                                                              │
  │  Run the installer:                                          │
  │    HOSTNAME=<host> USERNAME=<user> /root/setup/install.sh    │
  │                                                              │
  │  To pull fixes before installing:                            │
  │    cd /root/setup && git pull                                │
  │                                                              │
  └──────────────────────────────────────────────────────────────┘

MOTD

# ─── Build ISO ──────────────────────────────────────────────────────────

log_message "Building ISO"
sudo mkarchiso -v -w "$BUILD_DIR" -o "$OUT_DIR" "$WORK_DIR"

ISO_FILE=$(find "$OUT_DIR" -name 'archlinux-*.iso' -print -quit)
not_empty "ISO file" "$ISO_FILE"
check_exists "$ISO_FILE"

log_setting "ISO file" "$ISO_FILE"
log_setting "ISO size" "$(du -h "$ISO_FILE" | cut -f1)"

# ─── Write to USB ───────────────────────────────────────────────────────

echo ""
echo "Target USB device: $USB_DEV"
lsblk "$USB_DEV" 2>/dev/null || true
echo ""
echo "WARNING: ALL DATA on $USB_DEV will be destroyed."
confirm "Write ISO to ${USB_DEV}?"

log_message "Writing ISO to ${USB_DEV}"
sudo dd bs=4M if="$ISO_FILE" of="$USB_DEV" status=progress oflag=sync

log_message "ISO written successfully"
echo ""
echo "Done. Remove USB and boot from it."
echo "The installer is at: /root/setup/setup/install.sh"

cleanup 0
