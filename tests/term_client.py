"""Test helper: drive the web terminal API like the browser does.

Usage: python3 tests/term_client.py URL TOKEN ANSWER
Reads installer output until it prints "answer:", sends ANSWER + Enter, then
reads until the installer exits. Prints the output and "EXIT <code>".
"""
import base64
import json
import sys
import time
import urllib.request

url, token, answer = sys.argv[1:4]


def call(path, body=None):
    req = urllib.request.Request(url + path, data=json.dumps(body).encode() if body is not None else None,
                                 headers={"X-Token": token, "Content-Type": "application/json"})
    return json.load(urllib.request.urlopen(req, timeout=30))


out, offset, answered, deadline = b"", 0, False, time.time() + 20
while time.time() < deadline:
    r = call(f"/api/term?since={offset}&wait=1")
    out += base64.b64decode(r["data"])
    offset = r["offset"]
    if b"answer:" in out and not answered:
        call("/api/term/resize", {"cols": 100, "rows": 30})
        call("/api/term/input", {"data": answer + "\r"})
        answered = True
    if r["done"]:
        print(out.decode(errors="replace"))
        print("EXIT", r["exit_code"])
        break
else:
    print(out.decode(errors="replace"))
    print("TIMEOUT")
