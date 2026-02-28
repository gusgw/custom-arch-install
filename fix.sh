#!/bin/bash
#
# fix.sh — Fix tobermory after failed stage2 (USERNAME bug, missing ZFS, wrong sudoers)
#
# Run as gusgw on tobermory after first boot.
# One-time script — delete after use.
#

set -euo pipefail

if [[ $EUID -eq 0 ]]; then
    echo "Run as gusgw, not root"
    exit 1
fi

# ─── Fix sudoers ─────────────────────────────────────────────────────

echo "Fixing sudoers (NOPASSWD for wheel)..."
sudo sed -i 's/^# %wheel ALL=(ALL:ALL) NOPASSWD: ALL/%wheel ALL=(ALL:ALL) NOPASSWD: ALL/' /etc/sudoers

# ─── Create user if missing ──────────────────────────────────────────

if ! id gusgw &>/dev/null; then
    echo "Creating user gusgw..."
    sudo groupadd -g 1000 gusgw
    sudo useradd -u 1000 -g gusgw -G wheel,audio,network -s /bin/zsh -m gusgw
    echo "Set password for gusgw:"
    sudo passwd gusgw
else
    echo "User gusgw already exists"
fi

# ─── Install yay ─────────────────────────────────────────────────────

if ! command -v yay &>/dev/null; then
    echo "Installing yay..."
    git clone https://aur.archlinux.org/yay-bin.git /tmp/yay-bin
    (cd /tmp/yay-bin && makepkg -si)
    rm -rf /tmp/yay-bin
else
    echo "yay already installed"
fi

# ─── Install ZFS ─────────────────────────────────────────────────────

echo "Installing ZFS and sanoid..."
yay -S --needed zfs-dkms zfs-utils sanoid

echo "Loading ZFS module..."
sudo modprobe zfs

# ─── Enable ZFS services ─────────────────────────────────────────────

echo "Enabling ZFS services..."
sudo systemctl enable \
    zfs-import-scan.service \
    zfs-import.target \
    zfs-load-key.service \
    zfs-mount.service \
    zfs.target \
    zfs-volumes.target \
    zfs-volume-wait.service \
    zfs-zed.service \
    sanoid.timer

# ─── Done ─────────────────────────────────────────────────────────────

echo ""
echo "Done. Now import your ZFS pool:"
echo "  sudo zpool import <poolname>"
echo ""
echo "Delete this script when finished:"
echo "  rm fix.sh"
