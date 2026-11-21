#!/usr/bin/env bash
# Offline tests: no root, no disks touched. Run: ./tests/run.sh
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"; [[ -n "${SERVER_PID:-}" ]] && kill "$SERVER_PID" 2>/dev/null' EXIT
pass=0 fail=0
ok() { echo "  ok   $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL $1"; [[ -n "${2:-}" ]] && sed 's/^/       /' <<<"$2"; fail=$((fail + 1)); }
check() { local name=$1; shift; local out; if out=$("$@" 2>&1); then ok "$name"; else bad "$name" "$out"; fi; }
check_fails() { local name=$1; shift; local out; if out=$("$@" 2>&1); then bad "$name (expected failure)" "$out"; else ok "$name"; fi; }

echo "syntax"
for f in install.sh lib/*.sh tests/run.sh; do check "bash -n $f" bash -n "$f"; done
check "python compile server.py" python3 -c "import ast,sys; ast.parse(open('dashboard/server.py').read())"
if command -v shellcheck >/dev/null; then
  check "shellcheck" shellcheck -x -S warning install.sh lib/*.sh
fi

echo "schema"
check "dashboard schema matches lib/options.conf" python3 - <<'EOF'
import re, sys
conf = [l.split("|") for l in open("lib/options.conf").read().splitlines() if l.strip() and not l.startswith("#")]
html = open("dashboard/index.html").read()
emb = re.findall(r'^\s*\[("[^\n]*")\],?$', html.split("EMBEDDED_SCHEMA = [")[1].split("].map(")[0], re.M)
import json
emb = [json.loads("[" + e + "]") for e in emb]
if conf != emb:
    for a, b in zip(conf, emb):
        if a != b: print("conf:", a, "\nhtml:", b)
    print(len(conf), len(emb)); sys.exit(1)
EOF
check "config file has every option" bash -c '
  for k in $(grep -v "^#" lib/options.conf | cut -d"|" -f1); do grep -q "^$k=" config || { echo "missing $k"; exit 1; }; done'

echo "config validation"
check "default config passes --check" bash install.sh --check
mkcfg() { cp config "$TMP/cfg"; for kv in "$@"; do
  k=${kv%%=*}; v=${kv#*=}; sed -i "s|^$k=.*|$k='$v'|" "$TMP/cfg"; done; echo "$TMP/cfg"; }
for combo in "FILESYSTEM=btrfs SWAP=file ENCRYPT=yes" "FILESYSTEM=xfs BOOTLOADER=systemd-boot" \
             "DESKTOP=kde GPU_DRIVER=nvidia MULTILIB=yes" "DESKTOP=hyprland DISPLAY_MANAGER=ly AUR_HELPER=paru" \
             "DESKTOP=none NETWORK=iwd FIREWALL=ufw SSH=yes"; do
  # shellcheck disable=SC2086
  cfg=$(mkcfg $combo)
  check "dry-run: $combo" bash install.sh --dry-run -c "$cfg"
done
check_fails "rejects bad filesystem" bash install.sh --check -c "$(mkcfg FILESYSTEM=ntfs)"
check_fails "rejects bad username" bash install.sh --check -c "$(mkcfg USERNAME=Bad.User)"
check_fails "rejects root username" bash install.sh --check -c "$(mkcfg USERNAME=root)"
check_fails "rejects bad hostname" bash install.sh --check -c "$(mkcfg HOSTNAME=-bad)"
check_fails "rejects bad timezone" bash install.sh --check -c "$(mkcfg TIMEZONE=Mars/Olympus)"
check_fails "rejects unknown option" bash install.sh --frobnicate

echo "resolved packages"
out=$(bash install.sh --check -c "$(mkcfg FILESYSTEM=btrfs ENCRYPT=yes DESKTOP=kde GPU_DRIVER=amd BLUETOOTH=yes)" 2>&1)
for p in btrfs-progs cryptsetup plasma-meta sddm vulkan-radeon bluez; do
  grep -q "\b$p\b" <<<"$out" && ok "kde/btrfs plan includes $p" || bad "kde/btrfs plan includes $p" "$out"
done
out=$(bash install.sh --dry-run -c "$(mkcfg ENCRYPT=yes)" 2>&1)
grep -q "declare -- ENCRYPT=\"yes\"" <<<"$out" && ok "chroot script receives ENCRYPT" || bad "chroot script receives ENCRYPT" "$out"
grep -q "^declare -a SERVICES=" <<<"$out" && ok "chroot script receives SERVICES array" || bad "chroot script receives SERVICES array"

echo "legacy config"
cat >"$TMP/old" <<'EOF'
TIMEZONE="UTC"
LOCALE="en_US.UTF-8 UTF-8"
DISPLAYMANAGER="sddm"
DESKTOPMANAGER="xfce4 xfce4-goodies"
ADDITIONAL_PACKAGES="nano alacritty"
EOF
# merge the old file over defaults: missing keys come from defaults
cat config "$TMP/old" | grep -v '^DESKTOP=' >"$TMP/old2"
check "old-format config still loads" bash install.sh --check -c "$TMP/old2"

echo "config save round-trip"
check "save_config keeps comments and quotes values" bash -c '
  source lib/common.sh; load_schema lib/options.conf; cp config "$1/rt"; load_config "$1/rt"
  ADDITIONAL_PACKAGES="it'"'"'s \$HOME \`x\`"; HOSTNAME=box; save_config "$1/rt"
  grep -q "^# --- Disk" "$1/rt" || exit 1
  unset ADDITIONAL_PACKAGES HOSTNAME; load_config "$1/rt"
  [[ "$ADDITIONAL_PACKAGES" == "it'"'"'s \$HOME \`x\`" && "$HOSTNAME" == box ]] || { echo "got: $ADDITIONAL_PACKAGES / $HOSTNAME"; exit 1; }
' _ "$TMP"
check "partition_path" bash -c 'source lib/common.sh
  [[ $(partition_path /dev/sda 1) == /dev/sda1 && $(partition_path /dev/nvme0n1 2) == /dev/nvme0n1p2 && $(partition_path /dev/mmcblk0 1) == /dev/mmcblk0p1 ]]'

echo "web dashboard server"
cp config "$TMP/webcfg"
PORT=$((20000 + RANDOM % 20000))
python3 dashboard/server.py --config "$TMP/webcfg" --port "$PORT" --bind 127.0.0.1 >"$TMP/server.log" 2>&1 &
SERVER_PID=$!
for _ in $(seq 50); do grep -q token= "$TMP/server.log" && break; sleep 0.1; done
TOKEN=$(grep -o 'token=[^ ]*' "$TMP/server.log" | head -1 | cut -d= -f2)
URL="http://127.0.0.1:$PORT"
code=$(curl -s -o /dev/null -w '%{http_code}' "$URL/api/config")
[[ "$code" == 403 ]] && ok "rejects requests without token" || bad "rejects requests without token (got $code)"
check "serves index with token" bash -c "curl -fsS '$URL/?token=$TOKEN' | grep -q 'Arch Autoinstaller'"
check "GET /api/info" bash -c "curl -fsS -H 'X-Token: $TOKEN' '$URL/api/info' | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d[\"boot_mode\"] in (\"UEFI\",\"BIOS\")'"
cfg_json=$(curl -fsS -H "X-Token: $TOKEN" "$URL/api/config")
check "GET /api/config returns all options" python3 -c "import json,sys; d=json.loads(sys.argv[1]); assert len(d)==$(grep -cv '^#' lib/options.conf), len(d)" "$cfg_json"
body=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); d['HOSTNAME']='webbox'; d['DESKTOP']='gnome'; print(json.dumps({'config':d}))" "$cfg_json")
check "POST /api/plan" bash -c "curl -fsS -H 'X-Token: $TOKEN' -H 'Content-Type: application/json' -d '$body' '$URL/api/plan' | grep -q '\"ok\": true'"
check "POST /api/save writes config" bash -c "curl -fsS -H 'X-Token: $TOKEN' -d '$body' '$URL/api/save' >/dev/null && grep -q \"^HOSTNAME='webbox'\" '$TMP/webcfg' && grep -q '^# --- Disk' '$TMP/webcfg'"
evil=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); d['HOSTNAME']='x; rm -rf /'; print(json.dumps({'config':d}))" "$cfg_json")
code=$(curl -s -o /dev/null -w '%{http_code}' -H "X-Token: $TOKEN" -d "$evil" "$URL/api/save")
[[ "$code" == 400 ]] && ok "rejects invalid values" || bad "rejects invalid values (got $code)"
check "saved config is valid for install.sh" bash install.sh --check -c "$TMP/webcfg"
curl -fsS -H "X-Token: $TOKEN" -d "$body" "$URL/api/install" >/dev/null
wait "$SERVER_PID"; rc=$?; SERVER_PID=
[[ $rc == 10 ]] && ok "Save & install exits with code 10" || bad "Save & install exits with code 10 (got $rc)"

echo
echo "$pass passed, $fail failed"
((fail == 0))
