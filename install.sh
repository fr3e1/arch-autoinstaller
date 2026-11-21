#!/usr/bin/env bash
# arch-autoinstaller - automated Arch Linux installation
# https://github.com/fr3e1/arch-autoinstaller
set -Eeuo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
VERSION=2.0.0
CONFIG_FILE="$SCRIPT_DIR/config"
LOG_FILE=/tmp/arch-autoinstaller.log
MNT=/mnt
MODE=install # install | check | dry-run
ASSUME_YES=no
RUN_MENU=no
RUN_WEB=no
WEB_PORT=8080

# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/packages.sh
source "$SCRIPT_DIR/lib/packages.sh"
# shellcheck source=lib/menu.sh
source "$SCRIPT_DIR/lib/menu.sh"

usage() {
  cat <<EOF
arch-autoinstaller $VERSION

Usage: ./install.sh [options]

  -c, --config FILE   use FILE instead of ./config
  -m, --menu          open the terminal dashboard to edit the config first
  -w, --web [PORT]    start the web dashboard (default port $WEB_PORT); pick
                      options from any browser on your network, then press
                      "Save & install" to continue here
      --check         validate the config and print the install plan
      --dry-run       like --check, and also print the partition layout and
                      the script that runs inside the new system
  -y, --yes           do not ask for the final confirmation (still asks for
                      passwords unless USER_PASSWORD / ROOT_PASSWORD /
                      LUKS_PASSWORD are set in the environment)
  -h, --help          show this help

Everything on the selected disk is erased. Back up your data first.
EOF
}

while (($#)); do
  case $1 in
    -c|--config) CONFIG_FILE=$(realpath -m "${2:?--config needs a file}"); shift ;;
    -m|--menu) RUN_MENU=yes ;;
    -w|--web)
      RUN_WEB=yes
      if [[ "${2:-}" =~ ^[0-9]+$ ]]; then WEB_PORT=$2; shift; fi ;;
    --check) MODE=check ;;
    --dry-run) MODE=dry-run ;;
    -y|--yes) ASSUME_YES=yes ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "Unknown option: $1" ;;
  esac
  shift
done

load_schema "$SCRIPT_DIR/lib/options.conf"
load_config "$CONFIG_FILE"
BOOT_MODE=$(boot_mode)

# ------------------------------------------------------------ dashboards ---
if [[ "$RUN_WEB" == yes ]]; then
  command -v python3 >/dev/null || die "python3 is required for the web dashboard (use --menu instead)."
  set +e
  python3 "$SCRIPT_DIR/dashboard/server.py" --config "$CONFIG_FILE" --port "$WEB_PORT" --installer "$SCRIPT_DIR/install.sh"
  rc=$?
  set -e
  [[ $rc -eq 10 ]] || exit "$rc" # 10 = "Save & install" pressed
  load_config "$CONFIG_FILE"
fi

if [[ "$RUN_MENU" == yes ]]; then
  run_menu "$CONFIG_FILE" || exit 0 # non-zero = user quit without installing
  load_config "$CONFIG_FILE"
fi

# ------------------------------------------------------------ validation ---
validate_config || die "Fix the config ($CONFIG_FILE) and try again. Tip: ./install.sh --menu"

if [[ "$BOOTLOADER" == systemd-boot && "$BOOT_MODE" == BIOS ]]; then
  warn "systemd-boot needs UEFI; this machine booted in BIOS mode, so GRUB will be used."
  BOOTLOADER=grub
fi

resolve_packages "$BOOT_MODE"

print_summary() {
  local disk_desc=${DISK:-"(asked during install)"}
  cat <<EOF

${C_BOLD}Install plan${C_RESET}
  Boot mode        $BOOT_MODE
  Disk             $disk_desc  ${C_RED}(will be erased)${C_RESET}
  Filesystem       $FILESYSTEM$([[ "$ENCRYPT" == yes ]] && echo " on LUKS2")
  Swap             $SWAP$([[ "$SWAP" == file ]] && echo " ($SWAP_SIZE)")
  Bootloader       $BOOTLOADER
  Kernel           $KERNEL
  Hostname         $HOSTNAME
  Time zone        $TIMEZONE
  Locale / keymap  $LOCALE / $KEYMAP
  User             ${USERNAME:-"(asked during install)"} (shell: $USER_SHELL, sudo: $USER_SUDO)
  Root account     $ROOT_PASSWORD_MODE
  Desktop          $DESKTOP (display manager: $RESOLVED_DM)
  GPU / microcode  $RESOLVED_GPU / $RESOLVED_UCODE
  Audio            $AUDIO
  Network          $NETWORK$([[ "$SSH" == yes ]] && echo ", sshd")$([[ "$FIREWALL" != none ]] && echo ", $FIREWALL")
  AUR helper       $AUR_HELPER
  Packages (${#PKGS[@]})    ${PKGS[*]}
  Services         ${SERVICES[*]} ${RESOLVED_DM/none/}

EOF
}

partition_layout() {
  if [[ "$BOOT_MODE" == UEFI ]]; then
    printf 'label: gpt\n,%s,U\n,,L\n' "$EFI_SIZE"
  elif [[ "$ENCRYPT" == yes ]]; then
    printf 'label: dos\n,1G,L,*\n,,L\n'
  else
    printf 'label: dos\n,,L,*\n'
  fi
}

chroot_script() {
  # Variables for the chroot script, followed by its body.
  declare -p TIMEZONE LOCALE KEYMAP HOSTNAME USERNAME USER_SHELL USER_SUDO \
    BOOTLOADER BOOT_MODE DISK ENCRYPT FILESYSTEM SWAP KERNEL RESOLVED_UCODE \
    RESOLVED_DM RESOLVED_GPU SERVICES PARALLEL_DOWNLOADS MULTILIB AUR_HELPER \
    FIREWALL SSH NETWORK LUKS_UUID ROOT_UUID
  cat "$SCRIPT_DIR/lib/chroot-setup.sh"
}

if [[ "$MODE" != install ]]; then
  print_summary
  if [[ "$MODE" == dry-run ]]; then
    LUKS_UUID='<luks-uuid>' ROOT_UUID='<root-uuid>'
    echo "${C_BOLD}Partition layout (sfdisk)${C_RESET}"
    partition_layout | sed 's/^/  /'
    echo
    echo "${C_BOLD}Script that will run inside the new system${C_RESET}"
    chroot_script
  fi
  info "Config is valid."
  exit 0
fi

# ================================================================ install ===
[[ $EUID -eq 0 ]] || die "Run this as root from the Arch Linux live ISO (try: sudo ./install.sh)."
for cmd in pacstrap arch-chroot genfstab sfdisk wipefs blkid; do
  command -v "$cmd" >/dev/null || die "'$cmd' not found. Run this from the Arch Linux live ISO."
done

cleanup_on_error() {
  local rc=$? line=$1 cmd=$2
  trap - ERR
  err "Install failed (exit $rc) on line $line: $cmd"
  err "Full log: $LOG_FILE"
  if mountpoint -q "$MNT"; then
    cp "$LOG_FILE" "$MNT/var/log/arch-autoinstaller-failed.log" 2>/dev/null || true
  fi
  warn "Partitions are left mounted under $MNT so you can inspect them."
  exit "$rc"
}
trap 'cleanup_on_error $LINENO "$BASH_COMMAND"' ERR

clear 2>/dev/null || true
info "arch-autoinstaller $VERSION ($BOOT_MODE mode)"
[[ "$BOOT_MODE" == BIOS ]] && warn "Booted in BIOS/legacy mode. Boot the ISO in UEFI mode if your machine supports it."

step "Checking internet connection"
if ! curl -fsS --max-time 10 -o /dev/null https://archlinux.org; then
  die "No internet connection. Use 'iwctl' for Wi-Fi, then try again."
fi

# ------------------------------------------------------------ pick disk ---
iso_disk() {
  local src
  src=$(findmnt -no SOURCE /run/archiso/bootmnt 2>/dev/null || true)
  [[ -n "$src" ]] && lsblk -npo PKNAME "$src" 2>/dev/null | head -1
}

if [[ -z "$DISK" ]]; then
  mapfile -t disks < <(list_disks)
  skip=$(iso_disk || true)
  choices=()
  for d in "${disks[@]}"; do
    [[ -n "$skip" && "${d%% *}" == "$skip" ]] && continue
    choices+=("$d")
  done
  ((${#choices[@]})) || die "No installable disks found."
  echo
  echo "${C_BOLD}Available disks:${C_RESET}"
  for i in "${!choices[@]}"; do printf '  %d) %s\n' $((i + 1)) "${choices[$i]}"; done
  while true; do
    read -rp "Install to disk [1-${#choices[@]}]: " n
    if [[ "$n" =~ ^[0-9]+$ ]] && ((n >= 1 && n <= ${#choices[@]})); then
      DISK=${choices[$((n - 1))]%% *}
      break
    fi
  done
fi
[[ -b "$DISK" ]] || die "$DISK is not a block device."
[[ "$(lsblk -dno TYPE "$DISK")" == disk ]] || die "$DISK is not a whole disk (pick e.g. /dev/sda, not /dev/sda1)."
[[ "$DISK" == "$(iso_disk || true)" ]] && die "$DISK is the drive the live ISO booted from."
disk_bytes=$(lsblk -bdno SIZE "$DISK")
((disk_bytes >= 8 * 1024 ** 3)) || die "$DISK is smaller than 8 GiB."
((disk_bytes >= 20 * 1024 ** 3)) || [[ "$DESKTOP" == none ]] || warn "$DISK is under 20 GiB; a desktop install may run out of space."

# -------------------------------------------------------------- accounts ---
while [[ -z "$USERNAME" ]]; do
  read -rp "Username: " USERNAME
  if ! msg=$(validate_option USERNAME "$USERNAME") || [[ -z "$USERNAME" || "$USERNAME" == root ]]; then
    err "Invalid username. Use lowercase letters, digits, '-' and '_'."
    USERNAME=''
  fi
done

ask_password() { # ask_password VAR "Prompt"
  local var=$1 prompt=$2 a b
  if [[ -n "${!var:-}" ]]; then return; fi
  while true; do
    read -rsp "$prompt: " a; echo
    read -rsp "Confirm $prompt: " b; echo
    if [[ -z "$a" ]]; then err "Password cannot be empty."
    elif [[ "$a" != "$b" ]]; then err "Passwords do not match."
    else printf -v "$var" '%s' "$a"; return
    fi
  done
}
USER_PASSWORD=${USER_PASSWORD:-}
ROOT_PASSWORD=${ROOT_PASSWORD:-}
LUKS_PASSWORD=${LUKS_PASSWORD:-}
ask_password USER_PASSWORD "Password for $USERNAME"
case $ROOT_PASSWORD_MODE in
  same) ROOT_PASSWORD=$USER_PASSWORD ;;
  prompt) ask_password ROOT_PASSWORD "Root password" ;;
esac
[[ "$ENCRYPT" == yes ]] && ask_password LUKS_PASSWORD "Disk encryption passphrase"

# ---------------------------------------------------------- confirmation ---
print_summary
lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINTS "$DISK" | sed 's/^/  /'
echo
if [[ "$ASSUME_YES" != yes ]]; then
  read -rp "${C_RED}${C_BOLD}ALL DATA ON $DISK WILL BE ERASED.${C_RESET} Type the disk name ($DISK) to continue: " answer
  [[ "$answer" == "$DISK" || "/dev/$answer" == "$DISK" ]] || die "Aborted, nothing was changed."
fi

# Log everything from here on (passwords are never printed).
exec > >(tee -a "$LOG_FILE") 2>&1
info "Installation started $(date -Is)"

# ------------------------------------------------------------ host prep ---
info "Preparing the live environment"
timedatectl set-ntp true 2>/dev/null || true
sed -Ei "s/^#?\s*ParallelDownloads.*/ParallelDownloads = $PARALLEL_DOWNLOADS/" /etc/pacman.conf
if [[ "$MULTILIB" == yes ]] && ! grep -q '^\[multilib\]' /etc/pacman.conf; then
  sed -i '/^#\[multilib\]/{s/^#//;n;s/^#//}' /etc/pacman.conf
fi
if [[ -n "$MIRROR_COUNTRY" ]]; then
  step "Ranking mirrors for: $MIRROR_COUNTRY"
  reflector --country "$MIRROR_COUNTRY" --protocol https --latest 20 --sort rate \
    --save /etc/pacman.d/mirrorlist || warn "reflector failed, keeping the current mirror list."
fi
step "Refreshing package databases and keyring"
pacman -Sy --noconfirm --needed archlinux-keyring

step "Checking that all packages exist"
missing=$(pacman -Sp --noconfirm "${PKGS[@]}" 2>&1 >/dev/null | sed -n "s/.*target not found: //p" || true)
[[ -z "$missing" ]] || die "These packages do not exist: $(echo "$missing" | tr '\n' ' ') - fix ADDITIONAL_PACKAGES. Nothing was changed."

# ------------------------------------------------------------ partition ---
info "Partitioning $DISK"
swapoff -a 2>/dev/null || true
if mountpoint -q "$MNT"; then umount -R "$MNT"; fi
[[ -e /dev/mapper/cryptroot ]] && cryptsetup close cryptroot
while read -r part; do
  umount -q "$part" 2>/dev/null || true
done < <(lsblk -lnpo NAME "$DISK" | tac)
lsblk -lnpo NAME "$DISK" | tac | xargs -r wipefs -af >/dev/null
partition_layout | sfdisk --wipe always --wipe-partitions always "$DISK"
partprobe "$DISK" 2>/dev/null || true
udevadm settle

if [[ "$BOOT_MODE" == UEFI ]]; then
  BOOT_PART=$(partition_path "$DISK" 1); ROOT_PART=$(partition_path "$DISK" 2)
elif [[ "$ENCRYPT" == yes ]]; then
  BOOT_PART=$(partition_path "$DISK" 1); ROOT_PART=$(partition_path "$DISK" 2)
else
  BOOT_PART=''; ROOT_PART=$(partition_path "$DISK" 1)
fi

LUKS_UUID=''
ROOT_DEV=$ROOT_PART
if [[ "$ENCRYPT" == yes ]]; then
  step "Encrypting $ROOT_PART (LUKS2)"
  printf '%s' "$LUKS_PASSWORD" | cryptsetup luksFormat --type luks2 -q --key-file=- "$ROOT_PART"
  printf '%s' "$LUKS_PASSWORD" | cryptsetup open --key-file=- "$ROOT_PART" cryptroot
  LUKS_UUID=$(blkid -s UUID -o value "$ROOT_PART")
  ROOT_DEV=/dev/mapper/cryptroot
fi

info "Formatting"
if [[ -n "$BOOT_PART" ]]; then
  if [[ "$BOOT_MODE" == UEFI ]]; then mkfs.fat -F 32 -n EFI "$BOOT_PART"
  else mkfs.ext4 -F -L boot "$BOOT_PART"
  fi
fi
case $FILESYSTEM in
  ext4) mkfs.ext4 -F -L arch "$ROOT_DEV" ;;
  btrfs) mkfs.btrfs -f -L arch "$ROOT_DEV" ;;
  xfs) mkfs.xfs -f -L arch "$ROOT_DEV" ;;
esac
ROOT_UUID=$(blkid -s UUID -o value "$ROOT_DEV")

info "Mounting"
if [[ "$FILESYSTEM" == btrfs ]]; then
  mount "$ROOT_DEV" "$MNT"
  subvols=(@ @home @log @pkg @snapshots)
  [[ "$SWAP" == file ]] && subvols+=(@swap)
  for sv in "${subvols[@]}"; do btrfs subvolume create "$MNT/$sv" >/dev/null; done
  umount "$MNT"
  opts=noatime,compress=zstd
  mount -o "$opts,subvol=@" "$ROOT_DEV" "$MNT"
  mount --mkdir -o "$opts,subvol=@home" "$ROOT_DEV" "$MNT/home"
  mount --mkdir -o "$opts,subvol=@log" "$ROOT_DEV" "$MNT/var/log"
  mount --mkdir -o "$opts,subvol=@pkg" "$ROOT_DEV" "$MNT/var/cache/pacman/pkg"
  mount --mkdir -o "$opts,subvol=@snapshots" "$ROOT_DEV" "$MNT/.snapshots"
  [[ "$SWAP" == file ]] && mount --mkdir -o "noatime,subvol=@swap" "$ROOT_DEV" "$MNT/swap"
else
  mount -o noatime "$ROOT_DEV" "$MNT"
fi
if [[ -n "$BOOT_PART" ]]; then
  if [[ "$BOOT_MODE" == UEFI ]]; then mount --mkdir -o fmask=0077,dmask=0077 "$BOOT_PART" "$MNT/boot"
  else mount --mkdir "$BOOT_PART" "$MNT/boot"
  fi
fi

if [[ "$SWAP" == file ]]; then
  step "Creating ${SWAP_SIZE} swap file"
  if [[ "$FILESYSTEM" == btrfs ]]; then
    SWAPFILE=/swap/swapfile
    btrfs filesystem mkswapfile --size "${SWAP_SIZE,,}" "$MNT$SWAPFILE"
  else
    SWAPFILE=/swapfile
    fallocate -l "$SWAP_SIZE" "$MNT$SWAPFILE"
    chmod 600 "$MNT$SWAPFILE"
    mkswap "$MNT$SWAPFILE" >/dev/null
  fi
fi

# ------------------------------------------------------------- pacstrap ---
info "Installing ${#PKGS[@]} packages (this takes a while)"
pacstrap -K "$MNT" "${PKGS[@]}"

info "Generating fstab"
genfstab -U "$MNT" >"$MNT/etc/fstab"
[[ "$SWAP" == file ]] && echo "$SWAPFILE none swap defaults 0 0" >>"$MNT/etc/fstab"
sed 's/^/  /' "$MNT/etc/fstab"

# -------------------------------------------------------- configuration ---
info "Configuring the new system"
chroot_script >"$MNT/root/autoinstaller-setup.sh"
arch-chroot "$MNT" bash /root/autoinstaller-setup.sh
rm -f "$MNT/root/autoinstaller-setup.sh"

step "Setting passwords"
printf '%s:%s\n' "$USERNAME" "$USER_PASSWORD" | arch-chroot "$MNT" chpasswd
if [[ "$ROOT_PASSWORD_MODE" == lock ]]; then
  arch-chroot "$MNT" passwd -l root >/dev/null
else
  printf 'root:%s\n' "$ROOT_PASSWORD" | arch-chroot "$MNT" chpasswd
fi
unset USER_PASSWORD ROOT_PASSWORD LUKS_PASSWORD

if [[ "$NETWORK" == iwd ]]; then
  ln -sf ../run/systemd/resolve/stub-resolv.conf "$MNT/etc/resolv.conf"
fi

# ---------------------------------------------------------------- finish ---
info "Installation finished $(date -Is)"
mkdir -p "$MNT/var/log/arch-autoinstaller"
cp "$CONFIG_FILE" "$MNT/var/log/arch-autoinstaller/config"
cp "$LOG_FILE" "$MNT/var/log/arch-autoinstaller/install.log"
echo "  Log saved to /var/log/arch-autoinstaller/install.log on the new system."

trap - ERR
sync
swapoff -a 2>/dev/null || true
umount -R "$MNT"
[[ "$ENCRYPT" == yes ]] && cryptsetup close cryptroot

if [[ "$REBOOT_WHEN_DONE" == yes ]]; then
  info "Rebooting in 10 seconds (Ctrl+C to cancel)"
  sleep 10
  reboot
else
  info "Done! Remove the installation media and run 'reboot'."
fi
