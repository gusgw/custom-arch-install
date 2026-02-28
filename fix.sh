#!/bin/bash
#
# fix.sh — Fix tobermory after failed stage2
#
# Fixes: USERNAME bug, missing ZFS, wrong sudoers, missing network config.
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

# ─── Configure network (iwd + systemd-networkd + systemd-resolved) ──

echo "Configuring network..."

# iwd: delegate IP config to systemd-networkd
sudo mkdir -p /etc/iwd
sudo tee /etc/iwd/main.conf > /dev/null <<'EOF'
[General]
EnableNetworkConfiguration=false
EnableIPv6=true
RoamThreshold=-70
RoamThreshold5G=-76

[Network]
NameResolvingService=systemd
EOF

# systemd-networkd: DHCP + DNS over TLS on wlan0
sudo mkdir -p /etc/systemd/network
sudo tee /etc/systemd/network/25-wireless.network > /dev/null <<'EOF'
[Match]
Name=wlan0

[Link]
RequiredForOnline=routable

[Network]
DHCP=yes
IPv6AcceptRA=yes
IPv6PrivacyExtensions=yes
IgnoreCarrierLoss=3s
DNS=9.9.9.9#dns.quad9.net
DNS=149.112.112.112#dns.quad9.net
DNS=2620:fe::fe#dns.quad9.net
DNS=2620:fe::9#dns.quad9.net
DNSOverTLS=yes
Domains=~.

[DHCPv4]
RouteMetric=600
UseDNS=yes

[DHCPv6]
UseDNS=yes

[IPv6AcceptRA]
UseDNS=yes
RouteMetric=600
EOF

# systemd-resolved: encrypted DNS with Quad9
sudo mkdir -p /etc/systemd/resolved.conf.d
sudo tee /etc/systemd/resolved.conf.d/encrypted-dns.conf > /dev/null <<'EOF'
[Resolve]
DNS=9.9.9.9#dns.quad9.net
DNS=149.112.112.112#dns.quad9.net
DNS=2620:fe::fe#dns.quad9.net
DNS=2620:fe::9#dns.quad9.net
FallbackDNS=1.1.1.1#cloudflare-dns.com
FallbackDNS=1.0.0.1#cloudflare-dns.com
FallbackDNS=2606:4700:4700::1111#cloudflare-dns.com
FallbackDNS=2606:4700:4700::1001#cloudflare-dns.com
DNSOverTLS=yes
DNSSEC=allow-downgrade
Domains=~.
Cache=yes
DNSStubListener=yes
ReadEtcHosts=yes
MulticastDNS=no
LLMNR=no
DNSStubListenerExtra=[::1]:53
EOF

# resolv.conf symlink
sudo rm -f /etc/resolv.conf
sudo ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf

echo "Restarting network services..."
sudo systemctl restart systemd-resolved
sudo systemctl restart systemd-networkd
sudo systemctl restart iwd

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
echo "Done. Now:"
echo "  1. Reconnect WiFi: iwctl station wlan0 connect <network>"
echo "  2. Import ZFS pool: sudo zpool import <poolname>"
echo ""
echo "Delete this script when finished:"
echo "  rm fix.sh"
