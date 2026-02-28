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

for cmd in cryptsetup mkfs.fat pacstrap genfstab arch-chroot fdisk blkid; do
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

step "Open existing LUKS container (enter passphrase)" \
    "cryptsetup open ${LUKS_PART} ${VG_NAME}"
cryptsetup open "$LUKS_PART" "$VG_NAME"

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

step "Install packages with pacstrap" \
    "pacstrap -K /mnt <packages from packages.txt>"
# shellcheck disable=SC2046 — word splitting is intentional, pacstrap needs separate args
pacstrap -K /mnt $(grep -v '^#' "${SCRIPT_DIR}/packages.txt" | grep -v '^$')

step "Generate fstab" \
    "genfstab -U /mnt >> /mnt/etc/fstab"
genfstab -U /mnt >> /mnt/etc/fstab

# ═══════════════════════════════════════════════════════════════════════
#  Phase 4: LUKS keyfile
# ═══════════════════════════════════════════════════════════════════════

phase 4 "LUKS keyfile"

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

step "Add keyfile to LUKS" \
    "cryptsetup luksAddKey ${LUKS_PART} /mnt/root/key/internal.key"
cryptsetup luksAddKey "$LUKS_PART" /mnt/root/key/internal.key

# ═══════════════════════════════════════════════════════════════════════
#  Phase 5: System configuration (chroot)
# ═══════════════════════════════════════════════════════════════════════

phase 5 "System configuration"

cp "${SCRIPT_DIR}/services.txt" /mnt/root/services.txt
echo "$HOSTNAME" > /mnt/root/hostname.txt
echo "$USERNAME" > /mnt/root/username.txt

step "Set timezone and hardware clock" \
    "ln -sf /usr/share/zoneinfo/Australia/Sydney /etc/localtime" \
    "hwclock --systohc"
arch-chroot /mnt /bin/bash <<'CHROOT_TZ'
set -euo pipefail
ln -sf /usr/share/zoneinfo/Australia/Sydney /etc/localtime
hwclock --systohc
CHROOT_TZ

step "Set hostname to ${HOSTNAME}" \
    "echo ${HOSTNAME} > /etc/hostname"
arch-chroot /mnt /bin/bash <<'CHROOT_HOST'
set -euo pipefail
cp /root/hostname.txt /etc/hostname
rm -f /root/hostname.txt
CHROOT_HOST

step "Configure locale" \
    "Uncomment en_AU.UTF-8 and en_US.UTF-8 in /etc/locale.gen" \
    "locale-gen" \
    "LANG=en_AU.UTF-8 > /etc/locale.conf"
arch-chroot /mnt /bin/bash <<'CHROOT_LOCALE'
set -euo pipefail
sed -i 's/^#en_AU.UTF-8 UTF-8/en_AU.UTF-8 UTF-8/' /etc/locale.gen
sed -i 's/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
locale-gen
echo 'LANG=en_AU.UTF-8' > /etc/locale.conf
CHROOT_LOCALE

step "Configure mkinitcpio (encrypt + lvm2 hooks, keyfile)" \
    "FILES=(/root/key/internal.key)" \
    "HOOKS=(base udev autodetect keyboard keymap modconf block encrypt lvm2 filesystems fsck)" \
    "mkinitcpio -P"
arch-chroot /mnt /bin/bash <<'CHROOT_MKINIT'
set -euo pipefail
sed -i 's|^FILES=.*|FILES=(/root/key/internal.key)|' /etc/mkinitcpio.conf
sed -i 's|^HOOKS=.*|HOOKS=(base udev autodetect keyboard keymap modconf block encrypt lvm2 filesystems fsck)|' /etc/mkinitcpio.conf
chmod 000 /root/key/internal.key
mkinitcpio -P
CHROOT_MKINIT

step "Install and configure GRUB" \
    "GRUB_ENABLE_CRYPTODISK=y" \
    "GRUB_CMDLINE_LINUX=\"cryptdevice=UUID=<luks-uuid>:internal ...\"" \
    "grub-install --target=x86_64-efi --efi-directory=/efi --bootloader-id=GRUB" \
    "grub-mkconfig -o /boot/grub/grub.cfg"
arch-chroot /mnt /bin/bash <<'CHROOT_GRUB'
set -euo pipefail
sed -i 's/^#GRUB_ENABLE_CRYPTODISK=y/GRUB_ENABLE_CRYPTODISK=y/' /etc/default/grub

LUKS_UUID=$(blkid -s UUID -o value /dev/nvme0n1p3)
sed -i "s|^GRUB_CMDLINE_LINUX=.*|GRUB_CMDLINE_LINUX=\"cryptdevice=UUID=${LUKS_UUID}:internal cryptkey=rootfs:/root/key/internal.key nvidia-drm.modeset=1\"|" /etc/default/grub

sed -i 's|^GRUB_DEFAULT=.*|GRUB_DEFAULT=0|' /etc/default/grub
sed -i 's|^GRUB_TIMEOUT=.*|GRUB_TIMEOUT=5|' /etc/default/grub
grep -q '^GRUB_DISABLE_SUBMENU=' /etc/default/grub \
    || echo 'GRUB_DISABLE_SUBMENU=y' >> /etc/default/grub

grub-install --target=x86_64-efi --efi-directory=/efi --bootloader-id=GRUB
grub-mkconfig -o /boot/grub/grub.cfg
CHROOT_GRUB

step "Create user ${USERNAME} and configure sudo" \
    "groupadd -g 1000 ${USERNAME}" \
    "useradd -u 1000 -g ${USERNAME} -G wheel,audio,network -s /bin/zsh -m ${USERNAME}" \
    "Uncomment %wheel ALL=(ALL:ALL) ALL in /etc/sudoers"
arch-chroot /mnt /bin/bash <<'CHROOT_USER'
set -euo pipefail
INSTALL_USER=$(cat /root/username.txt)
rm -f /root/username.txt
groupadd -g 1000 "$INSTALL_USER"
useradd -u 1000 -g "$INSTALL_USER" -G wheel,audio,network -s /bin/zsh -m "$INSTALL_USER"
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers
CHROOT_USER

step "Configure NVIDIA and CPU governor" \
    "nvidia: NVreg_DynamicPowerManagement=0x00 → /etc/modprobe.d/nvidia.conf" \
    "cpu: scaling_governor=performance → /etc/tmpfiles.d/cpu-governor.conf"
arch-chroot /mnt /bin/bash <<'CHROOT_HW'
set -euo pipefail
mkdir -p /etc/modprobe.d
cat > /etc/modprobe.d/nvidia.conf <<'NVIDIA'
options nvidia NVreg_DynamicPowerManagement=0x00
NVIDIA

mkdir -p /etc/tmpfiles.d
cat > /etc/tmpfiles.d/cpu-governor.conf <<'CPUGOV'
w /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor - - - - performance
CPUGOV
CHROOT_HW

step "Enable system services from services.txt" \
    "systemctl enable <each service in services.txt>"
arch-chroot /mnt /bin/bash <<'CHROOT_SVC'
set -euo pipefail
while IFS= read -r service; do
    [[ -z "$service" || "$service" == \#* ]] && continue
    if systemctl enable "$service" 2>/dev/null; then
        echo "  Enabled $service"
    else
        echo "  WARNING: $service not available (may require AUR package)"
    fi
done < /root/services.txt
rm -f /root/services.txt
CHROOT_SVC

log_message "System configuration complete"

# ═══════════════════════════════════════════════════════════════════════
#  Phase 6: Set user password
# ═══════════════════════════════════════════════════════════════════════

phase 6 "Set user password"

step "Set password for ${USERNAME}" \
    "passwd ${USERNAME}"
arch-chroot /mnt passwd "$USERNAME"

# ═══════════════════════════════════════════════════════════════════════
#  Phase 7: Complete
# ═══════════════════════════════════════════════════════════════════════

phase 7 "Complete"

echo "Installation complete. After rebooting:"
echo ""
echo "  1. Remove the USB drive and boot into GRUB → Arch Linux"
echo "  2. Login as ${USERNAME}"
echo ""
echo "  3. Clone and set up dotfiles"
echo ""
echo "  4. Enable user services:"
while IFS= read -r svc; do
    [[ -z "$svc" || "$svc" == \#* ]] && continue
    echo "       systemctl --user enable $svc"
done < "${SCRIPT_DIR}/user-services.txt"
echo ""
echo "  5. Import ZFS pool:"
echo "       sudo zpool import <poolname>"
echo ""
echo "  6. Install AUR helper:"
echo "       git clone https://aur.archlinux.org/yay-bin.git /tmp/yay-bin"
echo "       cd /tmp/yay-bin && makepkg -si"
echo ""
echo "  7. Install AUR packages:"
echo "       yay -S zfs-dkms-staging-git sanoid"
echo ""
echo "  8. Enable ZFS services:"
echo "       sudo systemctl enable zfs-import-scan.service zfs-import.target \\"
echo "         zfs-load-key.service zfs-mount.service zfs.target \\"
echo "         zfs-volumes.target zfs-volume-wait.service zfs-zed.service \\"
echo "         sanoid.timer"
echo ""
echo "  9. Set up network configs from dotfiles"
echo "       (iwd, systemd-networkd, systemd-resolved)"
echo ""
echo "Reboot now with: umount -R /mnt && reboot"

cleanup 0
