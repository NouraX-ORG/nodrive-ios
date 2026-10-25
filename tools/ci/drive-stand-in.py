#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Nourax
# SPDX-License-Identifier: GPL-3.0-or-later
"""Local stand-in for https://drive.nourax.org, used only by the CI screenshot job.

CI must not contact the real Drive server (and its login pages only open from the
owner's home IP). So the job points drive.nourax.org at 127.0.0.1 / ::1 in /etc/hosts,
trusts a throw-away CI root certificate in the simulator, and runs this server. The
app's own sign-in code then runs unchanged:

  GET  /status.php                  -> a server status like Nextcloud server 35 sends
  POST /index.php/login/v2          -> Login Flow v2 start (token, poll endpoint, login URL)
  GET  /login/v2/flow/<token>       -> a plain page that the browser shows
  POST /login/v2/poll, /index.php/login/v2/poll -> 404 (sign-in still pending)

Every request (method, path, Host, User-Agent, TLS server name) is written as one
JSON line to --log, so CI can prove that tapping "Log in" opened the browser at
https://drive.nourax.org/login/v2/flow/... and which user agent the app sent.

  sudo python3 tools/ci/drive-stand-in.py --cert leaf.pem --key leaf.key --log stand-in.jsonl
"""

import argparse
import json
import socket
import ssl
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit

HOST = 'drive.nourax.org'
FLOW_TOKEN = 'nodrive-ci-flow-token'
POLL_TOKEN = 'nodrive-ci-poll-token'

STATUS = {
    'installed': True, 'maintenance': False, 'needsDbUpgrade': False,
    'version': '35.0.2.1', 'versionstring': '35.0.2', 'edition': '',
    'productname': 'Nourax Workspace', 'extendedSupport': False,
}
LOGIN_V2 = {
    'poll': {'token': POLL_TOKEN, 'endpoint': f'https://{HOST}/login/v2/poll'},
    'login': f'https://{HOST}/login/v2/flow/{FLOW_TOKEN}',
}
FLOW_PAGE = """<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>drive.nourax.org - CI stand-in</title>
<style>
 body { font-family: -apple-system, system-ui, sans-serif; background: #F8FAFC; color: #0F172A;
        margin: 0; padding: 40px 24px; line-height: 1.45; }
 h1 { color: #2563EB; font-size: 26px; margin: 0 0 16px; }
 code { word-break: break-all; background: #E2E8F0; padding: 1px 4px; border-radius: 4px; }
 @media (prefers-color-scheme: dark) {
   body { background: #0B1220; color: #F8FAFC; } h1 { color: #3B82F6; } code { background: #0F172A; } }
</style></head>
<body>
<h1>NoDrive sign-in (CI stand-in)</h1>
<p>NoDrive opened this page in the browser at<br><code>https://drive.nourax.org/login/v2/flow/...</code></p>
<p>In CI a local stand-in answers for drive.nourax.org, so the real Nourax server is never
contacted. The real &ldquo;Log in with Nourax&rdquo; page is checked by the owner.</p>
</body></html>
"""

_log_lock = threading.Lock()


class Handler(BaseHTTPRequestHandler):
    server_version = 'NoDriveCIStandIn/1'
    protocol_version = 'HTTP/1.1'

    def log_message(self, fmt, *args):   # keep stderr quiet; we log JSON lines
        pass

    def _record(self, status, extra=None):
        entry = {
            't': round(time.time(), 3),
            'method': self.command,
            'path': self.path,
            'host': self.headers.get('Host', ''),
            'user_agent': self.headers.get('User-Agent', ''),
            'sni': getattr(self.connection, 'nodrive_sni', None),
            'status': status,
        }
        if extra:
            entry.update(extra)
        self.server.write_log(entry)

    def _send(self, status, body, ctype):
        data = body.encode('utf-8')
        self.send_response(status)
        self.send_header('Content-Type', ctype)
        self.send_header('Content-Length', str(len(data)))
        self.send_header('Cache-Control', 'no-store')
        self.end_headers()
        if self.command != 'HEAD':
            self.wfile.write(data)

    def _json(self, status, obj):
        self._send(status, json.dumps(obj), 'application/json; charset=utf-8')

    def do_GET(self):
        path = urlsplit(self.path).path
        if path in ('/status.php', '/index.php/status.php'):
            self._record(200)
            self._json(200, STATUS)
        elif path.startswith('/login/v2/flow/') or path.startswith('/index.php/login/v2/flow/'):
            self._record(200, {'event': 'browser-opened-login-page'})
            self._send(200, FLOW_PAGE, 'text/html; charset=utf-8')
        else:
            self._record(404)
            self._json(404, {'message': 'not served by the CI stand-in'})

    do_HEAD = do_GET

    def do_POST(self):
        length = int(self.headers.get('Content-Length') or 0)
        if length:
            self.rfile.read(min(length, 1 << 16))
        path = urlsplit(self.path).path
        if path in ('/index.php/login/v2', '/login/v2'):
            self._record(200, {'event': 'login-flow-v2-start'})
            self._json(200, LOGIN_V2)
        elif path in ('/login/v2/poll', '/index.php/login/v2/poll'):
            self._record(404, {'event': 'login-flow-v2-poll'})
            self._json(404, [])
        else:
            self._record(404)
            self._json(404, {'message': 'not served by the CI stand-in'})


class DualStackTLSServer(ThreadingHTTPServer):
    """Listens on [::]:port with IPV6_V6ONLY off, so 127.0.0.1 and ::1 both reach it.
    The TLS handshake runs in the request thread; failures are logged (e.g. when the
    simulator does not trust the CI root)."""
    address_family = socket.AF_INET6
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, addr, handler, context, log_path):
        self.context = context
        self.log_path = log_path
        super().__init__(addr, handler)

    def server_bind(self):
        self.socket.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
        super().server_bind()

    def write_log(self, entry):
        line = json.dumps(entry, ensure_ascii=False)
        with _log_lock, open(self.log_path, 'a', encoding='utf-8') as f:
            f.write(line + '\n')

    def finish_request(self, request, client_address):
        try:
            request = self.context.wrap_socket(request, server_side=True)
        except (ssl.SSLError, OSError) as e:
            self.write_log({'t': round(time.time(), 3), 'event': 'tls-handshake-failed',
                            'client': str(client_address[0]), 'error': str(e)})
            try:
                request.close()
            except OSError:
                pass
            return
        try:
            super().finish_request(request, client_address)
        finally:
            try:
                request.close()
            except OSError:
                pass

    def handle_error(self, request, client_address):
        self.write_log({'t': round(time.time(), 3), 'event': 'handler-error',
                        'error': repr(sys.exc_info()[1])})


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--cert', required=True, help='PEM certificate chain for drive.nourax.org')
    ap.add_argument('--key', required=True, help='PEM private key')
    ap.add_argument('--log', required=True, help='JSON-lines request log (appended)')
    ap.add_argument('--port', type=int, default=443)
    args = ap.parse_args()

    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.minimum_version = ssl.TLSVersion.TLSv1_2
    ctx.load_cert_chain(args.cert, args.key)
    ctx.set_alpn_protocols(['http/1.1'])

    def sni(sslsock, server_name, _ctx):
        try:
            sslsock.nodrive_sni = server_name
        except AttributeError:
            pass
    ctx.sni_callback = sni

    server = DualStackTLSServer(('::', args.port), Handler, ctx, args.log)
    server.write_log({'t': round(time.time(), 3), 'event': 'listening', 'port': args.port})
    print(f'drive-stand-in: listening on [::]:{args.port} (IPv4 and IPv6), log {args.log}', flush=True)
    server.serve_forever()


if __name__ == '__main__':
    main()
