#!/bin/bash
#
# install.sh — Arch Linux installer for the HP ZBook Studio 16
#
# Run as root from a live USB booted with the custom archiso.
#
# Required environment variables:
#   HOSTNAME — the hostname for the new system
#   USERNAME — the primary user account name
#
# Example:
#   HOSTNAME=myhost USERNAME=myuser ./install.sh
#
# Partition layout (preserved, not recreated):
#   nvme0n1p1 — 1M      — BIOS boot (do not touch)
#   nvme0n1p2 — 512M    — EFI System (reformatted)
#   nvme0n1p3 — 153.3G  — LUKS → LVM "internal" (reformatted)
#   nvme0n1p4 — 800G    — ZFS (DO NOT TOUCH)
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

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

phase() {
    echo ""
    print_rule
    log_message "Phase $1: $2"
    echo "  Phase $1: $2"
    print_rule
    echo ""
}

# ═══════════════════════════════════════════════════════════════════════
#  Phase 1: Validate environment
# ═══════════════════════════════════════════════════════════════════════

phase 1 "Validate environment"

if [[ $EUID -ne 0 ]]; then
    log_message "Must run as root"
    cleanup "$SECURITY_FAILURE"
fi

if [[ ! -d /run/archiso ]]; then
    log_message "Not running from a live USB (no /run/archiso)"
    cleanup "$UNSAFE"
fi

for cmd in cryptsetup mkfs.fat pvcreate vgcreate lvcreate \
           pacstrap genfstab arch-chroot fdisk blkid; do
    check_dependency "$cmd"
done

check_exists "${SCRIPT_DIR}/packages.txt"
check_exists "${SCRIPT_DIR}/services.txt"
check_exists "${SCRIPT_DIR}/user-services.txt"

echo "Partition table:"
fdisk -l "$DISK"
echo ""
log_message "${ZFS_PART} (ZFS) will NOT be touched"
echo ""
echo "The following partitions will be ERASED:"
echo "  ${EFI_PART}  — EFI System (reformatted as FAT32)"
echo "  ${LUKS_PART} — LUKS + LVM (reformatted)"
echo ""
confirm "Proceed with installation?"

# ═══════════════════════════════════════════════════════════════════════
#  Phase 2: Format EFI + LUKS + LVM
# ═══════════════════════════════════════════════════════════════════════

phase 2 "Format EFI + LUKS + LVM"

log_message "Formatting EFI partition"
mkfs.fat -F32 "$EFI_PART"

log_message "Setting up LUKS on ${LUKS_PART}"
echo "You will be prompted for the LUKS passphrase (twice)."
cryptsetup luksFormat "$LUKS_PART"
cryptsetup open "$LUKS_PART" "$VG_NAME"

log_message "Creating LVM volumes"
pvcreate "/dev/mapper/${VG_NAME}"
vgcreate "$VG_NAME" "/dev/mapper/${VG_NAME}"
lvcreate -L 32G "$VG_NAME" -n swap
lvcreate -L 100G "$VG_NAME" -n root
lvcreate -l 100%FREE "$VG_NAME" -n home

log_message "Formatting filesystems"
mkswap "/dev/${VG_NAME}/swap"
mkfs.ext4 "/dev/${VG_NAME}/root"
mkfs.ext4 "/dev/${VG_NAME}/home"

# ═══════════════════════════════════════════════════════════════════════
#  Phase 3: Mount and install
# ═══════════════════════════════════════════════════════════════════════

phase 3 "Mount and install"

mount "/dev/${VG_NAME}/root" /mnt
mkdir -p /mnt/efi /mnt/home
mount "$EFI_PART" /mnt/efi
mount "/dev/${VG_NAME}/home" /mnt/home
swapon "/dev/${VG_NAME}/swap"
log_message "Filesystems mounted"

log_message "Installing packages with pacstrap"
# shellcheck disable=SC2046 — word splitting is intentional, pacstrap needs separate args
pacstrap -K /mnt $(grep -v '^#' "${SCRIPT_DIR}/packages.txt" | grep -v '^$')

log_message "Generating fstab"
genfstab -U /mnt >> /mnt/etc/fstab

# ═══════════════════════════════════════════════════════════════════════
#  Phase 4 (part 1): LUKS keyfile
# ═══════════════════════════════════════════════════════════════════════

phase 4 "System configuration"

log_message "Keyfile placement required"
echo ""
echo "The LUKS keyfile must be placed manually before continuing."
echo ""
echo "  1. Mount a USB or copy the keyfile to the live environment"
echo "  2. Place it at: /mnt/root/key/internal.key"
echo ""
echo "     mkdir -p /mnt/root/key"
echo "     cp /path/to/your/keyfile /mnt/root/key/internal.key"
echo "     chmod 000 /mnt/root/key/internal.key"
echo ""
confirm "Have you placed the keyfile at /mnt/root/key/internal.key?"

check_exists /mnt/root/key/internal.key

log_message "Adding keyfile to LUKS"
cryptsetup luksAddKey "$LUKS_PART" /mnt/root/key/internal.key

# ═══════════════════════════════════════════════════════════════════════
#  Phases 4–7: Chroot configuration
# ═══════════════════════════════════════════════════════════════════════

cp "${SCRIPT_DIR}/services.txt" /mnt/root/services.txt
echo "$HOSTNAME" > /mnt/root/hostname.txt
echo "$USERNAME" > /mnt/root/username.txt

log_message "Entering chroot for system configuration"

arch-chroot /mnt /bin/bash <<'CHROOT'
set -euo pipefail

echo "── Timezone ──"
ln -sf /usr/share/zoneinfo/Australia/Sydney /etc/localtime
hwclock --systohc

echo "── Hostname ──"
cp /root/hostname.txt /etc/hostname
rm -f /root/hostname.txt

echo "── Locale ──"
sed -i 's/^#en_AU.UTF-8 UTF-8/en_AU.UTF-8 UTF-8/' /etc/locale.gen
sed -i 's/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
locale-gen
echo 'LANG=en_AU.UTF-8' > /etc/locale.conf

echo "── mkinitcpio ──"
sed -i 's|^FILES=.*|FILES=(/root/key/internal.key)|' /etc/mkinitcpio.conf
sed -i 's|^HOOKS=.*|HOOKS=(base udev autodetect keyboard keymap modconf block encrypt lvm2 filesystems fsck)|' /etc/mkinitcpio.conf

chmod 000 /root/key/internal.key
mkinitcpio -P

echo "── GRUB ──"
sed -i 's/^#GRUB_ENABLE_CRYPTODISK=y/GRUB_ENABLE_CRYPTODISK=y/' /etc/default/grub

LUKS_UUID=$(blkid -s UUID -o value /dev/nvme0n1p3)
sed -i "s|^GRUB_CMDLINE_LINUX=.*|GRUB_CMDLINE_LINUX=\"cryptdevice=UUID=${LUKS_UUID}:internal cryptkey=rootfs:/root/key/internal.key nvidia-drm.modeset=1\"|" /etc/default/grub

sed -i 's|^GRUB_DEFAULT=.*|GRUB_DEFAULT=0|' /etc/default/grub
sed -i 's|^GRUB_TIMEOUT=.*|GRUB_TIMEOUT=5|' /etc/default/grub
grep -q '^GRUB_DISABLE_SUBMENU=' /etc/default/grub \
    || echo 'GRUB_DISABLE_SUBMENU=y' >> /etc/default/grub

grub-install --target=x86_64-efi --efi-directory=/efi --bootloader-id=GRUB
grub-mkconfig -o /boot/grub/grub.cfg

echo "── Users and groups ──"
INSTALL_USER=$(cat /root/username.txt)
rm -f /root/username.txt
groupadd -g 1000 "$INSTALL_USER"
useradd -u 1000 -g "$INSTALL_USER" -G wheel,audio,network -s /bin/zsh -m "$INSTALL_USER"
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

echo "── NVIDIA + Intel hybrid graphics ──"
mkdir -p /etc/modprobe.d
cat > /etc/modprobe.d/nvidia.conf <<'EOF'
options nvidia NVreg_DynamicPowerManagement=0x00
EOF

mkdir -p /etc/tmpfiles.d
cat > /etc/tmpfiles.d/cpu-governor.conf <<'EOF'
w /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor - - - - performance
EOF

echo "── Enable services ──"
while IFS= read -r service; do
    [[ -z "$service" || "$service" == \#* ]] && continue
    if systemctl enable "$service" 2>/dev/null; then
        echo "  Enabled $service"
    else
        echo "  WARNING: $service not available (may require AUR package)"
    fi
done < /root/services.txt

rm -f /root/services.txt
CHROOT

log_message "Chroot configuration complete"

# ═══════════════════════════════════════════════════════════════════════
#  Phase 5 (continued): Set user password
# ═══════════════════════════════════════════════════════════════════════

log_message "Set password for ${USERNAME}"
arch-chroot /mnt passwd "$USERNAME"

# ═══════════════════════════════════════════════════════════════════════
#  Phase 8: Post-install
# ═══════════════════════════════════════════════════════════════════════

phase 8 "Complete"

echo "Installation complete. After rebooting:"
echo ""
echo "  1. Remove the USB drive and boot into GRUB → Arch Linux"
echo "  2. Login as ${USERNAME}"
echo ""
echo "  3. Clone dotfiles:"
echo "       git clone <repo-url> ~/tilde"
echo ""
echo "  4. Symlink configs:"
echo "       ln -s ~/tilde/clovis/dot ~/dot"
echo "       ln -s ~/tilde/clovis/sh ~/sh"
echo ""
echo "  5. Enable user services:"
while IFS= read -r svc; do
    [[ -z "$svc" || "$svc" == \#* ]] && continue
    echo "       systemctl --user enable $svc"
done < "${SCRIPT_DIR}/user-services.txt"
echo ""
echo "  6. Import ZFS pool:"
echo "       sudo zpool import <poolname>"
echo ""
echo "  7. Install AUR helper:"
echo "       git clone https://aur.archlinux.org/yay-bin.git /tmp/yay-bin"
echo "       cd /tmp/yay-bin && makepkg -si"
echo ""
echo "  8. Install AUR packages:"
echo "       yay -S zfs-dkms-staging-git sanoid"
echo ""
echo "  9. Enable ZFS services:"
echo "       sudo systemctl enable zfs-import-scan.service zfs-import.target \\"
echo "         zfs-load-key.service zfs-mount.service zfs.target \\"
echo "         zfs-volumes.target zfs-volume-wait.service zfs-zed.service \\"
echo "         sanoid.timer"
echo ""
echo " 10. Set up network configs from dotfiles"
echo "       (iwd, systemd-networkd, systemd-resolved)"
echo ""
echo "Reboot now with: umount -R /mnt && reboot"

cleanup 0
