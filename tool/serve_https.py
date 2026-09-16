#!/usr/bin/env python3
"""Serves the built web app over HTTPS on the LAN, so a phone can reach it.

A browser only grants camera access on a secure origin. `localhost` qualifies;
`http://192.168.x.x` does not, and both iOS Safari and Android Chrome will
silently refuse getUserMedia over plain HTTP. Hence a certificate.

This is a local development convenience and nothing more. The certificate is
self-signed, so the phone will warn once and has to be told to proceed.

    python3 tool/serve_https.py

Then open https://<lan-ip>:8443 on the phone, on the same network.
"""

import http.server
import os
import socket
import ssl
import sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "app", "build", "web")
CERT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "certs", "cert.pem")
KEY = os.path.join(os.path.dirname(os.path.abspath(__file__)), "certs", "key.pem")
PORT = 8443


class Handler(http.server.SimpleHTTPRequestHandler):
    # Flutter web needs these served with the right type or the app will not boot.
    extensions_map = {
        **http.server.SimpleHTTPRequestHandler.extensions_map,
        ".js": "application/javascript",
        ".mjs": "application/javascript",
        ".wasm": "application/wasm",
        ".json": "application/json",
        ".otf": "font/otf",
        ".ttf": "font/ttf",
        "": "application/octet-stream",
    }

    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=ROOT, **kwargs)

    def end_headers(self):
        # The pose model and wasm come from a CDN; these keep the browser from
        # caching a stale build between runs.
        self.send_header("Cache-Control", "no-store")
        super().end_headers()

    def log_message(self, fmt, *args):
        sys.stderr.write("%s\n" % (fmt % args))


def lan_ip() -> str:
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        sock.connect(("8.8.8.8", 80))
        return sock.getsockname()[0]
    except OSError:
        return "127.0.0.1"
    finally:
        sock.close()


def main() -> int:
    if not os.path.isdir(ROOT):
        print(f"No build at {ROOT}. Run: cd app && flutter build web --release")
        return 1
    if not (os.path.isfile(CERT) and os.path.isfile(KEY)):
        print(f"No certificate at {CERT}. See tool/README.md")
        return 1

    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(CERT, KEY)

    server = http.server.ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    server.socket = context.wrap_socket(server.socket, server_side=True)

    print(f"\n  Plank Up  →  https://{lan_ip()}:{PORT}\n")
    print("  Same wifi. The certificate is self-signed, so the phone will warn")
    print("  once — proceed past it, then allow the camera.\n")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nstopped")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
