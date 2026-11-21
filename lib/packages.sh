#!/usr/bin/env bash
# Turns the config into concrete package and service lists.
# Fills: PKGS (array), SERVICES (array), RESOLVED_DM, RESOLVED_GPU, RESOLVED_UCODE
# shellcheck disable=SC2034

resolve_packages() {
  local mode=$1 # UEFI | BIOS
  PKGS=(base base-devel "$KERNEL" "${KERNEL}-headers" linux-firmware sudo git man-db man-pages
        bash-completion "$USER_SHELL")
  SERVICES=(fstrim.timer)

  # Filesystem tools
  case $FILESYSTEM in
    ext4) PKGS+=(e2fsprogs) ;;
    btrfs) PKGS+=(btrfs-progs) ;;
    xfs) PKGS+=(xfsprogs) ;;
  esac
  PKGS+=(dosfstools)
  [[ "$ENCRYPT" == yes ]] && PKGS+=(cryptsetup)
  [[ "$SWAP" == zram ]] && PKGS+=(zram-generator)

  # Bootloader
  if [[ "$BOOTLOADER" == grub || "$mode" == BIOS ]]; then
    PKGS+=(grub)
    [[ "$mode" == UEFI ]] && PKGS+=(efibootmgr)
  fi

  # Microcode
  RESOLVED_UCODE=$MICROCODE
  [[ "$RESOLVED_UCODE" == auto ]] && RESOLVED_UCODE=$(detect_cpu_vendor)
  case $RESOLVED_UCODE in
    intel) PKGS+=(intel-ucode) ;;
    amd) PKGS+=(amd-ucode) ;;
  esac

  # Network
  case $NETWORK in
    networkmanager) PKGS+=(networkmanager); SERVICES+=(NetworkManager.service) ;;
    iwd) PKGS+=(iwd); SERVICES+=(iwd.service systemd-networkd.service systemd-resolved.service) ;;
  esac

  # Desktop environment + default display manager
  local dm_default=none xorg=yes
  case $DESKTOP in
    none) xorg=no ;;
    xfce) PKGS+=(xfce4 xfce4-goodies); dm_default=lightdm ;;
    gnome) PKGS+=(gnome gnome-tweaks); dm_default=gdm; xorg=no ;;
    kde) PKGS+=(plasma-meta konsole dolphin kate ark spectacle); dm_default=sddm; xorg=no ;;
    cinnamon) PKGS+=(cinnamon gnome-terminal); dm_default=lightdm ;;
    mate) PKGS+=(mate mate-extra); dm_default=lightdm ;;
    lxqt) PKGS+=(lxqt breeze-icons); dm_default=sddm ;;
    budgie) PKGS+=(budgie gnome-terminal); dm_default=lightdm ;;
    i3) PKGS+=(i3-wm i3status i3lock dmenu xterm); dm_default=lightdm ;;
    sway) PKGS+=(sway swaybg swaylock swayidle foot wmenu xorg-xwayland); dm_default=sddm; xorg=no ;;
    hyprland) PKGS+=(hyprland kitty wofi waybar xdg-desktop-portal-hyprland hyprpolkitagent); dm_default=sddm; xorg=no ;;
  esac
  if [[ "$DESKTOP" != none ]]; then
    PKGS+=(xdg-user-dirs xdg-utils noto-fonts noto-fonts-emoji ttf-dejavu)
    [[ "$xorg" == yes ]] && PKGS+=(xorg-server xorg-xinit)
  fi

  RESOLVED_DM=$DISPLAY_MANAGER
  [[ "$RESOLVED_DM" == auto ]] && RESOLVED_DM=$dm_default
  case $RESOLVED_DM in
    sddm) PKGS+=(sddm) ;;
    gdm) PKGS+=(gdm) ;;
    lightdm) PKGS+=(lightdm lightdm-gtk-greeter) ;;
    ly) PKGS+=(ly) ;;
  esac
  # Service is enabled by the chroot script (ly's unit name varies by version).

  # Graphics
  RESOLVED_GPU=$GPU_DRIVER
  [[ "$RESOLVED_GPU" == auto ]] && RESOLVED_GPU=$(detect_gpu)
  case $RESOLVED_GPU in
    intel) PKGS+=(mesa vulkan-intel intel-media-driver) ;;
    amd) PKGS+=(mesa vulkan-radeon libva-mesa-driver) ;;
    nvidia) PKGS+=(nvidia-open-dkms nvidia-utils nvidia-settings) ;;
    vm)
      PKGS+=(mesa)
      case $(systemd-detect-virt 2>/dev/null || true) in
        oracle) PKGS+=(virtualbox-guest-utils); SERVICES+=(vboxservice.service) ;;
        vmware) PKGS+=(open-vm-tools); SERVICES+=(vmtoolsd.service vmware-vmblock-fuse.service) ;;
        kvm|qemu) PKGS+=(qemu-guest-agent spice-vdagent); SERVICES+=(qemu-guest-agent.service) ;;
        microsoft) PKGS+=(hyperv); SERVICES+=(hv_kvp_daemon.service hv_vss_daemon.service) ;;
      esac ;;
  esac
  if [[ "$MULTILIB" == yes ]]; then
    case $RESOLVED_GPU in
      intel) PKGS+=(lib32-mesa lib32-vulkan-intel) ;;
      amd) PKGS+=(lib32-mesa lib32-vulkan-radeon) ;;
      nvidia) PKGS+=(lib32-nvidia-utils) ;;
    esac
  fi

  # Audio
  case $AUDIO in
    pipewire) PKGS+=(pipewire pipewire-alsa pipewire-pulse pipewire-jack wireplumber) ;;
    pulseaudio) PKGS+=(pulseaudio pulseaudio-alsa) ;;
  esac
  [[ "$AUDIO" != none && "$DESKTOP" != none ]] && PKGS+=(pavucontrol)

  [[ "$BLUETOOTH" == yes ]] && { PKGS+=(bluez bluez-utils); SERVICES+=(bluetooth.service); }
  [[ "$PRINTING" == yes ]] && { PKGS+=(cups cups-pdf); SERVICES+=(cups.service); }
  [[ "$SSH" == yes ]] && { PKGS+=(openssh); SERVICES+=(sshd.service); }
  case $FIREWALL in
    ufw) PKGS+=(ufw); SERVICES+=(ufw.service) ;;
    firewalld) PKGS+=(firewalld); SERVICES+=(firewalld.service) ;;
  esac

  # User extras
  local extra
  read -ra extra <<<"${ADDITIONAL_PACKAGES//,/ }"
  PKGS+=("${extra[@]}")
  read -ra extra <<<"${ADDITIONAL_SERVICES//,/ }"
  SERVICES+=("${extra[@]}")

  # bash is always present, drop duplicates while keeping order
  local -A seen=()
  local p out=()
  for p in "${PKGS[@]}"; do
    [[ -z "$p" || -n "${seen[$p]:-}" ]] && continue
    seen[$p]=1
    out+=("$p")
  done
  PKGS=("${out[@]}")
}
