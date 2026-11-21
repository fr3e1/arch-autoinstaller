#!/usr/bin/env python3
"""Web dashboard server for arch-autoinstaller.

Runs on the live ISO (python3 is included there) using only the standard
library. Open the printed URL from any device on the same network, pick the
install options and press "Save & install" to hand control back to
install.sh.

Exit codes: 0 = stopped (Ctrl+C or "Save only"), 10 = start the install.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import secrets
import socket
import subprocess
import sys
import tempfile
import threading
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SCHEMA_FILE = ROOT / "lib" / "options.conf"
INDEX_FILE = Path(__file__).resolve().parent / "index.html"
EXIT_INSTALL = 10
MAX_BODY = 64 * 1024


def load_schema() -> list[dict]:
    options = []
    for line in SCHEMA_FILE.read_text().splitlines():
        if not line.strip() or line.startswith("#"):
            continue
        key, kind, rule, section, label = line.split("|", 4)
        opt = {"key": key, "kind": kind, "section": section, "label": label}
        if kind == "enum":
            opt["choices"] = rule.split(",")
        elif kind == "text":
            opt["pattern"] = rule
        options.append(opt)
    return options


SCHEMA = load_schema()
SCHEMA_BY_KEY = {o["key"]: o for o in SCHEMA}
DISK_RE = re.compile(r"^(/dev/[A-Za-z0-9/_-]+)?$")


def validate(values: dict) -> list[str]:
    errors = []
    for opt in SCHEMA:
        key = opt["key"]
        value = values.get(key, "")
        if not isinstance(value, str) or "\n" in value or "\0" in value:
            errors.append(f"{key}: invalid value")
            continue
        if opt["kind"] == "enum" and value not in opt["choices"]:
            errors.append(f"{key}: must be one of {', '.join(opt['choices'])}")
        elif opt["kind"] == "text" and not re.search(opt["pattern"], value):
            errors.append(f"{key}: invalid value '{value}'")
        elif opt["kind"] == "disk" and not DISK_RE.match(value):
            errors.append(f"{key}: must be a device path like /dev/sda")
    unknown = set(values) - set(SCHEMA_BY_KEY)
    if unknown:
        errors.append("unknown options: " + ", ".join(sorted(unknown)))
    return errors


def read_config(path: Path) -> dict:
    """Read KEY='value' lines. Uses bash itself so any valid config works."""
    keys = " ".join(SCHEMA_BY_KEY)
    script = (
        'source "$1" >/dev/null 2>&1; shift; '
        'for k in "$@"; do printf "%s\\0%s\\0" "$k" "${!k-}"; done'
    )
    try:
        out = subprocess.run(
            ["bash", "-c", script, "bash", str(path), *keys.split()],
            capture_output=True, check=True, timeout=10,
        ).stdout.decode()
    except (subprocess.SubprocessError, OSError):
        return {}
    parts = out.split("\0")
    values = dict(zip(parts[0::2], parts[1::2]))
    values.pop("", None)
    if values.get("DISK") and not values["DISK"].startswith("/"):
        values["DISK"] = "/dev/" + values["DISK"]
    if values.get("LOCALE", "").endswith(" UTF-8"):
        values["LOCALE"] = values["LOCALE"][: -len(" UTF-8")]
    return values


def sh_quote(value: str) -> str:
    """Always single-quote, matching shell_quote in lib/common.sh."""
    return "'" + value.replace("'", "'\\''") + "'"


def write_config(path: Path, values: dict) -> None:
    """Replace KEY= lines in place (keeping comments) and append missing ones."""
    lines = path.read_text().splitlines() if path.exists() else []
    seen = set()
    out = []
    for line in lines:
        m = re.match(r"^([A-Z_]+)=", line)
        if m and m.group(1) in values:
            key = m.group(1)
            out.append(f"{key}={sh_quote(values[key])}")
            seen.add(key)
        else:
            out.append(line)
    for opt in SCHEMA:
        if opt["key"] not in seen and opt["key"] in values:
            out.append(f"{opt['key']}={sh_quote(values[opt['key']])}")
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=".config-")
    with os.fdopen(fd, "w") as f:
        f.write("\n".join(out) + "\n")
    os.replace(tmp, path)


def run(cmd: list[str]) -> str:
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=10).stdout
    except (subprocess.SubprocessError, OSError):
        return ""


def system_info() -> dict:
    disks = []
    try:
        data = json.loads(run(["lsblk", "-J", "-b", "-d", "-o", "NAME,PATH,SIZE,MODEL,TRAN,TYPE,RM"]) or "{}")
        for dev in data.get("blockdevices", []):
            if dev.get("type") != "disk" or re.match(r"(loop|sr|zram|ram)", dev.get("name", "")):
                continue
            disks.append({
                "path": dev.get("path") or "/dev/" + dev["name"],
                "size": int(dev.get("size") or 0),
                "model": (dev.get("model") or "").strip(),
                "tran": dev.get("tran") or "",
                "removable": bool(dev.get("rm")),
            })
    except (ValueError, KeyError):
        pass
    iso_src = run(["findmnt", "-no", "SOURCE", "/run/archiso/bootmnt"]).strip()
    iso_disk = run(["lsblk", "-npo", "PKNAME", iso_src]).strip().splitlines()[:1] if iso_src else []
    for d in disks:
        d["live_iso"] = d["path"] in iso_disk

    cpu = "none"
    try:
        text = Path("/proc/cpuinfo").read_text()
        cpu = "intel" if "GenuineIntel" in text else "amd" if "AuthenticAMD" in text else "none"
    except OSError:
        pass
    virt = run(["systemd-detect-virt"]).strip()
    gpus = [l for l in run(["lspci"]).splitlines() if re.search(r"vga|3d|display", l, re.I)]
    if virt and virt != "none":
        gpu = "vm"
    elif any("nvidia" in g.lower() for g in gpus):
        gpu = "nvidia"
    elif any(re.search(r"amd|ati|radeon", g, re.I) for g in gpus):
        gpu = "amd"
    elif any("intel" in g.lower() for g in gpus):
        gpu = "intel"
    else:
        gpu = "none"
    try:
        mem = int(re.search(r"MemTotal:\s+(\d+)", Path("/proc/meminfo").read_text()).group(1)) * 1024
    except (OSError, AttributeError):
        mem = 0
    return {
        "boot_mode": "UEFI" if Path("/sys/firmware/efi/efivars").is_dir() else "BIOS",
        "disks": disks,
        "cpu": cpu,
        "gpu": gpu,
        "gpus": [g.split(": ", 1)[-1] for g in gpus],
        "virt": virt if virt != "none" else "",
        "memory": mem,
        "hostname": socket.gethostname(),
        "live_iso": Path("/run/archiso").is_dir(),
    }


class Handler(BaseHTTPRequestHandler):
    server_version = "arch-autoinstaller"
    # set in main()
    token: str = ""
    config_path: Path
    installer: Path
    exit_code = 0
    httpd: ThreadingHTTPServer

    def log_message(self, fmt, *args):  # keep the console quiet
        pass

    # -- helpers --------------------------------------------------------
    def _authorized(self) -> bool:
        if not self.token:
            return True
        supplied = self.headers.get("X-Token", "")
        if not supplied and "?" in self.path:
            from urllib.parse import parse_qs, urlparse
            supplied = parse_qs(urlparse(self.path).query).get("token", [""])[0]
        return secrets.compare_digest(supplied, self.token)

    def _send(self, status: int, body: bytes, ctype: str = "application/json") -> None:
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        self.wfile.write(body)

    def _json(self, obj, status: int = 200) -> None:
        self._send(status, json.dumps(obj).encode())

    def _body(self) -> dict:
        length = int(self.headers.get("Content-Length") or 0)
        if length > MAX_BODY:
            raise ValueError("request too large")
        data = json.loads(self.rfile.read(length) or b"{}")
        if not isinstance(data, dict):
            raise ValueError("expected a JSON object")
        return data

    # -- routes ---------------------------------------------------------
    def do_GET(self):
        route = self.path.split("?", 1)[0]
        if route in ("/", "/index.html"):
            if not self._authorized():
                return self._send(HTTPStatus.FORBIDDEN, b"Missing or wrong token. Use the full URL printed by install.sh.", "text/plain")
            return self._send(200, INDEX_FILE.read_bytes(), "text/html; charset=utf-8")
        if not self._authorized():
            return self._json({"error": "forbidden"}, HTTPStatus.FORBIDDEN)
        if route == "/api/schema":
            return self._json(SCHEMA)
        if route == "/api/config":
            return self._json(read_config(self.config_path))
        if route == "/api/info":
            return self._json(system_info())
        self._json({"error": "not found"}, HTTPStatus.NOT_FOUND)

    def do_POST(self):
        if not self._authorized():
            return self._json({"error": "forbidden"}, HTTPStatus.FORBIDDEN)
        route = self.path.split("?", 1)[0]
        try:
            body = self._body()
        except ValueError as e:
            return self._json({"ok": False, "errors": [str(e)]}, HTTPStatus.BAD_REQUEST)
        values = {k: str(v) for k, v in (body.get("config") or {}).items()}
        errors = validate(values)
        if errors:
            return self._json({"ok": False, "errors": errors}, HTTPStatus.BAD_REQUEST)

        if route == "/api/plan":
            # Run the real installer in --check mode against a temp copy.
            with tempfile.TemporaryDirectory() as d:
                tmp = Path(d) / "config"
                write_config(tmp, values)
                proc = subprocess.run(
                    ["bash", str(self.installer), "--check", "--config", str(tmp)],
                    capture_output=True, text=True, timeout=30, env={**os.environ, "NO_COLOR": "1"},
                )
            return self._json({"ok": proc.returncode == 0, "output": proc.stdout + proc.stderr})

        if route in ("/api/save", "/api/install"):
            write_config(self.config_path, values)
            if route == "/api/install":
                Handler.exit_code = EXIT_INSTALL
                print("\n  Config saved. Continue the install in this terminal.", flush=True)
                threading.Thread(target=self.httpd.shutdown, daemon=True).start()
            else:
                print(f"  Config saved to {self.config_path}", flush=True)
            return self._json({"ok": True})
        self._json({"error": "not found"}, HTTPStatus.NOT_FOUND)


def local_addresses() -> list[str]:
    out = run(["ip", "-4", "-o", "addr", "show", "scope", "global"])
    addrs = re.findall(r"inet (\d+\.\d+\.\d+\.\d+)", out)
    return addrs or ["127.0.0.1"]


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--config", default=str(ROOT / "config"))
    ap.add_argument("--port", type=int, default=8080)
    ap.add_argument("--bind", default="0.0.0.0")
    ap.add_argument("--installer", default=str(ROOT / "install.sh"))
    ap.add_argument("--no-token", action="store_true", help="disable the access token (local testing only)")
    args = ap.parse_args()

    Handler.config_path = Path(args.config).resolve()
    Handler.installer = Path(args.installer).resolve()
    Handler.token = "" if args.no_token else secrets.token_urlsafe(9)
    try:
        httpd = ThreadingHTTPServer((args.bind, args.port), Handler)
    except OSError as e:
        print(f"Could not listen on port {args.port}: {e}", file=sys.stderr)
        return 1
    Handler.httpd = httpd

    q = f"/?token={Handler.token}" if Handler.token else "/"
    print("\n  arch-autoinstaller web dashboard is running. Open one of:\n")
    for addr in local_addresses():
        print(f"    http://{addr}:{args.port}{q}")
    print("\n  Press \"Save & install\" in the browser to continue, or Ctrl+C to stop.\n", flush=True)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print()
    finally:
        httpd.server_close()
    return Handler.exit_code


if __name__ == "__main__":
    sys.exit(main())
