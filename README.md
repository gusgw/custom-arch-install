# Arch Linux Installer

Custom Arch Linux installer for an HP ZBook Studio 16 with LUKS+LVM and ZFS.

## Requirements

- An existing GPT partition table on `/dev/nvme0n1` with:
  - `p1` — 1M BIOS boot (untouched)
  - `p2` — 512M EFI System (reformatted)
  - `p3` — ~153G LUKS → LVM (opened, not reformatted)
  - `p4` — ZFS (untouched)
- The existing LUKS keyfile on separate media
- A USB drive for the live ISO

## Quick Start

### 1. Build the ISO (on an existing Arch machine)

```bash
./build-iso.sh /dev/sdX
```

This installs `archiso`, clones this repo into the ISO at `/root/setup/`, writes it to the USB drive, and adds login instructions.

### 2. Boot the USB

Boot the target machine from the USB. Instructions are displayed on login.

### 3. Stage 1 — format, mount, pacstrap

```bash
HOSTNAME=<hostname> USERNAME=<user> /root/setup/stage1.sh
```

Stage 1 will:

1. Validate the environment (root, live USB, dependencies)
2. Format EFI, open existing LUKS, reformat swap and root (home is preserved)
3. Mount filesystems
4. Add the Sublime Text repository and GPG key
5. Install packages with `pacstrap`
6. Generate fstab

### 4. Place the LUKS keyfile

After stage 1 completes, the filesystems remain mounted. Place the keyfile:

```bash
mkdir -p /mnt/root/key
cp /path/to/your/keyfile /mnt/root/key/internal.key
chmod 000 /mnt/root/key/internal.key
```

### 5. Stage 2 — system configuration

```bash
HOSTNAME=<hostname> USERNAME=<user> /root/setup/stage2.sh
```

Stage 2 will:

1. Verify stage 1 state (mounts, keyfile)
2. Optionally add keyfile to LUKS (skip if already registered)
3. Configure timezone, locale, hostname
4. Configure mkinitcpio with encrypt + lvm2 hooks
5. Install and configure GRUB with LUKS support
6. Create the user account (uid/gid 1000, wheel group)
7. Configure NVIDIA + Intel hybrid graphics and CPU governor
8. Enable system services
9. Set user password

### 6. After reboot

- Clone your dotfiles and symlink configs
- Enable user services listed in `user-services.txt`
- Import ZFS pool: `sudo zpool import <pool>`
- Install AUR helper and AUR packages (`zfs-dkms-staging-git`, `sanoid`, etc.)
- Set up network configs (iwd, systemd-networkd, systemd-resolved)

## Files

| File | Purpose |
|---|---|
| `stage1.sh` | Stage 1: format, mount, pacstrap |
| `stage2.sh` | Stage 2: keyfile, chroot config, users |
| `common.sh` | Shared configuration and helpers |
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

The installer preserves the existing GPT table and LUKS container. It opens LUKS, reformats swap and root, and preserves home.

LVM volumes inside LUKS (already exist, not recreated):

| Volume | Size | Filesystem | Action |
|---|---|---|---|
| `internal-swap` | 32G | swap | reformatted |
| `internal-root` | 100G | ext4 | reformatted |
| `internal-home` | remainder | ext4 | **preserved** |

## Graphics

NVIDIA always on (`NVreg_DynamicPowerManagement=0x00`), Intel for display, NVIDIA for compute via `prime-run`. CPU governor set to `performance`.
