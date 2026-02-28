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

# Bootstrap DNS immediately so subsequent steps can resolve hosts
echo 'nameserver 9.9.9.9' | sudo tee /etc/resolv.conf > /dev/null

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

echo "Restarting network services..."
sudo systemctl restart systemd-resolved
sudo systemctl restart systemd-networkd
sudo systemctl restart iwd

# Switch to resolved stub now that systemd-resolved is running
sudo rm -f /etc/resolv.conf
sudo ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf

echo "Waiting for network to come back up..."
for i in $(seq 1 30); do
    if ping -c 1 -W 2 archlinux.org >/dev/null 2>&1; then
        echo "Network is up"
        break
    fi
    if [[ $i -eq 30 ]]; then
        echo "Network did not come back. Reconnect WiFi manually:"
        echo "  iwctl station wlan0 connect <network>"
        echo "Then re-run this script."
        exit 1
    fi
    sleep 1
done

# ─── Add Sublime Text repo to installed system ───────────────────────

if ! grep -q '\[sublime-text\]' /etc/pacman.conf; then
    echo "Adding Sublime Text repository..."
    curl -O https://download.sublimetext.com/sublimehq-pub.gpg
    sudo pacman-key --add sublimehq-pub.gpg
    sudo pacman-key --lsign-key 8A8F901A
    rm -f sublimehq-pub.gpg
    echo -e '\n[sublime-text]\nServer = https://download.sublimetext.com/arch/stable/x86_64' | sudo tee -a /etc/pacman.conf > /dev/null
else
    echo "Sublime Text repository already configured"
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

echo "Installing custom zfs-load-key.service (package version is masked)..."
sudo tee /etc/systemd/system/zfs-load-key.service > /dev/null <<'EOF'
[Unit]
Description=Load encryption keys
DefaultDependencies=no
After=zfs-import.target
Before=zfs-mount.service
Requires=zfs-import.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/zfs load-key -a
StandardInput=tty-force

[Install]
WantedBy=zfs-mount.service
EOF
sudo systemctl daemon-reload

echo "Enabling ZFS services..."
sudo systemctl enable \
    zfs-import-scan.service \
    zfs-import.target \
    zfs-load-key.service \
    zfs-mount.service \
    zfs-volume-wait.service \
    zfs-volumes.target \
    zfs.target \
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
