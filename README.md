# Arch Linux Installer

Custom Arch Linux installer for an HP ZBook Studio 16 with LUKS+LVM and ZFS.

## Requirements

- An NVMe drive (1TB+ for fresh install, existing layout for reinstall)
- A LUKS keyfile on separate media
- A USB drive for the live ISO

## Quick Start

### 1. Build the ISO (on an existing Arch machine)

```bash
./build-iso.sh /dev/sdX
```

This installs `archiso`, clones this repo into the ISO at `/root/setup/`, writes it to the USB drive, and adds login instructions.

### 2. Boot the USB

Boot the target machine from the USB. Connect to the network (e.g. `iwctl`). Instructions are displayed on login.

### 3a. Fresh install (blank disk): stage0 → keyfile → stage2

```bash
INSTALL_HOST=<host> INSTALL_USER=<user> /root/setup/stage0.sh
```

Stage 0 will:

1. Partition the disk (GPT: BIOS boot, EFI, LUKS, ZFS)
2. Create LUKS container and LVM volumes (swap, root, home)
3. Format home filesystem

Then run stage1 (stage0 leaves LUKS open for stage1).

### 3b. Reinstall (preserve /home): stage1 → keyfile → stage2

```bash
INSTALL_HOST=<host> INSTALL_USER=<user> /root/setup/stage1.sh
```

Stage 1 will:

1. Format EFI, open existing LUKS, reformat swap and root (home preserved)
2. Mount filesystems
3. Install packages with `pacstrap`
4. Generate fstab

### 4. Place the LUKS keyfile

After stage 0 or 1 completes, the filesystems remain mounted. Place the keyfile:

```bash
mkdir -p /mnt/root/key
cp /path/to/your/keyfile /mnt/root/key/internal.key
chmod 000 /mnt/root/key/internal.key
```

### 5. Stage 2 — system configuration

```bash
INSTALL_HOST=<host> INSTALL_USER=<user> /root/setup/stage2.sh
```

Stage 2 will:

1. Verify mounts and keyfile
2. Optionally add keyfile to LUKS (skip if already registered)
3. Configure timezone, locale, hostname
4. Configure mkinitcpio with encrypt + lvm2 hooks
5. Install and configure GRUB with LUKS support
6. Create the user account (uid/gid 1000, wheel group)
7. Configure NVIDIA + Intel hybrid graphics and CPU governor
8. Enable system services
9. Set user password

### 6. Stage 3 — post-reboot setup

After rebooting, clone the repo and run stage3 as the primary user (not root):

```bash
git clone <repo-url> ~/setup
cd ~/setup && ./stage3.sh
```

Stage 3 will:

1. Install yay (AUR helper)
2. Install AUR packages from `aur-packages.txt` (ZFS, sanoid)
3. Enable ZFS and AUR-dependent system services
4. Enable user services from `user-services.txt`

### 7. After stage 3

- Import or create ZFS pool: `sudo modprobe zfs && sudo zpool import <poolname>`
- Clone your dotfiles and symlink configs
- Set up network configs (iwd, systemd-networkd, systemd-resolved)

## Files

| File | Purpose |
|---|---|
| `stage0.sh` | Fresh install: partition, LUKS, LVM, format |
| `stage1.sh` | Reinstall: open existing LUKS, reformat swap+root, pacstrap |
| `stage2.sh` | Both paths: keyfile, chroot config, users, services |
| `stage3.sh` | Post-reboot: AUR helper, ZFS, user services |
| `common.sh` | Shared configuration and helpers |
| `build-iso.sh` | Builds custom Arch ISO and writes to USB |
| `packages.txt` | Native packages to install |
| `aur-packages.txt` | AUR packages to install post-reboot |
| `services.txt` | System services to enable |
| `user-services.txt` | User services to enable after first login |
| `bump.sh` | [BUMP](https://github.com/gusgw/bump) library for error handling |
| `return_codes.sh` | BUMP return codes |

## Environment Variables

| Variable | Required | Description |
|---|---|---|
| `INSTALL_HOST` | Yes | Hostname for the new system |
| `INSTALL_USER` | Yes | Primary user account name (uid/gid 1000) |

## Partition Layout

| Partition | Size | Type | Purpose |
|---|---|---|---|
| `nvme0n1p1` | 1M | EF02 | BIOS boot |
| `nvme0n1p2` | 512M | EF00 | EFI System |
| `nvme0n1p3` | 153G | 8300 | LUKS → LVM |
| `nvme0n1p4` | remainder | BF00 | ZFS |

LVM volumes inside LUKS:

| Volume | Size | Filesystem |
|---|---|---|
| `internal-swap` | 32G | swap |
| `internal-root` | 100G | ext4 |
| `internal-home` | remainder | ext4 |

## Graphics

NVIDIA always on (`NVreg_DynamicPowerManagement=0x00`), Intel for display, NVIDIA for compute via `prime-run`. CPU governor set to `performance`.
