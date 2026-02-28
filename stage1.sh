#!/bin/bash
#
# stage1.sh — Format, mount, and install base system
#
# Run as root from a live USB booted with the custom archiso.
# After stage1 completes, place the LUKS keyfile, then run stage2.sh.
#
# Required environment variables:
#   HOSTNAME — the hostname for the new system
#   USERNAME — the primary user account name
#
# Example:
#   HOSTNAME=myhost USERNAME=myuser ./stage1.sh
#
# Partition layout:
#   nvme0n1p1 — 1M      — BIOS boot (do not touch)
#   nvme0n1p2 — 512M    — EFI System (reformatted)
#   nvme0n1p3 — 153.3G  — LUKS → LVM "internal" (opened, not reformatted)
#     swap    — 32G     — reformatted
#     root    — 100G    — reformatted
#     home    — ~21G    — PRESERVED
#   nvme0n1p4 — 800G    — ZFS (DO NOT TOUCH)
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

for cmd in cryptsetup mkfs.fat pacstrap genfstab arch-chroot fdisk blkid curl; do
    check_dependency "$cmd"
done

check_exists "${SCRIPT_DIR}/packages.txt"
check_exists "${SCRIPT_DIR}/services.txt"
check_exists "${SCRIPT_DIR}/user-services.txt"

echo "Partition table:"
fdisk -l "$DISK"
echo ""
log_message "${ZFS_PART} (ZFS) will NOT be touched"
log_message "/dev/${VG_NAME}/home will be PRESERVED"
echo ""
echo "The following will be ERASED:"
echo "  ${EFI_PART}       — EFI System (reformatted as FAT32)"
echo "  ${VG_NAME}/swap   — swap (reformatted)"
echo "  ${VG_NAME}/root   — root (reformatted as ext4)"
echo ""
echo "The following will be PRESERVED:"
echo "  ${LUKS_PART}      — LUKS container (opened, not reformatted)"
echo "  ${VG_NAME}/home   — home (mounted as-is)"
echo "  ${ZFS_PART}       — ZFS (not touched)"
echo ""
confirm "Proceed with installation?"

# ═══════════════════════════════════════════════════════════════════════
#  Phase 2: Format EFI, open LUKS, reformat swap + root
# ═══════════════════════════════════════════════════════════════════════

phase 2 "Format EFI, open LUKS, reformat swap + root"

step "Format EFI partition" \
    "mkfs.fat -F32 ${EFI_PART}"
mkfs.fat -F32 "$EFI_PART"

if cryptsetup status "$VG_NAME" >/dev/null 2>&1; then
    log_message "LUKS already open (from stage0)"
else
    step "Open existing LUKS container (enter passphrase)" \
        "cryptsetup open ${LUKS_PART} ${VG_NAME}"
    cryptsetup open "$LUKS_PART" "$VG_NAME"
fi

step "Reformat swap" \
    "mkswap /dev/${VG_NAME}/swap"
mkswap "/dev/${VG_NAME}/swap"

step "Reformat root filesystem" \
    "mkfs.ext4 /dev/${VG_NAME}/root"
mkfs.ext4 "/dev/${VG_NAME}/root"

# ═══════════════════════════════════════════════════════════════════════
#  Phase 3: Mount and install
# ═══════════════════════════════════════════════════════════════════════

phase 3 "Mount and install"

step "Mount filesystems" \
    "mount /dev/${VG_NAME}/root /mnt" \
    "mount ${EFI_PART} /mnt/efi" \
    "mount /dev/${VG_NAME}/home /mnt/home  (existing, preserved)" \
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
#  Stage 1 complete
# ═══════════════════════════════════════════════════════════════════════

phase "" "Stage 1 complete"

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

cleanup 0
