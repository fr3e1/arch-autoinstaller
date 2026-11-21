#!/usr/bin/env bash
# Shared helpers: output, config loading/saving and validation.
# shellcheck disable=SC2034

if [[ -t 1 ]] || [[ -n "${FORCE_COLOR:-}" ]]; then
  C_RED=$'\e[31m' C_GREEN=$'\e[32m' C_YELLOW=$'\e[33m' C_BLUE=$'\e[34m'
  C_BOLD=$'\e[1m' C_DIM=$'\e[2m' C_RESET=$'\e[0m'
else
  C_RED='' C_GREEN='' C_YELLOW='' C_BLUE='' C_BOLD='' C_DIM='' C_RESET=''
fi

info() { printf '%s==>%s %s%s%s\n' "$C_GREEN" "$C_RESET" "$C_BOLD" "$*" "$C_RESET"; }
step() { printf '%s  ->%s %s\n' "$C_BLUE" "$C_RESET" "$*"; }
warn() { printf '%s==> WARNING:%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
err()  { printf '%s==> ERROR:%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }
die()  { err "$*"; exit 1; }

# Single-quote a value so it is safe to write into a bash-sourced file.
shell_quote() {
  local s=${1//\'/\'\\\'\'}
  printf "'%s'" "$s"
}

# ---------------------------------------------------------------- schema ---
# Arrays filled by load_schema:
#   OPT_KEYS (ordered), OPT_KIND[k], OPT_RULE[k], OPT_SECTION[k], OPT_LABEL[k]
declare -a OPT_KEYS=()
declare -A OPT_KIND=() OPT_RULE=() OPT_SECTION=() OPT_LABEL=()

load_schema() {
  local file=$1 key kind rule section label
  OPT_KEYS=()
  while IFS='|' read -r key kind rule section label; do
    [[ -z "$key" || "$key" == \#* ]] && continue
    OPT_KEYS+=("$key")
    OPT_KIND[$key]=$kind
    OPT_RULE[$key]=$rule
    OPT_SECTION[$key]=$section
    OPT_LABEL[$key]=$label
  done <"$file"
}

# ---------------------------------------------------------------- config ---
load_config() {
  local file=$1
  [[ -f "$file" ]] || die "Config file not found: $file"
  # Backwards compatibility with the old config format.
  local DESKTOPMANAGER='' DISPLAYMANAGER=''
  # shellcheck source=/dev/null
  source "$file"
  if [[ -n "$DESKTOPMANAGER" && -z "${DESKTOP:-}" ]]; then
    warn "Old config format detected (DESKTOPMANAGER); treating it as extra packages."
    DESKTOP=none
    ADDITIONAL_PACKAGES="${ADDITIONAL_PACKAGES:-} $DESKTOPMANAGER"
  fi
  if [[ -n "$DISPLAYMANAGER" && -z "${DISPLAY_MANAGER:-}" ]]; then
    DISPLAY_MANAGER=$DISPLAYMANAGER
  fi
  # Old locale format "en_US.UTF-8 UTF-8" -> "en_US.UTF-8"
  LOCALE=${LOCALE% UTF-8}
  # A bare disk name ("sda") becomes a path.
  if [[ -n "${DISK:-}" && "$DISK" != /* ]]; then DISK="/dev/$DISK"; fi
}

# Rewrite KEY=... lines in place (keeping comments), append missing keys.
save_config() {
  local file=$1 key tmp
  tmp=$(mktemp)
  if [[ -f "$file" ]]; then cp "$file" "$tmp"; fi
  for key in "${OPT_KEYS[@]}"; do
    local line
    line="$key=$(shell_quote "${!key-}")"
    if grep -q "^${key}=" "$tmp"; then
      # awk avoids sed escaping problems with arbitrary values
      K="$key" L="$line" awk 'index($0, ENVIRON["K"] "=")==1 {print ENVIRON["L"]; next} {print}' "$tmp" >"$tmp.new"
      mv "$tmp.new" "$tmp"
    else
      printf '%s\n' "$line" >>"$tmp"
    fi
  done
  mv "$tmp" "$file"
}

# Returns 0 if $2 is a valid value for option $1, prints a reason otherwise.
validate_option() {
  local key=$1 value=$2 kind=${OPT_KIND[$1]} rule=${OPT_RULE[$1]}
  case $kind in
    enum)
      [[ ",$rule," == *",$value,"* ]] && return 0
      echo "must be one of: ${rule//,/, } (got '$value')"
      return 1 ;;
    text)
      [[ "$value" =~ $rule ]] && return 0
      echo "invalid value '$value'"
      return 1 ;;
    disk)
      [[ -z "$value" || "$value" =~ ^/dev/[A-Za-z0-9/_-]+$ ]] && return 0
      echo "must be a device path like /dev/sda (got '$value')"
      return 1 ;;
  esac
}

# Validate every option plus cross-option rules. Prints all problems.
validate_config() {
  local key msg problems=0
  for key in "${OPT_KEYS[@]}"; do
    if ! msg=$(validate_option "$key" "${!key-}"); then
      err "$key: $msg"
      problems=$((problems + 1))
    fi
  done
  if [[ -d /usr/share/zoneinfo && -n "$TIMEZONE" && ! -f "/usr/share/zoneinfo/$TIMEZONE" ]]; then
    err "TIMEZONE: '$TIMEZONE' does not exist in /usr/share/zoneinfo"
    problems=$((problems + 1))
  fi
  if [[ -f /usr/share/i18n/SUPPORTED ]] && ! grep -q "^${LOCALE//./\\.} " /usr/share/i18n/SUPPORTED; then
    err "LOCALE: '$LOCALE' is not listed in /usr/share/i18n/SUPPORTED"
    problems=$((problems + 1))
  fi
  if [[ "$USERNAME" == root ]]; then
    err "USERNAME: 'root' is reserved"
    problems=$((problems + 1))
  fi
  return $((problems > 0))
}

# Partition path for a disk: /dev/sda + 1 -> /dev/sda1, /dev/nvme0n1 + 1 -> /dev/nvme0n1p1
partition_path() {
  local disk=$1 n=$2
  if [[ "$disk" =~ [0-9]$ ]]; then echo "${disk}p${n}"; else echo "${disk}${n}"; fi
}

boot_mode() {
  [[ -d /sys/firmware/efi/efivars ]] && echo UEFI || echo BIOS
}

detect_cpu_vendor() {
  local v
  v=$(awk -F': ' '/^vendor_id/ {print $2; exit}' /proc/cpuinfo 2>/dev/null)
  case $v in
    GenuineIntel) echo intel ;;
    AuthenticAMD) echo amd ;;
    *) echo none ;;
  esac
}

detect_gpu() {
  local virt
  virt=$(systemd-detect-virt 2>/dev/null || true)
  if [[ -n "$virt" && "$virt" != none ]]; then echo vm; return; fi
  local gpus
  gpus=$(lspci 2>/dev/null | grep -Ei 'vga|3d|display' || true)
  if grep -qi nvidia <<<"$gpus"; then echo nvidia
  elif grep -Eqi 'amd|ati|radeon' <<<"$gpus"; then echo amd
  elif grep -qi intel <<<"$gpus"; then echo intel
  else echo none
  fi
}

list_disks() {
  lsblk -dpno NAME,SIZE,MODEL,TYPE 2>/dev/null | awk '$NF=="disk" {$NF=""; print}' |
    grep -Ev '^/dev/(loop|sr|zram|ram)' || true
}
