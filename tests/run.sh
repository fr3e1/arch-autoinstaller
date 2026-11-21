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
for f in install.sh bootstrap.sh lib/*.sh tests/run.sh; do check "bash -n $f" bash -n "$f"; done
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
# Stand-in installer: --check goes to the real one; an install run shows what
# it received and asks one question through the web terminal.
cat >"$TMP/fake-install.sh" <<FAKE
if [[ " \$* " == *" --check "* ]]; then exec bash "$ROOT/install.sh" "\$@"; fi
echo "ARGS:\$*"
[[ -n "\${USER_PASSWORD:-}" ]] && echo "PW:\$USER_PASSWORD"
[[ -t 0 ]] && echo "TTY:yes"
read -r -p "answer: " a
echo "GOT:\$a"
exit 3
FAKE
PORT=$((20000 + RANDOM % 20000))
python3 dashboard/server.py --config "$TMP/webcfg" --port "$PORT" --bind 127.0.0.1 --installer "$TMP/fake-install.sh" >"$TMP/server.log" 2>&1 &
SERVER_PID=$!
for _ in $(seq 50); do grep -q 'Access code' "$TMP/server.log" && break; sleep 0.1; done
TOKEN=$(sed -n 's/.*Access code: //p' "$TMP/server.log" | head -1)
URL="http://127.0.0.1:$PORT"
[[ "$TOKEN" =~ ^[a-z2-9]{6}$ ]] && ok "access code is 6 easy characters ($TOKEN)" || bad "access code is 6 easy characters (got '$TOKEN')"
grep -q "http://127.0.0.1:$PORT/$TOKEN" "$TMP/server.log" && ok "prints short link" || bad "prints short link" "$(cat "$TMP/server.log")"
code=$(curl -s -o /dev/null -w '%{http_code}' "$URL/api/config")
[[ "$code" == 403 ]] && ok "rejects requests without token" || bad "rejects requests without token (got $code)"
check "serves index at /<code>" bash -c "curl -fsS '$URL/$TOKEN' | grep -q 'EMBEDDED_SCHEMA'"
check "code is case-insensitive" bash -c "curl -fsS '$URL/${TOKEN^^}' | grep -q 'EMBEDDED_SCHEMA'"
check "serves index with ?token=" bash -c "curl -fsS '$URL/?token=$TOKEN' | grep -q 'EMBEDDED_SCHEMA'"
check "bare / shows code entry page" bash -c "curl -fsS '$URL/' | grep -q 'Enter the access code'"
code=$(curl -s -o /dev/null -w '%{http_code}' "$URL/apple-touch-icon.png")
[[ "$code" == 404 ]] && ok "stray browser requests are 404, not failed logins" || bad "stray requests (got $code)"
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
code=$(curl -s -o "$TMP/r" -w '%{http_code}' -H "X-Token: $TOKEN" -d "$body" "$URL/api/install")
[[ "$code" == 400 ]] && grep -q "disk" "$TMP/r" && grep -q "username" "$TMP/r" \
  && ok "install refuses without disk + username" || bad "install refuses without disk + username ($code)" "$(cat "$TMP/r")"
disk=$(curl -fsS -H "X-Token: $TOKEN" "$URL/api/info" | python3 -c 'import json,sys; d=[x["path"] for x in json.load(sys.stdin)["disks"] if not x["live_iso"] and x["size"]>=8<<30]; print(d[0] if d else "")')
if [[ -z "$disk" ]]; then
  echo "  skip install hand-off tests (no disk >= 8 GiB on this machine)"
  kill "$SERVER_PID"; wait "$SERVER_PID" 2>/dev/null; SERVER_PID=
else
  ready=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); d['config'].update(DISK=sys.argv[2], USERNAME='tester'); print(json.dumps(d))" "$body" "$disk")
  wrong=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); d['confirm_disk']='nope'; print(json.dumps(d))" "$ready")
  code=$(curl -s -o /dev/null -w '%{http_code}' -H "X-Token: $TOKEN" -d "$wrong" "$URL/api/install")
  [[ "$code" == 400 ]] && ok "install needs the typed disk name" || bad "install needs the typed disk name (got $code)"
  confirmed=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); d['confirm_disk']=sys.argv[2].removeprefix('/dev/'); print(json.dumps(d))" "$ready" "$disk")
  badpw=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); d['passwords']={'user':'a\nb'}; print(json.dumps(d))" "$confirmed")
  code=$(curl -s -o /dev/null -w '%{http_code}' -H "X-Token: $TOKEN" -d "$badpw" "$URL/api/install")
  [[ "$code" == 400 ]] && ok "rejects passwords with line breaks" || bad "rejects passwords with line breaks (got $code)"
  withpw=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); d['passwords']={'user':'s3cr3t pw'}; print(json.dumps(d))" "$confirmed")
  code=$(curl -s -o "$TMP/r" -w '%{http_code}' -H "X-Token: $TOKEN" -d "$withpw" "$URL/api/install")
  [[ "$code" == 200 ]] && ok "install starts the web terminal" || bad "install starts the web terminal ($code)" "$(cat "$TMP/r")"
  code=$(curl -s -o /dev/null -w '%{http_code}' -H "X-Token: $TOKEN" -d "$withpw" "$URL/api/install")
  [[ "$code" == 409 ]] && ok "only one install at a time" || bad "only one install at a time (got $code)"
  term_text=$(python3 tests/term_client.py "$URL" "$TOKEN" "hello web")
  grep -q "ARGS:--config $TMP/webcfg --yes" <<<"$term_text" && ok "installer runs with --yes" || bad "installer runs with --yes" "$term_text"
  grep -q "TTY:yes" <<<"$term_text" && ok "installer gets a real terminal" || bad "installer gets a real terminal" "$term_text"
  grep -q "PW:s3cr3t pw" <<<"$term_text" && ok "web password reaches the installer" || bad "web password reaches the installer" "$term_text"
  grep -q "GOT:hello web" <<<"$term_text" && ok "web terminal input reaches the installer" || bad "web terminal input reaches the installer" "$term_text"
  grep -q "EXIT 3" <<<"$term_text" && ok "exit code reported" || bad "exit code reported" "$term_text"
  if grep -q "s3cr3t" "$TMP/webcfg"; then bad "password must not be written to the config"; else ok "password not written to the config"; fi
  grep -q "^USERNAME='tester'" "$TMP/webcfg" && ok "install saved disk + username" || bad "install saved disk + username"
  kill "$SERVER_PID"; wait "$SERVER_PID" 2>/dev/null; SERVER_PID=
fi

echo "lockout"
python3 dashboard/server.py --config "$TMP/webcfg" --port "$((PORT + 1))" --bind 127.0.0.1 >"$TMP/server2.log" 2>&1 &
SERVER_PID=$!
for _ in $(seq 50); do grep -q 'Access code' "$TMP/server2.log" && break; sleep 0.1; done
TOKEN2=$(sed -n 's/.*Access code: //p' "$TMP/server2.log" | head -1)
for i in $(seq 20); do curl -s -o /dev/null "http://127.0.0.1:$((PORT + 1))/zzzzzz"; done
code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$((PORT + 1))/$TOKEN2")
[[ "$code" == 403 ]] && ok "locks out after 20 wrong codes" || bad "locks out after 20 wrong codes (got $code)"
kill "$SERVER_PID"; wait "$SERVER_PID" 2>/dev/null; SERVER_PID=

echo
echo "$pass passed, $fail failed"
((fail == 0))
