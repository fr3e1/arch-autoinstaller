#!/usr/bin/env python3
"""Web dashboard server for arch-autoinstaller.

Runs on the live ISO (python3 is included there) using only the standard
library. Open the printed URL from any device on the same network, pick the
install options and press "Install". The installer then runs in a
pseudo-terminal that is shown both in the browser (web terminal) and on the
machine's own console, so passwords can be typed in either place.

Exit code: the installer's exit code once it has run, otherwise 0.
"""

from __future__ import annotations

import argparse
import base64
import fcntl
import json
import os
import pty
import re
import secrets
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import termios
import threading
import time
import tty
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SCHEMA_FILE = ROOT / "lib" / "options.conf"
INDEX_FILE = Path(__file__).resolve().parent / "index.html"
MAX_BODY = 64 * 1024
TERM_BUFFER = 8 * 1024 * 1024  # bytes of installer output kept for the web terminal
PASSWORD_ENV = {"user": "USER_PASSWORD", "root": "ROOT_PASSWORD", "luks": "LUKS_PASSWORD"}
# Short, easy to type on a phone: no 0/o, 1/l/i look-alikes.
TOKEN_ALPHABET = "abcdefghjkmnpqrstuvwxyz23456789"
TOKEN_LENGTH = 6
MAX_FAILED_ATTEMPTS = 20  # per client IP, then it is locked out


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


CODE_PAGE = b"""<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1"><title>Arch Autoinstaller</title>
<style>body{margin:0;min-height:100vh;display:grid;place-items:center;background:#0f1218;color:#e6e9ef;
font:16px system-ui,sans-serif}form{display:grid;gap:12px;padding:28px;border:1px solid #2a3142;border-radius:12px;
background:#171b23;width:min(340px,calc(100% - 32px))}input{font:24px ui-monospace,monospace;letter-spacing:.3em;
text-align:center;padding:10px;border-radius:8px;border:1px solid #2a3142;background:#1e2330;color:inherit;text-transform:lowercase}
button{padding:12px;border:0;border-radius:8px;background:#1793d1;color:#fff;font:inherit;font-weight:600}
p{margin:0;color:#8b93a7;font-size:14px}</style></head><body>
<form onsubmit="location.href='/'+encodeURIComponent(this.c.value.trim().toLowerCase());return false">
<b>Arch Autoinstaller</b><p>Enter the access code shown in the installer's terminal.</p>
<input name="c" maxlength="16" autocomplete="off" autocapitalize="off" spellcheck="false" autofocus required>
<button>Open dashboard</button></form></body></html>"""


def new_token() -> str:
    return "".join(secrets.choice(TOKEN_ALPHABET) for _ in range(TOKEN_LENGTH))


def install_errors(values: dict) -> list[str]:
    """Extra checks for "Save & install": nothing may be left to ask in the terminal."""
    errors = []
    disk = values.get("DISK", "")
    if not disk:
        errors.append("Pick the disk to install to.")
    else:
        info = system_info()
        match = next((d for d in info["disks"] if d["path"] == disk), None)
        if match is None:
            errors.append(f"{disk} is not a disk on this machine.")
        elif match["live_iso"]:
            errors.append(f"{disk} is the drive the live ISO booted from.")
        elif match["size"] and match["size"] < 8 * 1024**3:
            errors.append(f"{disk} is smaller than 8 GiB.")
    if not values.get("USERNAME"):
        errors.append("Enter a username.")
    elif values["USERNAME"] == "root":
        errors.append("The username cannot be root.")
    return errors


class InstallSession:
    """The installer running in a pseudo-terminal.

    Output is kept in a ring buffer for the web terminal (clients poll with an
    offset) and mirrored to this process's stdout. Input comes from the web
    terminal and, when stdin is a TTY, from the machine's own keyboard.
    """

    def __init__(self, cmd: list[str], env: dict[str, str]):
        self.buf = bytearray()
        self.base = 0  # stream offset of buf[0]
        self.cond = threading.Condition()
        self.exit_code: int | None = None
        self.started = time.time()
        self.console_attrs = None
        pid, fd = pty.fork()
        if pid == 0:  # child
            try:
                os.execvpe(cmd[0], cmd, env)
            finally:
                os._exit(127)
        self.pid, self.fd = pid, fd
        self.resize(120, 32)
        if sys.stdin.isatty():
            try:
                self.console_attrs = termios.tcgetattr(sys.stdin.fileno())
                tty.setraw(sys.stdin.fileno())
                threading.Thread(target=self._console_input, daemon=True).start()
            except termios.error:
                self.console_attrs = None
        threading.Thread(target=self._pump, daemon=True).start()

    def _pump(self) -> None:
        out = sys.stdout.buffer
        while True:
            try:
                data = os.read(self.fd, 65536)
            except OSError:
                data = b""
            if not data:
                break
            try:
                out.write(data)
                out.flush()
            except OSError:
                pass
            with self.cond:
                self.buf += data
                if len(self.buf) > TERM_BUFFER:
                    drop = len(self.buf) - TERM_BUFFER
                    del self.buf[:drop]
                    self.base += drop
                self.cond.notify_all()
        _, status = os.waitpid(self.pid, 0)
        code = os.waitstatus_to_exitcode(status)
        self.restore_console()
        msg = (f"\r\n\x1b[1;32m== Installer finished (exit code {code}) ==\x1b[0m\r\n" if code == 0 else
               f"\r\n\x1b[1;31m== Installer stopped with exit code {code} ==\x1b[0m\r\n")
        print(msg.replace("\x1b[1;32m", "").replace("\x1b[1;31m", "").replace("\x1b[0m", "").strip(), flush=True)
        print("  The dashboard keeps running so you can read the output. Ctrl+C stops it.", flush=True)
        with self.cond:
            self.buf += msg.encode()
            self.exit_code = code
            self.cond.notify_all()
        try:
            os.close(self.fd)
        except OSError:
            pass

    def _console_input(self) -> None:
        while self.exit_code is None:
            try:
                data = os.read(sys.stdin.fileno(), 1024)
            except OSError:
                return
            if not data:
                return
            self.write(data)

    def restore_console(self) -> None:
        if self.console_attrs is not None:
            try:
                termios.tcsetattr(sys.stdin.fileno(), termios.TCSADRAIN, self.console_attrs)
            except termios.error:
                pass
            self.console_attrs = None

    @property
    def done(self) -> bool:
        return self.exit_code is not None

    def read(self, since: int, wait: float) -> dict:
        with self.cond:
            end = self.base + len(self.buf)
            if since >= end and not self.done and wait > 0:
                self.cond.wait(wait)
                end = self.base + len(self.buf)
            since = max(since, self.base)
            data = bytes(self.buf[since - self.base:])
            return {"offset": end, "data": base64.b64encode(data).decode(), "done": self.done,
                    "exit_code": self.exit_code}

    def write(self, data: bytes) -> None:
        if self.done:
            return
        try:
            os.write(self.fd, data)
        except OSError:
            pass

    def resize(self, cols: int, rows: int) -> None:
        if self.done:
            return
        cols, rows = max(20, min(cols, 400)), max(5, min(rows, 200))
        try:
            fcntl.ioctl(self.fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
        except OSError:
            pass

    def stop(self) -> None:
        if not self.done:
            try:
                os.kill(self.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
        self.restore_console()


def password_errors(passwords: dict) -> list[str]:
    errors = []
    for kind, value in passwords.items():
        if kind not in PASSWORD_ENV:
            errors.append(f"unknown password field {kind}")
        elif not isinstance(value, str) or not value or "\n" in value or "\0" in value:
            errors.append(f"the {kind} password is empty or contains a line break")
    return errors


class Handler(BaseHTTPRequestHandler):
    server_version = "arch-autoinstaller"
    # set in main()
    token: str = ""
    config_path: Path
    installer: Path
    session: InstallSession | None = None
    session_lock = threading.Lock()
    httpd: ThreadingHTTPServer
    failures: dict[str, int] = {}
    lock = threading.Lock()

    def log_message(self, fmt, *args):  # keep the console quiet
        pass

    # -- helpers --------------------------------------------------------
    def _supplied_token(self) -> str:
        supplied = self.headers.get("X-Token", "")
        if not supplied and "?" in self.path:
            from urllib.parse import parse_qs, urlparse
            supplied = parse_qs(urlparse(self.path).query).get("token", [""])[0]
        if not supplied:  # http://host/<token>
            supplied = self.path.split("?", 1)[0].strip("/")
        return supplied.strip().lower()

    def _locked_out(self) -> bool:
        with self.lock:
            return self.failures.get(self.client_address[0], 0) >= MAX_FAILED_ATTEMPTS

    def _authorized(self) -> bool:
        if not self.token:
            return True
        if self._locked_out():
            return False
        ok = secrets.compare_digest(self._supplied_token().encode(), self.token.encode())
        if not ok:
            with self.lock:
                ip = self.client_address[0]
                self.failures[ip] = self.failures.get(ip, 0) + 1
        return ok

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
        if route == "/favicon.ico":
            return self._send(HTTPStatus.NO_CONTENT, b"", "text/plain")
        if not route.startswith("/api/"):
            if route != "/" and not re.fullmatch(r"/[A-Za-z0-9]{4,16}/?", route):
                return self._send(HTTPStatus.NOT_FOUND, b"Not found", "text/plain")
            # The page itself: http://host/<code> (or /?token=<code>)
            if self.token and not self._supplied_token() and not self._locked_out():
                return self._send(200, CODE_PAGE, "text/html; charset=utf-8")
            if not self._authorized():
                msg = (b"Too many wrong codes from this device. Restart ./install.sh --web."
                       if self._locked_out() else
                       b"Wrong or missing code. Open the exact link shown in the installer's terminal.")
                return self._send(HTTPStatus.FORBIDDEN, msg, "text/plain; charset=utf-8")
            return self._send(200, INDEX_FILE.read_bytes(), "text/html; charset=utf-8")
        if not self._authorized():
            return self._json({"error": "forbidden"}, HTTPStatus.FORBIDDEN)
        if route == "/api/schema":
            return self._json(SCHEMA)
        if route == "/api/config":
            return self._json(read_config(self.config_path))
        if route == "/api/info":
            return self._json(system_info())
        if route == "/api/status":
            s = Handler.session
            return self._json({"installing": bool(s and not s.done), "ran": bool(s),
                               "exit_code": s.exit_code if s else None})
        if route == "/api/term":
            from urllib.parse import parse_qs, urlparse
            q = parse_qs(urlparse(self.path).query)
            s = Handler.session
            if not s:
                return self._json({"error": "the installer is not running"}, HTTPStatus.CONFLICT)
            since = int((q.get("since") or ["0"])[0] or 0)
            wait = 20.0 if (q.get("wait") or ["0"])[0] == "1" else 0.0
            return self._json(s.read(since, wait))
        self._json({"error": "not found"}, HTTPStatus.NOT_FOUND)

    def do_POST(self):
        if not self._authorized():
            return self._json({"error": "forbidden"}, HTTPStatus.FORBIDDEN)
        route = self.path.split("?", 1)[0]
        try:
            body = self._body()
        except ValueError as e:
            return self._json({"ok": False, "errors": [str(e)]}, HTTPStatus.BAD_REQUEST)

        # Web terminal input / resize
        if route in ("/api/term/input", "/api/term/resize"):
            s = Handler.session
            if not s or s.done:
                return self._json({"ok": False, "errors": ["the installer is not running"]}, HTTPStatus.CONFLICT)
            if route == "/api/term/input":
                data = body.get("data", "")
                if not isinstance(data, str) or len(data) > 4096:
                    return self._json({"ok": False}, HTTPStatus.BAD_REQUEST)
                s.write(data.encode())
            else:
                try:
                    s.resize(int(body.get("cols", 80)), int(body.get("rows", 24)))
                except (TypeError, ValueError):
                    return self._json({"ok": False}, HTTPStatus.BAD_REQUEST)
            return self._json({"ok": True})

        if Handler.session and not Handler.session.done and route in ("/api/save", "/api/install"):
            return self._json({"ok": False, "errors": ["The installer is already running."]}, HTTPStatus.CONFLICT)

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

        passwords = {k: v for k, v in (body.get("passwords") or {}).items() if v not in (None, "")}
        if route == "/api/install":
            errors = install_errors(values) + password_errors(passwords)
            if body.get("confirm_disk", "").strip() not in (values.get("DISK"), values.get("DISK", "").removeprefix("/dev/")):
                errors.append("Type the disk name to confirm that it will be erased.")
            if errors:
                return self._json({"ok": False, "errors": errors}, HTTPStatus.BAD_REQUEST)

        if route in ("/api/save", "/api/install"):
            write_config(self.config_path, values)
            if route == "/api/install":
                with Handler.session_lock:
                    if Handler.session and not Handler.session.done:
                        return self._json({"ok": False, "errors": ["The installer is already running."]}, HTTPStatus.CONFLICT)
                    env = {**os.environ, "TERM": "xterm-256color"}
                    for k in PASSWORD_ENV.values():
                        env.pop(k, None)
                    for kind, value in passwords.items():
                        env[PASSWORD_ENV[kind]] = value  # passed to the child only, never written to disk
                    print("\n  Options confirmed in the browser. Starting the installer...\n", flush=True)
                    Handler.session = InstallSession(
                        ["bash", str(self.installer), "--config", str(self.config_path), "--yes"], env)
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
    ap.add_argument("--port", type=int, default=0, help="default: 80 when root, else 8080")
    ap.add_argument("--bind", default="0.0.0.0")
    ap.add_argument("--installer", default=str(ROOT / "install.sh"))
    ap.add_argument("--no-token", action="store_true", help="disable the access token (local testing only)")
    args = ap.parse_args()

    Handler.config_path = Path(args.config).resolve()
    Handler.installer = Path(args.installer).resolve()
    Handler.token = "" if args.no_token else new_token()
    ports = [args.port] if args.port else ([80, 8080] if os.geteuid() == 0 else [8080])
    httpd = None
    for port in ports:
        try:
            httpd = ThreadingHTTPServer((args.bind, port), Handler)
            break
        except OSError as e:
            last_error = e
    if httpd is None:
        print(f"Could not start the web server on port {'/'.join(map(str, ports))}: {last_error}", file=sys.stderr)
        return 1
    port = httpd.server_address[1]
    Handler.httpd = httpd

    host_port = "" if port == 80 else f":{port}"
    path = f"/{Handler.token}" if Handler.token else "/"
    bold, reset = ("\033[1m", "\033[0m") if sys.stdout.isatty() else ("", "")
    print("\n  arch-autoinstaller web dashboard is running.")
    print("  On your phone or another computer on this network, open:\n")
    for addr in (local_addresses() if args.bind in ("0.0.0.0", "") else [args.bind]):
        print(f"    {bold}http://{addr}{host_port}{path}{reset}")
    if Handler.token:
        print(f"\n  Access code: {bold}{Handler.token}{reset}")
    print("\n  Pick your options there and press \"Install\". The installer then runs in")
    print("  the browser's terminal and here at the same time; type passwords in either.")
    print("  Ctrl+C stops the dashboard.\n", flush=True)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print()
    finally:
        if Handler.session:
            Handler.session.stop()
        httpd.server_close()
    s = Handler.session
    return s.exit_code if s and s.exit_code is not None else 0


if __name__ == "__main__":
    sys.exit(main())
