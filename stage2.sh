#!/bin/bash
#
# stage2.sh — Configure system after keyfile placement
#
# Run as root from a live USB after stage1.sh has completed and the
# LUKS keyfile has been placed at /mnt/root/key/internal.key.
#
# Required environment variables:
#   INSTALL_HOST — the hostname for the new system
#   INSTALL_USER — the primary user account name
#
# Example:
#   INSTALL_HOST=myhost INSTALL_USER=myuser ./stage2.sh
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# shellcheck disable=SC1091
. "${SCRIPT_DIR}/common.sh"

# ═══════════════════════════════════════════════════════════════════════
#  Validate stage 1 completed
# ═══════════════════════════════════════════════════════════════════════

phase 4 "Validate stage 1"

validate_live_usb

check_dependency arch-chroot
check_dependency blkid

# Verify mounts from stage 1
for mp in /mnt /mnt/efi /mnt/home; do
    if ! mountpoint -q "$mp"; then
        log_message "${mp} is not mounted — run stage1.sh first"
        cleanup "$MISSING_INPUT"
    fi
done

check_exists "${SCRIPT_DIR}/services.txt"
check_exists "${SCRIPT_DIR}/user-services.txt"
check_exists /mnt/root/key/internal.key

log_message "Stage 1 state verified"

# ═══════════════════════════════════════════════════════════════════════
#  Phase 5: LUKS keyfile
# ═══════════════════════════════════════════════════════════════════════

phase 5 "LUKS keyfile"

echo "If the keyfile is already registered with LUKS (e.g. from a"
echo "previous install), you can skip this step."
echo ""
echo "  → cryptsetup luksAddKey ${LUKS_PART} /mnt/root/key/internal.key"
echo ""
read -r -p "Add keyfile to LUKS? [y/N] " response || true
if [[ "$response" =~ ^[Yy]$ ]]; then
    cryptsetup luksAddKey "$LUKS_PART" /mnt/root/key/internal.key
else
    log_message "Skipped luksAddKey (keyfile assumed already registered)"
fi

# ═══════════════════════════════════════════════════════════════════════
#  Phase 6: System configuration (chroot)
# ═══════════════════════════════════════════════════════════════════════

phase 6 "System configuration"

cp "${SCRIPT_DIR}/services.txt" /mnt/root/services.txt
echo "$INSTALL_HOST" > /mnt/root/hostname.txt
echo "$INSTALL_USER" > /mnt/root/username.txt

step "Set timezone and hardware clock" \
    "ln -sf /usr/share/zoneinfo/Australia/Sydney /etc/localtime" \
    "hwclock --systohc"
arch-chroot /mnt /bin/bash <<'CHROOT_TZ'
set -euo pipefail
ln -sf /usr/share/zoneinfo/Australia/Sydney /etc/localtime
hwclock --systohc
CHROOT_TZ

step "Set hostname to ${INSTALL_HOST}" \
    "echo ${INSTALL_HOST} > /etc/hostname"
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

step "Create user ${INSTALL_USER} and configure sudo" \
    "groupadd -g 1000 ${INSTALL_USER}" \
    "useradd -u 1000 -g ${INSTALL_USER} -G wheel,audio,network -s /bin/zsh -m ${INSTALL_USER}" \
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
#  Phase 7: Set user password
# ═══════════════════════════════════════════════════════════════════════

phase 7 "Set user password"

step "Set password for ${INSTALL_USER}" \
    "passwd ${INSTALL_USER}"
arch-chroot /mnt passwd "$INSTALL_USER"

# ═══════════════════════════════════════════════════════════════════════
#  Phase 8: Complete
# ═══════════════════════════════════════════════════════════════════════

phase 8 "Complete"

echo "Installation complete. After rebooting:"
echo ""
echo "  1. Remove the USB drive and boot into GRUB → Arch Linux"
echo "  2. Login as ${INSTALL_USER}"
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
