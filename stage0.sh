#!/bin/bash
#
# stage0.sh — Partition a blank NVMe drive and install base system
#
# For fresh installations on a completely blank disk. Creates GPT
# partition table, LUKS, LVM, formats filesystems, mounts, and
# runs pacstrap.
#
# After stage0, place the LUKS keyfile and run stage2.sh.
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
#  Phase 1: Validate environment
# ═══════════════════════════════════════════════════════════════════════

phase 1 "Validate environment"

validate_live_usb

log_message "Checking network connectivity"
if ! ping -c 1 -W 5 archlinux.org >/dev/null 2>&1; then
    log_message "No network connection — connect with iwctl or ethernet first"
    cleanup "$MISSING_INPUT"
fi

for cmd in sgdisk cryptsetup mkfs.fat pvcreate vgcreate lvcreate \
           pacstrap genfstab arch-chroot fdisk blkid curl; do
    check_dependency "$cmd"
done

check_exists "${SCRIPT_DIR}/packages.txt"
check_exists "${SCRIPT_DIR}/services.txt"
check_exists "${SCRIPT_DIR}/user-services.txt"

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
#  Phase 2: Partition disk
# ═══════════════════════════════════════════════════════════════════════

phase 2 "Partition disk"

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
#  Phase 3: LUKS + LVM + format
# ═══════════════════════════════════════════════════════════════════════

phase 3 "LUKS + LVM + format"

step "Format EFI partition" \
    "mkfs.fat -F32 ${EFI_PART}"
mkfs.fat -F32 "$EFI_PART"

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

step "Format filesystems" \
    "mkswap /dev/${VG_NAME}/swap" \
    "mkfs.ext4 /dev/${VG_NAME}/root" \
    "mkfs.ext4 /dev/${VG_NAME}/home"
mkswap "/dev/${VG_NAME}/swap"
mkfs.ext4 "/dev/${VG_NAME}/root"
mkfs.ext4 "/dev/${VG_NAME}/home"

# ═══════════════════════════════════════════════════════════════════════
#  Phase 4: Mount and install
# ═══════════════════════════════════════════════════════════════════════

phase 4 "Mount and install"

step "Mount filesystems" \
    "mount /dev/${VG_NAME}/root /mnt" \
    "mount ${EFI_PART} /mnt/efi" \
    "mount /dev/${VG_NAME}/home /mnt/home" \
    "swapon /dev/${VG_NAME}/swap"
mount "/dev/${VG_NAME}/root" /mnt
mkdir -p /mnt/efi /mnt/home
mount "$EFI_PART" /mnt/efi
mount "/dev/${VG_NAME}/home" /mnt/home
swapon "/dev/${VG_NAME}/swap"

step "Add Sublime Text repository and GPG key" \
    "pacman-key: import sublimehq-pub.gpg (key 8A8F901A)" \
    "Add [sublime-text] repo to /etc/pacman.conf" \
    "pacman -Sy"
curl -O https://download.sublimetext.com/sublimehq-pub.gpg
pacman-key --add sublimehq-pub.gpg
pacman-key --lsign-key 8A8F901A
rm -f sublimehq-pub.gpg
echo -e '\n[sublime-text]\nServer = https://download.sublimetext.com/arch/stable/x86_64' >> /etc/pacman.conf
pacman -Sy

step "Install packages with pacstrap" \
    "pacstrap -K /mnt <packages from packages.txt>"
# shellcheck disable=SC2046 — word splitting is intentional, pacstrap needs separate args
pacstrap -K /mnt $(grep -v '^#' "${SCRIPT_DIR}/packages.txt" | grep -v '^$')

step "Generate fstab" \
    "genfstab -U /mnt >> /mnt/etc/fstab"
genfstab -U /mnt >> /mnt/etc/fstab

# ═══════════════════════════════════════════════════════════════════════
#  Stage 0 complete
# ═══════════════════════════════════════════════════════════════════════

phase "" "Stage 0 complete"

echo "Filesystems are mounted at /mnt. Now place the LUKS keyfile:"
echo ""
echo "  mkdir -p /mnt/root/key"
echo "  cp /path/to/your/keyfile /mnt/root/key/internal.key"
echo "  chmod 000 /mnt/root/key/internal.key"
echo ""
echo "Then run stage 2:"
echo ""
echo "  HOSTNAME=${HOSTNAME} USERNAME=${USERNAME} ${SCRIPT_DIR}/stage2.sh"
echo ""
echo "Note: ${ZFS_PART} is partitioned (type BF00) but not formatted."
echo "Create the ZFS pool after rebooting:"
echo "  sudo zpool create <poolname> ${ZFS_PART}"
echo ""

cleanup 0
