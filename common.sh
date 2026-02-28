#!/bin/bash
#
# common.sh — Shared configuration and helpers for stage1.sh and stage2.sh
#
# Sourced by both scripts. Expects SCRIPT_DIR to be set before sourcing.
#

# ─── BUMP library ──────────────────────────────────────────────────────

# shellcheck disable=SC1091
. "${SCRIPT_DIR}/bump.sh"

set_stamp
trap handle_signal SIGINT SIGTERM

# ─── Configuration ─────────────────────────────────────────────────────

not_empty "HOSTNAME environment variable" "${HOSTNAME:-}"
not_empty "USERNAME environment variable" "${USERNAME:-}"

DISK="/dev/nvme0n1"
EFI_PART="${DISK}p2"
LUKS_PART="${DISK}p3"
ZFS_PART="${DISK}p4"
VG_NAME="internal"

log_setting "Hostname" "$HOSTNAME"
log_setting "Username" "$USERNAME"
log_setting "Disk" "$DISK"
log_setting "EFI partition" "$EFI_PART"
log_setting "LUKS partition" "$LUKS_PART"
log_setting "ZFS partition (DO NOT TOUCH)" "$ZFS_PART"
log_setting "LVM volume group" "$VG_NAME"

# ─── Cleanup handler ───────────────────────────────────────────────────

function cleanup_mounts {
    local rc="$1"
    if [[ $rc -ne 0 ]]; then
        log_message "Cleaning up mounts and LUKS..."
        swapoff "/dev/${VG_NAME}/swap" 2>/dev/null || true
        umount -R /mnt 2>/dev/null || true
        vgchange -an "$VG_NAME" 2>/dev/null || true
        cryptsetup close "$VG_NAME" 2>/dev/null || true
    fi
}
cleanup_functions+=(cleanup_mounts)
trap 'rc=$?; [[ $rc -ne 0 ]] && cleanup_mounts "$rc"; exit $rc' EXIT

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

# ─── Common validation ────────────────────────────────────────────────

validate_live_usb() {
    if [[ $EUID -ne 0 ]]; then
        log_message "Must run as root"
        cleanup "$SECURITY_FAILURE"
    fi

    if [[ ! -d /run/archiso ]]; then
        log_message "Not running from a live USB (no /run/archiso)"
        cleanup "$UNSAFE"
    fi
}
