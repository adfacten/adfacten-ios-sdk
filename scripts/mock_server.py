#!/usr/bin/env python3
"""Local stand-in for the Adfacten tracker's /m/v1 API for SDK demos.

    python3 scripts/mock_server.py [--port 8197]

Serves test ads for every format (banner image, interstitial HTML, rewarded VAST video,
native, app-open image), logs every request and beacon to stdout, and 302s clicks to
https://adfacten.com/. Video needs ffmpeg (a 5 s mp4 is generated once). Stdlib only.
"""
import argparse
import email.utils
import json
import os
import shutil
import struct
import subprocess
import sys
import tempfile
import time
import uuid
import zlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

CACHE = os.path.join(tempfile.gettempdir(), "adfacten-mock")
COLORS = {"banner": (232, 93, 4), "app_open": (20, 110, 190), "native": (40, 150, 90), "icon": (90, 60, 160)}


def png(w, h, rgb):
    """Solid-colour PNG with a lighter diagonal band, no dependencies."""
    rows = []
    for y in range(h):
        row = bytearray([0])
        for x in range(w):
            band = (x + y) % 80 < 40
            r, g, b = rgb
            row += bytes((min(255, r + 40), min(255, g + 40), min(255, b + 40)) if band else (r, g, b))
        rows.append(bytes(row))
    raw = zlib.compress(b"".join(rows), 6)

    def chunk(t, d):
        return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF)

    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)) + chunk(b"IDAT", raw) + chunk(b"IEND", b"")


def video_path():
    path = os.path.join(CACHE, "test5s.mp4")
    if not os.path.exists(path) and shutil.which("ffmpeg"):
        os.makedirs(CACHE, exist_ok=True)
        subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-f", "lavfi", "-i", "testsrc2=size=1280x720:rate=30:duration=5",
                        "-f", "lavfi", "-i", "sine=frequency=440:duration=5", "-c:v", "libx264", "-pix_fmt", "yuv420p",
                        "-c:a", "aac", "-shortest", "-movflags", "+faststart", path], check=False)
    return path if os.path.exists(path) else None


class Handler(BaseHTTPRequestHandler):
    server_version = "AdfactenMock/1"

    def log_message(self, fmt, *args):
        pass

    def say(self, msg):
        print(time.strftime("%H:%M:%S"), msg, flush=True)

    def base(self):
        return f"http://{self.headers.get('Host', '127.0.0.1')}"

    def send(self, status, body=b"", ctype="application/json", extra=None):
        self.send_response(status)
        self.send_header("Date", email.utils.formatdate(usegmt=True))
        if body:
            self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        if body and self.command != "HEAD":
            self.wfile.write(body)

    # --- /m/v1/ad -----------------------------------------------------------------------------
    def do_POST(self):
        path = urlparse(self.path).path
        if path != "/m/v1/ad":
            return self.send(404)
        raw = self.rfile.read(int(self.headers.get("Content-Length", "0") or 0))
        try:
            req = json.loads(raw)
        except ValueError:
            return self.send(400, json.dumps({"code": "invalid_request", "message": "bad json"}).encode())
        ua = self.headers.get("User-Agent", "")
        dev = req.get("device", {})
        self.say(f"AD  format={req.get('format')} placement={req.get('placement')} sizes={req.get('sizes')} "
                 f"ifa_type={dev.get('ifa_type')} lmt={dev.get('lmt')} sdk_id={dev.get('sdk_id')} test={req.get('test')} "
                 f"user={req.get('user')} UA='{ua}'")
        missing = [k for k in ("app_key", "placement", "format") if not req.get(k)]
        if not dev.get("sdk_id") or not (req.get("app") or {}).get("bundle"):
            missing.append("device.sdk_id/app.bundle")
        if missing or not ua.startswith("AdfactenSDK/"):
            return self.send(400, json.dumps({"code": "invalid_request", "message": f"missing {missing} or bad UA"}).encode())
        if req.get("regs", {}).get("coppa") in (True, 1):
            return self.send(403, json.dumps({"code": "coppa", "message": "child-directed"}).encode())
        if req.get("placement", "").endswith("_nofill"):
            return self.send(204)
        self.send(200, json.dumps({"ad": self.make_ad(req)}).encode())

    def make_ad(self, req):
        fmt = req["format"]
        imp = "mock-" + uuid.uuid4().hex[:12]
        b = self.base()
        tr = {e: f"{b}/i?imp={imp}&e={e}" for e in ("render", "view", "complete", "close")}
        ad = {"id": imp, "format": fmt, "click_url": f"{b}/a/click?imp={imp}", "trackers": tr,
              "view_rule": {"min_ratio": 0.5, "min_ms": 1000}, "close_after_s": 0, "label": "Test ad",
              "expires_at": int(time.time()) + 55 * 60, "test": True}
        if fmt == "banner":
            w, h = (req.get("sizes") or ["320x50"])[0].split("x")
            ad.update(kind="image", w=int(w), h=int(h),
                      image={"url": f"{b}/creative/banner_{w}x{h}.png", "url_2x": f"{b}/creative/banner_{int(w)*2}x{int(h)*2}.png"})
        elif fmt == "interstitial":
            ad.update(kind="html", w=320, h=480, close_after_s=3, html=(
                "<!doctype html><html><head><meta name=viewport content='width=device-width,initial-scale=1'></head>"
                "<body style='margin:0;height:100vh;display:flex;align-items:center;justify-content:center;"
                "background:linear-gradient(135deg,#ff7a18,#af002d);font:600 24px -apple-system;color:#fff;text-align:center'>"
                f"<a href='{b}/a/click?imp={imp}' style='color:#fff'>Adfacten<br>HTML5 test ad<br><small>tap me</small></a>"
                "</body></html>"))
        elif fmt == "rewarded":
            ad.update(kind="video", w=1280, h=720, close_after_s=5, reward={"type": "coins", "amount": 10}, vast=(
                f"<VAST version=\"4.1\"><Ad id=\"{imp}\"><InLine><AdSystem>AdfactenMock</AdSystem><AdTitle>Test</AdTitle>"
                f"<Impression><![CDATA[{b}/i?imp={imp}&e=vast_impression]]></Impression>"
                f"<Error><![CDATA[{b}/i?imp={imp}&e=vast_error&code=[ERRORCODE]]]></Error>"
                "<Creatives><Creative><Linear><Duration>00:00:05</Duration><TrackingEvents>"
                + "".join(f"<Tracking event=\"{e}\"><![CDATA[{b}/i?imp={imp}&e=vast_{e}]]></Tracking>"
                          for e in ("start", "firstQuartile", "midpoint", "thirdQuartile", "complete", "mute", "unmute", "close"))
                + f"</TrackingEvents><VideoClicks><ClickThrough><![CDATA[https://adfacten.com/]]></ClickThrough></VideoClicks>"
                f"<MediaFiles><MediaFile delivery=\"progressive\" type=\"video/mp4\" width=\"1280\" height=\"720\" bitrate=\"900\">"
                f"<![CDATA[{b}/creative/test5s.mp4]]></MediaFile></MediaFiles></Linear></Creative></Creatives></InLine></Ad></VAST>"))
        elif fmt == "native":
            ad.update(kind="native", native={"title": "Adfacten test ad", "body": "Native ad sample with a title, text, image and button.",
                                             "brand": "Adfacten", "cta": "Learn more",
                                             "image": {"url": f"{b}/creative/native_1200x628.png", "w": 1200, "h": 628},
                                             "icon": {"url": f"{b}/creative/icon_128x128.png"}})
        else:  # app_open
            ad.update(kind="image", w=320, h=480, close_after_s=0,
                      image={"url": f"{b}/creative/app_open_320x480.png", "url_2x": f"{b}/creative/app_open_640x960.png"})
        return ad

    # --- beacons, clicks, creatives -----------------------------------------------------------
    def do_HEAD(self):
        self.do_GET()

    def do_GET(self):
        u = urlparse(self.path)
        q = {k: v[0] for k, v in parse_qs(u.query).items()}
        if u.path == "/i":
            self.say(f"BEACON e={q.get('e')} imp={q.get('imp')} sid={q.get('sid', '-')} ts={q.get('ts', '-')}")
            return self.send(204)
        if u.path == "/a/click":
            self.say(f"CLICK imp={q.get('imp')}")
            return self.send(302, extra={"Location": "https://adfacten.com/"})
        if u.path == "/reward":
            self.say(f"REWARD callback {u.query}")
            return self.send(200, b"ok", "text/plain")
        if u.path.startswith("/creative/"):
            name = u.path.rsplit("/", 1)[-1]
            if name.endswith(".mp4"):
                return self.send_file(video_path(), "video/mp4")
            try:
                kind, size = name[:-4].rsplit("_", 1)
                w, h = (int(x) for x in size.split("x"))
            except ValueError:
                return self.send(404)
            key = "banner" if kind == "banner" else kind
            return self.send(200, png(min(w, 1600), min(h, 1600), COLORS.get(key, (120, 120, 120))), "image/png",
                             {"Cache-Control": "max-age=3600"})
        self.send(404)

    def send_file(self, path, ctype):
        if not path:
            return self.send(404)
        size = os.path.getsize(path)
        start, end = 0, size - 1
        rng = self.headers.get("Range")
        status = 200
        if rng and rng.startswith("bytes="):
            a, _, b = rng[6:].partition("-")
            start = int(a) if a else max(0, size - int(b))
            end = int(b) if (a and b) else size - 1
            end = min(end, size - 1)
            status = 206
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Length", str(end - start + 1))
        if status == 206:
            self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        self.end_headers()
        if self.command == "HEAD":
            return
        with open(path, "rb") as f:
            f.seek(start)
            self.wfile.write(f.read(end - start + 1))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8197)
    args = ap.parse_args()
    if not video_path():
        print("warning: ffmpeg not found; rewarded video will fail", file=sys.stderr)
    srv = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    print(f"Adfacten mock tracker on http://127.0.0.1:{args.port}", flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    main()
