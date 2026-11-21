# Runs INSIDE the new system via arch-chroot.
# install.sh prepends the variable declarations this script needs, so do not
# run it on its own. Passwords are never passed in here.
# shellcheck shell=bash disable=SC2154
set -Eeuo pipefail
trap 'echo "chroot-setup: command failed on line $LINENO: $BASH_COMMAND" >&2' ERR

say() { printf '\e[34m  ->\e[0m %s\n' "$*"; }

say "Time zone and clock ($TIMEZONE)"
ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
hwclock --systohc || true
systemctl enable systemd-timesyncd.service

say "Locale ($LOCALE) and keymap ($KEYMAP)"
locale_re=${LOCALE//./\\.}
if grep -Eq "^#?\s*${locale_re} " /etc/locale.gen; then
  sed -Ei "s/^#\s*(${locale_re} )/\1/" /etc/locale.gen
else
  echo "$LOCALE UTF-8" >>/etc/locale.gen
fi
locale-gen
echo "LANG=$LOCALE" >/etc/locale.conf
echo "KEYMAP=$KEYMAP" >/etc/vconsole.conf

say "Hostname ($HOSTNAME)"
echo "$HOSTNAME" >/etc/hostname
cat >/etc/hosts <<EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   $HOSTNAME.localdomain $HOSTNAME
EOF

say "pacman configuration"
sed -Ei "s/^#?\s*ParallelDownloads.*/ParallelDownloads = $PARALLEL_DOWNLOADS/" /etc/pacman.conf
sed -i 's/^#Color/Color/' /etc/pacman.conf
if [[ "$MULTILIB" == yes ]]; then
  sed -i '/^#\[multilib\]/{s/^#//;n;s/^#//}' /etc/pacman.conf
fi

say "Swap ($SWAP)"
if [[ "$SWAP" == zram ]]; then
  cat >/etc/systemd/zram-generator.conf <<'EOF'
[zram0]
zram-size = min(ram / 2, 8192)
compression-algorithm = zstd
EOF
fi

# ----------------------------------------------------------------- initramfs
say "Initramfs"
if [[ "$ENCRYPT" == yes ]]; then
  if grep -Eq '^HOOKS=.*\bsystemd\b' /etc/mkinitcpio.conf; then
    ENCRYPT_HOOK=sd-encrypt
    CRYPT_PARAMS="rd.luks.name=${LUKS_UUID}=cryptroot root=/dev/mapper/cryptroot"
  else
    ENCRYPT_HOOK=encrypt
    CRYPT_PARAMS="cryptdevice=UUID=${LUKS_UUID}:cryptroot root=/dev/mapper/cryptroot"
  fi
  # keyboard must come before the encrypt hook so the passphrase can be typed
  if ! grep -Eq '^HOOKS=.*\bkeyboard\b' /etc/mkinitcpio.conf; then
    sed -Ei 's/^(HOOKS=\(.*)\bblock\b/\1keyboard block/' /etc/mkinitcpio.conf
  fi
  sed -Ei "s/^(HOOKS=\(.*)\bfilesystems\b/\1${ENCRYPT_HOOK} filesystems/" /etc/mkinitcpio.conf
  ROOT_PARAMS="$CRYPT_PARAMS"
else
  ROOT_PARAMS="root=UUID=${ROOT_UUID}"
fi
[[ "$FILESYSTEM" == btrfs ]] && ROOT_PARAMS+=" rootflags=subvol=@"
KERNEL_PARAMS="$ROOT_PARAMS rw quiet loglevel=3"
[[ "$RESOLVED_GPU" == nvidia ]] && KERNEL_PARAMS+=" nvidia-drm.modeset=1"
mkinitcpio -P

# ---------------------------------------------------------------- bootloader
if [[ "$BOOTLOADER" == systemd-boot && "$BOOT_MODE" == UEFI ]]; then
  say "Bootloader: systemd-boot"
  bootctl install
  cat >/boot/loader/loader.conf <<EOF
default arch.conf
timeout 3
console-mode max
editor no
EOF
  ucode_line=''
  # Older mkinitcpio without the microcode hook needs the image listed separately.
  if ! grep -Eq '^HOOKS=.*\bmicrocode\b' /etc/mkinitcpio.conf && [[ -f "/boot/${RESOLVED_UCODE}-ucode.img" ]]; then
    ucode_line="initrd  /${RESOLVED_UCODE}-ucode.img"
  fi
  for variant in "" "-fallback"; do
    name=arch$variant
    [[ -f "/boot/initramfs-${KERNEL}${variant}.img" ]] || continue
    {
      echo "title   Arch Linux (${KERNEL}${variant})"
      echo "linux   /vmlinuz-${KERNEL}"
      [[ -n "$ucode_line" ]] && echo "$ucode_line"
      echo "initrd  /initramfs-${KERNEL}${variant}.img"
      echo "options $KERNEL_PARAMS"
    } >"/boot/loader/entries/${name}.conf"
  done
  systemctl enable systemd-boot-update.service
else
  say "Bootloader: GRUB ($BOOT_MODE)"
  sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"loglevel=3 quiet\"|" /etc/default/grub
  if [[ "$ENCRYPT" == yes ]]; then
    sed -i "s|^GRUB_CMDLINE_LINUX=.*|GRUB_CMDLINE_LINUX=\"$CRYPT_PARAMS\"|" /etc/default/grub
  fi
  if [[ "$RESOLVED_GPU" == nvidia ]]; then
    sed -i 's|^GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"|GRUB_CMDLINE_LINUX_DEFAULT="\1 nvidia-drm.modeset=1"|' /etc/default/grub
  fi
  if [[ "$BOOT_MODE" == UEFI ]]; then
    grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB
    # Also install to the fallback path; some firmware (and many VMs) forget NVRAM entries.
    grub-install --target=x86_64-efi --efi-directory=/boot --removable
  else
    grub-install --target=i386-pc "$DISK"
  fi
  grub-mkconfig -o /boot/grub/grub.cfg
fi

# --------------------------------------------------------------------- users
say "User account ($USERNAME)"
useradd_args=(-m -s "/usr/bin/$USER_SHELL")
[[ "$USER_SUDO" == yes ]] && useradd_args+=(-G wheel)
useradd "${useradd_args[@]}" "$USERNAME"
install -m 0440 /dev/stdin /etc/sudoers.d/10-wheel <<'EOF'
%wheel ALL=(ALL:ALL) ALL
EOF
visudo -cq
sudo -u "$USERNAME" xdg-user-dirs-update 2>/dev/null || true

# ----------------------------------------------------------------- network
case $NETWORK in
  iwd)
    mkdir -p /etc/iwd /etc/systemd/network
    printf '[General]\nEnableNetworkConfiguration=true\n' >/etc/iwd/main.conf
    printf '[Match]\nName=en* eth*\n\n[Network]\nDHCP=yes\n' >/etc/systemd/network/20-wired.network
    ;;
esac

# ---------------------------------------------------------------- firewall
if [[ "$FIREWALL" == ufw ]]; then
  sed -i 's/^ENABLED=.*/ENABLED=yes/' /etc/ufw/ufw.conf
  # ufw rules need a running kernel, so apply them once on first boot.
  cat >/etc/systemd/system/autoinstaller-ufw-firstboot.service <<EOF
[Unit]
Description=Apply initial ufw rules (arch-autoinstaller)
After=ufw.service
ConditionPathExists=!/var/lib/autoinstaller-ufw-done

[Service]
Type=oneshot
ExecStart=/usr/bin/ufw default deny incoming
ExecStart=/usr/bin/ufw default allow outgoing
$([[ "$SSH" == yes ]] && echo "ExecStart=/usr/bin/ufw allow ssh")
ExecStart=/usr/bin/ufw --force enable
ExecStart=/usr/bin/touch /var/lib/autoinstaller-ufw-done

[Install]
WantedBy=multi-user.target
EOF
  SERVICES+=(autoinstaller-ufw-firstboot.service)
fi

# ---------------------------------------------------------------- services
say "Enabling services"
for svc in "${SERVICES[@]}"; do
  systemctl enable "$svc" || echo "  !! could not enable $svc" >&2
done
case $RESOLVED_DM in
  none) ;;
  ly)
    if ! systemctl enable ly.service 2>/dev/null; then
      systemctl disable getty@tty2.service 2>/dev/null || true
      systemctl enable ly@tty2.service
    fi ;;
  *) systemctl enable "$RESOLVED_DM.service" ;;
esac

# --------------------------------------------------------------- AUR helper
if [[ "$AUR_HELPER" != none ]]; then
  say "AUR helper ($AUR_HELPER)"
  echo "$USERNAME ALL=(ALL) NOPASSWD: ALL" >/etc/sudoers.d/99-autoinstaller-tmp
  chmod 0440 /etc/sudoers.d/99-autoinstaller-tmp
  if ! sudo -u "$USERNAME" bash -c "
      set -e
      d=\$(mktemp -d)
      git clone --depth 1 https://aur.archlinux.org/${AUR_HELPER}-bin.git \"\$d\"
      cd \"\$d\" && makepkg -si --noconfirm
      rm -rf \"\$d\""; then
    echo "  !! failed to install $AUR_HELPER, you can install it manually later" >&2
  fi
  rm -f /etc/sudoers.d/99-autoinstaller-tmp
fi

say "chroot setup complete"
