#!/bin/bash
#
# stage0.sh — Partition a blank NVMe drive
#
# Optional first step for fresh installations on a completely blank
# disk. Creates GPT partition table, LUKS container, and LVM volumes.
# Formats home (since stage1 preserves it). Leaves LUKS open for
# stage1 to continue.
#
# After stage0, run stage1.sh (which skips LUKS open if already open).
#
# Required environment variables:
#   HOSTNAME — the hostname for the new system
#   USERNAME — the primary user account name
#
# Example:
#   HOSTNAME=myhost USERNAME=myuser ./stage0.sh
#
# Partition layout created:
#   nvme0n1p1 — 1M      — BIOS boot
#   nvme0n1p2 — 512M    — EFI System
#   nvme0n1p3 — 153G    — LUKS → LVM "internal"
#     swap    — 32G
#     root    — 100G
#     home    — remainder
#   nvme0n1p4 — remainder — ZFS (partitioned, not formatted)
#
# Requires a 1TB+ NVMe drive. Any space beyond 153G+512M+1M
# goes to the ZFS partition.
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# shellcheck disable=SC1091
. "${SCRIPT_DIR}/common.sh"

# ═══════════════════════════════════════════════════════════════════════
#  Validate environment
# ═══════════════════════════════════════════════════════════════════════

phase 0 "Validate environment"

validate_live_usb

for cmd in sgdisk cryptsetup pvcreate vgcreate lvcreate fdisk blkid; do
    check_dependency "$cmd"
done

# ─── Check disk size ──────────────────────────────────────────────────

DISK_BYTES=$(blockdev --getsize64 "$DISK")
DISK_GIB=$((DISK_BYTES / 1073741824))
MIN_GIB=950

log_setting "Disk size" "${DISK_GIB} GiB"

if [[ $DISK_GIB -lt $MIN_GIB ]]; then
    log_message "Disk is ${DISK_GIB} GiB — need at least ${MIN_GIB} GiB"
    cleanup "$UNSAFE"
fi

echo "Disk: ${DISK} (${DISK_GIB} GiB)"
echo ""
echo "Partition layout to create:"
echo "  p1 — 1M      — BIOS boot"
echo "  p2 — 512M    — EFI System"
echo "  p3 — 153G    — LUKS → LVM (swap 32G, root 100G, home ~21G)"
echo "  p4 — ~$((DISK_GIB - 154))G  — ZFS"
echo ""
echo "WARNING: ALL DATA on ${DISK} will be DESTROYED."
echo ""
confirm "Create partition table on ${DISK}?"

# ═══════════════════════════════════════════════════════════════════════
#  Partition disk
# ═══════════════════════════════════════════════════════════════════════

phase 0 "Partition disk"

step "Create GPT partition table" \
    "sgdisk --zap-all ${DISK}" \
    "sgdisk -n 1:0:+1M   -t 1:EF02 ${DISK}  (BIOS boot)" \
    "sgdisk -n 2:0:+512M -t 2:EF00 ${DISK}  (EFI)" \
    "sgdisk -n 3:0:+153G -t 3:8300 ${DISK}  (LUKS)" \
    "sgdisk -n 4:0:0     -t 4:BF00 ${DISK}  (ZFS)"
sgdisk --zap-all "$DISK"
sgdisk -n 1:0:+1M   -t 1:EF02 "$DISK"
sgdisk -n 2:0:+512M -t 2:EF00 "$DISK"
sgdisk -n 3:0:+153G -t 3:8300 "$DISK"
sgdisk -n 4:0:0     -t 4:BF00 "$DISK"

echo ""
echo "Partition table created:"
fdisk -l "$DISK"
echo ""

# ═══════════════════════════════════════════════════════════════════════
#  LUKS + LVM
# ═══════════════════════════════════════════════════════════════════════

phase 0 "LUKS + LVM"

step "Create LUKS container (set passphrase)" \
    "cryptsetup luksFormat ${LUKS_PART}"
echo "You will be prompted for the LUKS passphrase (twice)."
cryptsetup luksFormat "$LUKS_PART"

step "Open LUKS container" \
    "cryptsetup open ${LUKS_PART} ${VG_NAME}"
cryptsetup open "$LUKS_PART" "$VG_NAME"

step "Create LVM physical volume and volume group" \
    "pvcreate /dev/mapper/${VG_NAME}" \
    "vgcreate ${VG_NAME} /dev/mapper/${VG_NAME}"
pvcreate "/dev/mapper/${VG_NAME}"
vgcreate "$VG_NAME" "/dev/mapper/${VG_NAME}"

step "Create logical volumes" \
    "lvcreate -L 32G  ${VG_NAME} -n swap" \
    "lvcreate -L 100G ${VG_NAME} -n root" \
    "lvcreate -l 100%FREE ${VG_NAME} -n home"
lvcreate -L 32G "$VG_NAME" -n swap
lvcreate -L 100G "$VG_NAME" -n root
lvcreate -l 100%FREE "$VG_NAME" -n home

step "Format home filesystem" \
    "mkfs.ext4 /dev/${VG_NAME}/home"
mkfs.ext4 "/dev/${VG_NAME}/home"

# ═══════════════════════════════════════════════════════════════════════
#  Stage 0 complete
# ═══════════════════════════════════════════════════════════════════════

phase 0 "Complete"

echo "Partition layout created. LUKS is open. Now run stage 1:"
echo ""
echo "  HOSTNAME=${HOSTNAME} USERNAME=${USERNAME} ${SCRIPT_DIR}/stage1.sh"
echo ""
echo "Note: ${ZFS_PART} is partitioned (type BF00) but not formatted."
echo "Create the ZFS pool after rebooting:"
echo "  sudo zpool create <poolname> ${ZFS_PART}"
echo ""

cleanup 0
