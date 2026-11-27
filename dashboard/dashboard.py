"""
Trade Copier dashboard.

Reads the status files written by TC_Master / TC_Follower in the MT5
Common\\Files\\TradeCopier folder and shows them in a browser.
Uses only the Python standard library - no installs needed.

    python dashboard.py                 # http://127.0.0.1:8080
    python dashboard.py --port 9000
    python dashboard.py --dir "D:\\some\\other\\TradeCopier"
"""
import argparse
import glob
import json
import os
import re
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))


def default_dir():
    appdata = os.environ.get("APPDATA", os.path.expanduser("~"))
    return os.path.join(appdata, "MetaQuotes", "Terminal", "Common", "Files", "TradeCopier")


_cache = {}


def read_json(path):
    """Read a status file. If the EA is mid-write, fall back to the last good copy."""
    try:
        with open(path, "rb") as f:
            raw = f.read()
        if raw.startswith(b"\xff\xfe") or raw.startswith(b"\xfe\xff"):
            text = raw.decode("utf-16")
        else:
            text = raw.decode("utf-8", errors="replace")
        data = json.loads(text)
        _cache[path] = data
        return data
    except (OSError, ValueError):
        return _cache.get(path)


def state(folder):
    now = int(time.time())
    masters, followers = [], []
    for p in sorted(glob.glob(os.path.join(folder, "master_*.json"))):
        d = read_json(p)
        if d:
            d["age"] = now - int(d.get("updated", 0))
            masters.append(d)
    for p in sorted(glob.glob(os.path.join(folder, "status_*.json"))):
        d = read_json(p)
        if d:
            d["age"] = now - int(d.get("updated", 0))
            followers.append(d)
    return {"now": now, "dir": folder, "exists": os.path.isdir(folder),
            "masters": masters, "followers": followers}


class Handler(BaseHTTPRequestHandler):
    folder = default_dir()

    def log_message(self, *args):
        pass

    def _host_ok(self):
        # Blocks DNS-rebinding: only answer requests addressed to this machine.
        host = (self.headers.get("Host") or "").split(":")[0].strip("[]")
        return host in ("127.0.0.1", "localhost", "::1")

    def _send(self, code, body, ctype="application/json"):
        data = body.encode("utf-8") if isinstance(body, str) else body
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if not self._host_ok():
            return self._send(403, '{"error":"forbidden"}')
        if self.path in ("/", "/index.html"):
            with open(os.path.join(HERE, "index.html"), "rb") as f:
                return self._send(200, f.read(), "text/html; charset=utf-8")
        if self.path == "/api/state":
            return self._send(200, json.dumps(state(self.folder)))
        self._send(404, '{"error":"not found"}')

    def do_POST(self):
        # The custom header can't be sent by another website without a CORS
        # preflight (which we never approve), so pages you visit can't click Pause for you.
        if not self._host_ok() or self.headers.get("X-TC") != "1":
            return self._send(403, '{"error":"forbidden"}')
        if self.path != "/api/pause":
            return self._send(404, '{"error":"not found"}')
        try:
            length = int(self.headers.get("Content-Length", "0"))
            body = json.loads(self.rfile.read(min(length, 4096)) or b"{}")
            login = str(int(body["login"]))
            paused = bool(body["paused"])
        except (ValueError, KeyError, TypeError):
            return self._send(400, '{"error":"bad request"}')
        if not re.fullmatch(r"\d{1,20}", login):
            return self._send(400, '{"error":"bad login"}')
        os.makedirs(self.folder, exist_ok=True)
        with open(os.path.join(self.folder, "control_%s.txt" % login), "w") as f:
            f.write("PAUSE=1" if paused else "PAUSE=0")
        self._send(200, json.dumps({"ok": True, "login": login, "paused": paused}))


def main():
    ap = argparse.ArgumentParser(description="Trade Copier dashboard")
    ap.add_argument("--dir", default=default_dir(), help="TradeCopier folder in MT5 Common\\Files")
    ap.add_argument("--port", type=int, default=8080)
    ap.add_argument("--host", default="127.0.0.1",
                    help="Keep 127.0.0.1 unless you know what you're doing")
    args = ap.parse_args()
    Handler.folder = args.dir
    print("Reading:   %s" % args.dir)
    if not os.path.isdir(args.dir):
        print("           (folder not found yet - start TC_Master in MT5 first)")
    print("Dashboard: http://127.0.0.1:%d   (Ctrl+C to stop)" % args.port)
    ThreadingHTTPServer((args.host, args.port), Handler).serve_forever()


if __name__ == "__main__":
    main()
