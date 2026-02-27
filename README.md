# Arch Linux Installer

Custom Arch Linux installer for an HP ZBook Studio 16 with LUKS+LVM and ZFS.

## Requirements

- An existing GPT partition table on `/dev/nvme0n1` with:
  - `p1` — 1M BIOS boot (untouched)
  - `p2` — 512M EFI System (reformatted)
  - `p3` — ~153G LUKS → LVM (reformatted)
  - `p4` — ZFS (untouched)
- A LUKS keyfile on separate media
- A USB drive for the live ISO

## Quick Start

### 1. Build the ISO (on an existing Arch machine)

```bash
./setup/build-iso.sh /dev/sdX
```

This installs `archiso`, clones this repo into the ISO, writes it to the USB drive, and adds login instructions.

### 2. Boot the USB

Boot the target machine from the USB. Instructions are displayed on login.

### 3. Run the installer

```bash
HOSTNAME=<hostname> USERNAME=<user> /root/setup/install.sh
```

The installer will:

1. Validate the environment (root, live USB, dependencies)
2. Format EFI and set up LUKS + LVM (swap, root, home)
3. Install packages with `pacstrap`
4. Pause for LUKS keyfile placement at `/mnt/root/key/internal.key`
5. Configure timezone, locale, mkinitcpio, GRUB
6. Create the user account (uid/gid 1000, wheel group)
7. Configure NVIDIA + Intel hybrid graphics
8. Enable system services

### 4. After reboot

- Clone your dotfiles and symlink configs
- Enable user services listed in `user-services.txt`
- Import ZFS pool: `sudo zpool import <pool>`
- Install AUR helper and AUR packages (`zfs-dkms-staging-git`, `sanoid`, etc.)
- Set up network configs (iwd, systemd-networkd, systemd-resolved)

## Files

| File | Purpose |
|---|---|
| `install.sh` | Main installer script |
| `build-iso.sh` | Builds custom Arch ISO and writes to USB |
| `packages.txt` | Native packages to install |
| `services.txt` | System services to enable |
| `user-services.txt` | User services to enable after first login |
| `bump.sh` | [BUMP](https://github.com/gusgw/bump) library for error handling |
| `return_codes.sh` | BUMP return codes |

## Environment Variables

| Variable | Required | Description |
|---|---|---|
| `HOSTNAME` | Yes | Hostname for the new system |
| `USERNAME` | Yes | Primary user account name (uid/gid 1000) |

## Partition Layout

The installer preserves the existing GPT table. It reformats `p2` (EFI) and `p3` (LUKS), and does not touch `p1` or `p4`.

LVM volumes created inside LUKS:

| Volume | Size | Filesystem | Mount |
|---|---|---|---|
| `internal-swap` | 32G | swap | swap |
| `internal-root` | 100G | ext4 | `/` |
| `internal-home` | remainder | ext4 | `/home` |

## Graphics

NVIDIA always on (`NVreg_DynamicPowerManagement=0x00`), Intel for display, NVIDIA for compute via `prime-run`. CPU governor set to `performance`.
