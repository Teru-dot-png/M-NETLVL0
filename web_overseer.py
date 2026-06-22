#!/usr/bin/env python3
"""
O-NET V1 | WEB OVERSEER
================================================================
HTTP bridge between CC:Tweaked overseer and the web dashboard.

- Receives voxel data (GEO_DATA) from CC overseer via POST.
- Stores voxels in RAM with no disk size limit.
- Serves the web dashboard at http://localhost:PORT/
- Provides REST API for dashboard to read live state.
- Queues commands typed in web terminal for CC to execute.

Usage:
    python3 web_overseer.py
    python3 web_overseer.py --port 8080 --host 0.0.0.0

In main_mapper.lua, set:
    WEB_API_URL = "http://YOUR_PC_IP:8080"
"""

import json
import threading
import time
import argparse
import os
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse, parse_qs

# ── In-memory state ──────────────────────────────────────────────────────────
_lock = threading.Lock()

# Voxels stored as voxels[y][x][z] = "block_name"
# Python dict of dicts -- handles tens of millions of entries easily.
voxels: dict = {}

# fleet[hwid] = {status, fuel, free, pos:{x,y,z}}
fleet: dict = {}

# Ore discovery feed (capped ring-buffer)
ore_feed: list = []
ORE_FEED_MAX = 200

# Alerts from CC
alerts: list = []
ALERT_MAX = 100

# Commands queued by web UI, to be polled by CC overseer
cmd_queue: list = []

# Results of executed commands sent back by CC
cmd_results: list = []
RESULTS_MAX = 100

# Stats
voxel_count: int = 0

# ── Voxel helpers ─────────────────────────────────────────────────────────────
def _set_voxel(x: int, y: int, z: int, name: str | None):
    global voxel_count
    y, x, z = int(y), int(x), int(z)
    if y not in voxels:
        voxels[y] = {}
    if x not in voxels[y]:
        voxels[y][x] = {}
    if name is None or name == "":
        if z in voxels[y][x]:
            del voxels[y][x][z]
            voxel_count -= 1
    else:
        if z not in voxels[y][x]:
            voxel_count += 1
        voxels[y][x][z] = name


def ingest_scan(scan_data: list, ox: int = 0, oy: int = 0, oz: int = 0) -> int:
    added = 0
    with _lock:
        for b in scan_data:
            if not isinstance(b, dict):
                continue
            name = b.get("name", "")
            if not name:
                continue
            # Filter air and noise
            if "air" in name or "turtle" in name.lower():
                continue
            bx = int(b.get("x", 0)) + ox
            by = int(b.get("y", 0)) + oy
            bz = int(b.get("z", 0)) + oz
            _set_voxel(bx, by, bz, name)
            added += 1
    return added


def get_map_slice(cx: int, y: int, cz: int, rx: int = 50, rz: int = 40) -> list:
    """Return voxels in a rectangle centered at (cx,y,cz) with half-extents rx,rz."""
    result = []
    MAX = 8000
    with _lock:
        layer = voxels.get(int(y), {})
        x1, x2 = int(cx) - int(rx), int(cx) + int(rx)
        z1, z2 = int(cz) - int(rz), int(cz) + int(rz)
        for xi in range(x1, x2 + 1):
            col = layer.get(xi)
            if not col:
                continue
            for zi in range(z1, z2 + 1):
                name = col.get(zi)
                if name:
                    result.append({"x": xi, "y": int(y), "z": zi, "n": name})
                    if len(result) >= MAX:
                        return result
    return result


def get_stats() -> dict:
    with _lock:
        return {
            "voxels": voxel_count,
            "y_layers": len(voxels),
            "fleet_size": len(fleet),
        }

# ── HTML file loading ─────────────────────────────────────────────────────────
_THIS_DIR = os.path.dirname(os.path.abspath(__file__))

def _load_html():
    path = os.path.join(_THIS_DIR, "web_ui.html")
    if os.path.exists(path):
        with open(path, "rb") as f:
            return f.read()
    return b"<h1>web_ui.html not found next to web_overseer.py</h1>"


# ── Timestamp helper ──────────────────────────────────────────────────────────
def _ts():
    return time.strftime("%H:%M:%S")


# ── HTTP Handler ──────────────────────────────────────────────────────────────
class _Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        # Suppress default per-request log; print only interesting events.
        pass

    # ── helpers ──────────────────────────────────────────────────────────────
    def _cors(self):
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET,POST,OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")

    def _json(self, data, code=200):
        body = json.dumps(data, separators=(",", ":")).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self._cors()
        self.end_headers()
        self.wfile.write(body)

    def _read_json(self):
        n = int(self.headers.get("Content-Length", 0))
        if n == 0:
            return {}
        try:
            return json.loads(self.rfile.read(n).decode())
        except Exception:
            return {}

    # ── OPTIONS (pre-flight) ─────────────────────────────────────────────────
    def do_OPTIONS(self):
        self.send_response(200)
        self._cors()
        self.end_headers()

    # ── GET ──────────────────────────────────────────────────────────────────
    def do_GET(self):
        parsed = urlparse(self.path)
        qs = parse_qs(parsed.query)
        path = parsed.path.rstrip("/") or "/"

        # ── Dashboard HTML ────────────────────────────────────────────────
        if path in ("/", "/index.html"):
            body = _load_html()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self._cors()
            self.end_headers()
            self.wfile.write(body)
            return

        # ── Full state snapshot for dashboard polling ─────────────────────
        elif path == "/api/state":
            with _lock:
                fleet_snap = {k: dict(v) for k, v in fleet.items()}
                feed_snap  = list(ore_feed[-50:])
                alert_snap = list(alerts[-20:])
                results    = list(cmd_results[-20:])
            self._json({
                "fleet":      fleet_snap,
                "ore_feed":   feed_snap,
                "alerts":     alert_snap,
                "cmd_results": results,
                "stats":      get_stats(),
                "t":          time.time(),
            })

        # ── Voxel map slice ───────────────────────────────────────────────
        elif path == "/api/map":
            cx = int(qs.get("cx", [0])[0])
            y  = int(qs.get("y",  [64])[0])
            cz = int(qs.get("cz", [0])[0])
            rx = min(int(qs.get("rx", [60])[0]), 120)
            rz = min(int(qs.get("rz", [50])[0]), 120)
            self._json({"voxels": get_map_slice(cx, y, cz, rx, rz)})

        # ── CC overseer polls here for pending web commands ───────────────
        elif path == "/api/poll":
            with _lock:
                pending = list(cmd_queue)
                cmd_queue.clear()
            self._json({"cmds": pending})

        else:
            self._json({"error": "not found"}, 404)

    # ── POST ─────────────────────────────────────────────────────────────────
    def do_POST(self):
        parsed = urlparse(self.path)
        body   = self._read_json()
        path   = parsed.path.rstrip("/")

        # ── GEO_DATA: voxels from CC overseer ────────────────────────────
        if path == "/api/geo":
            p  = body.get("pos", {})
            ox = int(p.get("x", 0))
            oy = int(p.get("y", 0))
            oz = int(p.get("z", 0))
            added = ingest_scan(body.get("scan_data", []), ox, oy, oz)
            self._json({"ok": True, "added": added, "total": voxel_count})

        # ── Fleet snapshot ────────────────────────────────────────────────
        elif path == "/api/fleet":
            snap = body.get("fleet", {})
            with _lock:
                fleet.clear()
                fleet.update(snap)
            self._json({"ok": True, "bots": len(fleet)})

        # ── Single ore discovery ──────────────────────────────────────────
        elif path == "/api/ore":
            entry = {
                "t":    _ts(),
                "hwid": body.get("hwid", "?"),
                "ore":  body.get("ore",  "?"),
                "x":    body.get("x", 0),
                "y":    body.get("y", 0),
                "z":    body.get("z", 0),
            }
            with _lock:
                ore_feed.append(entry)
                if len(ore_feed) > ORE_FEED_MAX:
                    ore_feed.pop(0)
            self._json({"ok": True})

        # ── Alert ─────────────────────────────────────────────────────────
        elif path == "/api/alert":
            with _lock:
                alerts.append({"t": _ts(), "msg": body.get("msg", "?")})
                if len(alerts) > ALERT_MAX:
                    alerts.pop(0)
            self._json({"ok": True})

        # ── Command from web UI → queued for CC to poll ───────────────────
        elif path == "/api/cmd":
            cmd = body.get("cmd", "").strip()
            if cmd:
                with _lock:
                    cmd_queue.append({"cmd": cmd, "t": _ts()})
            print(f"[WEB CMD] queued: {cmd}")
            self._json({"ok": True, "queued": cmd})

        # ── Command result from CC overseer ───────────────────────────────
        elif path == "/api/result":
            with _lock:
                cmd_results.append({
                    "t":      _ts(),
                    "cmd":    body.get("cmd", ""),
                    "result": body.get("result", ""),
                })
                if len(cmd_results) > RESULTS_MAX:
                    cmd_results.pop(0)
            self._json({"ok": True})

        else:
            self._json({"error": "not found"}, 404)


# ── Entry point ───────────────────────────────────────────────────────────────
def main():
    ap = argparse.ArgumentParser(description="O-NET V1 Web Overseer")
    ap.add_argument("--host", default="0.0.0.0", help="Bind host (default 0.0.0.0)")
    ap.add_argument("--port", type=int, default=8080, help="HTTP port (default 8080)")
    args = ap.parse_args()

    srv = HTTPServer((args.host, args.port), _Handler)
    import socket
    local_ip = socket.gethostbyname(socket.gethostname())

    print("=" * 60)
    print("  O-NET V1  WEB OVERSEER")
    print("=" * 60)
    print(f"  Dashboard : http://localhost:{args.port}/")
    print(f"  Network   : http://{local_ip}:{args.port}/")
    print(f"  API state : http://localhost:{args.port}/api/state")
    print()
    print("  In main_mapper.lua set:")
    print(f'  WEB_API_URL = "http://{local_ip}:{args.port}"')
    print("=" * 60)

    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        print("\nShutting down.")
        srv.shutdown()


if __name__ == "__main__":
    main()
