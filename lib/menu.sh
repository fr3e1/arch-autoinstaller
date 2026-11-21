#!/usr/bin/env bash
# Terminal dashboard: edit every option, save the config, start the install.
# Pure bash, works on the bare live ISO.

apply_preset() {
  case $1 in
    minimal)
      DESKTOP=none DISPLAY_MANAGER=none AUDIO=none BLUETOOTH=no PRINTING=no
      SWAP=zram AUR_HELPER=none ADDITIONAL_PACKAGES='nano vim' ;;
    desktop)
      DESKTOP=kde DISPLAY_MANAGER=auto AUDIO=pipewire BLUETOOTH=yes PRINTING=yes
      GPU_DRIVER=auto SWAP=zram AUR_HELPER=yay ADDITIONAL_PACKAGES='firefox nano vlc' ;;
    gaming)
      DESKTOP=kde DISPLAY_MANAGER=auto AUDIO=pipewire BLUETOOTH=yes MULTILIB=yes
      KERNEL=linux-zen GPU_DRIVER=auto SWAP=zram AUR_HELPER=yay
      ADDITIONAL_PACKAGES='firefox steam gamemode lib32-gamemode mangohud discord' ;;
    server)
      DESKTOP=none DISPLAY_MANAGER=none AUDIO=none BLUETOOTH=no PRINTING=no
      KERNEL=linux-lts SSH=yes FIREWALL=ufw SWAP=file
      ADDITIONAL_PACKAGES='vim htop tmux rsync' ;;
    *) return 1 ;;
  esac
}

_menu_header() {
  clear 2>/dev/null || true
  printf '%sarch-autoinstaller%s  terminal dashboard   %s(%s mode, config: %s)%s\n\n' \
    "$C_BOLD" "$C_RESET" "$C_DIM" "$(boot_mode)" "$1" "$C_RESET"
}

_menu_pick_disk() {
  local disks=() i n
  mapfile -t disks < <(list_disks)
  echo
  if ((${#disks[@]} == 0)); then warn "No disks found."; read -rp "Press Enter..." _; return; fi
  echo "  0) ask during install"
  for i in "${!disks[@]}"; do printf '  %d) %s\n' $((i + 1)) "${disks[$i]}"; done
  read -rp "Disk: " n
  if [[ "$n" == 0 ]]; then DISK=''
  elif [[ "$n" =~ ^[0-9]+$ ]] && ((n >= 1 && n <= ${#disks[@]})); then DISK=${disks[$((n - 1))]%% *}
  fi
}

_menu_edit() {
  local key=$1 kind=${OPT_KIND[$1]} rule=${OPT_RULE[$1]} value msg
  if [[ "$kind" == disk ]]; then _menu_pick_disk; return; fi
  if [[ "$kind" == enum ]]; then
    local choices=() i n
    IFS=',' read -ra choices <<<"$rule"
    echo
    for i in "${!choices[@]}"; do
      printf '  %d) %s%s\n' $((i + 1)) "${choices[$i]}" "$([[ "${choices[$i]}" == "${!key}" ]] && echo '  <- current')"
    done
    read -rp "${OPT_LABEL[$key]}: " n
    if [[ "$n" =~ ^[0-9]+$ ]] && ((n >= 1 && n <= ${#choices[@]})); then
      printf -v "$key" '%s' "${choices[$((n - 1))]}"
    fi
    return
  fi
  while true; do
    read -erp "${OPT_LABEL[$key]}: " -i "${!key}" value
    if msg=$(validate_option "$key" "$value"); then printf -v "$key" '%s' "$value"; return; fi
    err "$msg"
  done
}

# run_menu CONFIG_FILE -> returns 0 to start the install, 1 to quit
run_menu() {
  local file=$1 key i section last_section choice dirty=no
  while true; do
    _menu_header "$file"
    last_section=''
    for i in "${!OPT_KEYS[@]}"; do
      key=${OPT_KEYS[$i]}
      section=${OPT_SECTION[$key]}
      if [[ "$section" != "$last_section" ]]; then
        printf '\n %s%s%s\n' "$C_BLUE" "$section" "$C_RESET"
        last_section=$section
      fi
      local shown=${!key}
      [[ -z "$shown" ]] && shown="${C_DIM}(ask during install)${C_RESET}"
      printf '  %3d  %-26s %s\n' $((i + 1)) "${OPT_LABEL[$key]}" "$shown"
    done
    echo
    printf ' %s[number]%s edit   %sp%s preset   %ss%s save   %si%s save & install   %sq%s quit%s\n' \
      "$C_BOLD" "$C_RESET" "$C_BOLD" "$C_RESET" "$C_BOLD" "$C_RESET" "$C_BOLD" "$C_RESET" "$C_BOLD" "$C_RESET" \
      "$([[ $dirty == yes ]] && echo "   ${C_YELLOW}(unsaved changes)${C_RESET}")"
    read -rp " > " choice
    case $choice in
      [0-9]*)
        if [[ "$choice" =~ ^[0-9]+$ ]] && ((choice >= 1 && choice <= ${#OPT_KEYS[@]})); then
          _menu_edit "${OPT_KEYS[$((choice - 1))]}"
          dirty=yes
        fi ;;
      p|P)
        echo; echo "  1) minimal  2) desktop  3) gaming  4) server"
        read -rp "Preset: " choice
        case $choice in
          1) apply_preset minimal ;; 2) apply_preset desktop ;;
          3) apply_preset gaming ;; 4) apply_preset server ;;
        esac
        dirty=yes ;;
      s|S)
        if validate_config; then save_config "$file"; dirty=no; info "Saved to $file"
        else warn "Not saved: fix the errors above."
        fi
        read -rp "Press Enter..." _ ;;
      i|I)
        if validate_config; then save_config "$file"; return 0; fi
        read -rp "Press Enter..." _ ;;
      q|Q)
        if [[ $dirty == yes ]]; then
          read -rp "Discard unsaved changes? [y/N] " choice
          [[ "$choice" == [yY]* ]] || continue
        fi
        return 1 ;;
    esac
  done
}
