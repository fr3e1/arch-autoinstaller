# Arch Linux Autoinstaller

An automated Arch Linux installer that you configure with a **web dashboard**, a
**terminal dashboard**, or a plain config file. It validates everything (including
that all packages exist) **before** touching your disk, then partitions,
installs and configures a ready-to-use system.

> ⚠️ **The selected disk is completely erased.** Back up your data first. I am not
> responsible for any data loss.

Proof the original version works: https://youtu.be/yvbMFVl8CTA

## Features

- **Web dashboard**: pick options from your phone or PC while the target machine runs the live ISO
- **Terminal dashboard**: the same options in a pure-bash menu, nothing extra needed
- Presets: Minimal, Desktop, Gaming, Server
- UEFI and BIOS, SATA / NVMe / eMMC disks
- ext4, btrfs (with subvolumes and zstd compression) or xfs
- Optional LUKS2 full-disk encryption
- GRUB or systemd-boot
- Kernels: `linux`, `linux-lts`, `linux-zen`, `linux-hardened`
- 10 desktops (Xfce, GNOME, KDE Plasma, Cinnamon, MATE, LXQt, Budgie, i3, Sway,
  Hyprland) with a matching display manager picked for you
- Detects your CPU microcode and GPU drivers (Intel / AMD / NVIDIA), including
  VirtualBox, VMware, QEMU and Hyper-V guest tools
- zram or swap file, PipeWire audio, Bluetooth, printing, SSH, ufw / firewalld
- Mirror ranking with reflector, parallel downloads, multilib, AUR helper (yay / paru)
- Checks your config, the network and all package names before erasing anything
- Clear install plan and a typed confirmation before the disk is wiped
- Full log saved to `/var/log/arch-autoinstaller/` on the new system
- Passwords are never written to disk or to the log

## Quick start

Boot the [Arch Linux ISO](https://archlinux.org/download/), connect to the
internet (`iwctl` for Wi-Fi), then:

```bash
pacman -Sy git
git clone https://github.com/fr3e1/arch-autoinstaller.git
cd arch-autoinstaller
```

Then choose how you want to configure it.

### Option 1: web dashboard (recommended)

```bash
./install.sh --web
```

The terminal prints a link such as `http://192.168.1.50:8080/?token=...`. Open it
on any phone or computer on the same network, pick your options, and press
**Save & install**. The installer continues in the terminal: it asks for
passwords and a final confirmation, then installs.

The dashboard shows the target machine's disks, boot mode, CPU and GPU. Use
**Check plan** to see exactly which packages and services will be installed.
The token in the link keeps other devices on your network out.

You can also open `dashboard/index.html` directly in a browser on any computer
to build a config in advance. Use **Download config** and copy the file to the
installer as `config`.

### Option 2: terminal dashboard

```bash
./install.sh --menu
```

Type a number to change an option, `p` for presets, `s` to save, `i` to save
and install.

### Option 3: edit the config by hand

```bash
nano config
./install.sh
```

Every option is documented in [`config`](config). Leave `DISK` or `USERNAME`
empty to be asked during the install.

## Command line

```
./install.sh [options]
  -c, --config FILE   use FILE instead of ./config
  -m, --menu          terminal dashboard
  -w, --web [PORT]    web dashboard (default port 8080)
      --check         validate the config and print the install plan
      --dry-run       also print the partition layout and the chroot script
  -y, --yes           skip the final "type the disk name" confirmation
  -h, --help
```

For unattended installs, set `USER_PASSWORD`, `ROOT_PASSWORD` (when
`ROOT_PASSWORD_MODE=prompt`) and `LUKS_PASSWORD` (when `ENCRYPT=yes`) in the
environment and use `--yes`.

## Disk layout

| Boot mode | Partitions |
|-----------|------------|
| UEFI | GPT: EFI system partition (`EFI_SIZE`, mounted at `/boot`) + root |
| BIOS | MBR: root (bootable) |
| BIOS + encryption | MBR: `/boot` (1 GiB, ext4) + encrypted root |

With btrfs, the root holds the subvolumes `@`, `@home`, `@log`, `@pkg` and
`@snapshots` (plus `@swap` when using a swap file).

## Troubleshooting

**Keyring / signature errors when installing git**: refresh the keyring:

```bash
pacman -Sy archlinux-keyring
```

If that still fails:

```bash
pacman-key --init && pacman-key --populate
```

The installer refreshes the keyring itself before installing.

**Finding your time zone**:

```bash
timedatectl list-timezones | grep Europe
```

**Finding your locale**: see `/usr/share/i18n/SUPPORTED`; most people want
`en_US.UTF-8`.

**The install failed**: the error and the failing line are printed, and the
full log is at `/tmp/arch-autoinstaller.log`. Partitions stay mounted at
`/mnt` so you can look around. Fix the problem and run `./install.sh` again;
it starts over from a clean disk.

## Development

```bash
./tests/run.sh
```

The tests run offline without root. They check syntax, validate many option
combinations with `--check` / `--dry-run`, test config saving, and exercise the
web dashboard API. They never touch a disk.

Project layout:

| Path | Purpose |
|------|---------|
| `install.sh` | Entry point: validation, partitioning, pacstrap, passwords |
| `config` | Your install options |
| `lib/options.conf` | Option schema (allowed values) used by every part |
| `lib/packages.sh` | Turns options into packages and services |
| `lib/chroot-setup.sh` | Runs inside the new system (locale, bootloader, users…) |
| `lib/menu.sh` | Terminal dashboard |
| `dashboard/` | Web dashboard (`server.py`, standard library only) |
| `tests/run.sh` | Test suite |

## License

[MIT](LICENSE)
