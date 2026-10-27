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

Every request (method, path without its query, Host, User-Agent, TLS server name, whether an
Authorization header came, the names of the cookies) is written as one JSON line to --log, so CI can
prove that tapping "Log in" opened the browser at https://drive.nourax.org/login/v2/flow/... and which
user agent the app sent. Header values and cookie values are never logged.

With --workspace it also answers for a signed-in account (NODRIVE_WS_USER and NODRIVE_WS_APP_PASSWORD
in the environment, never on the command line), like the Nextcloud server 35 does in the parts the
Workspace apps menu uses (tools/ci/server_login_check.py proves those against the real server code):

  GET  /ocs/v2.php/cloud/user         Basic -> the user, and the session cookies (oc_sessionPassphrase,
                                      the session cookie sent twice, __Host- same-site cookies, a deletion).
                                      With ?nodrive=ws (the app's Workspace hand-off) the log event is
                                      "bootstrap"; without it (the app's account setup) "account-setup"
  GET  /ocs/v2.php/cloud/capabilities, PROPFIND /remote.php/dav/files/<user>/   a minimal account
  GET  /ocs/v2.php/core/navigation/apps   the app list, ETag and 304 (Basic or session cookies)
  GET  /apps/<app>/, /index.php/apps/<app>/   a page that says signed-in:<name> only with a valid session
                                      (the cookie pair of the bootstrap answer), else 302 to /login
  GET  /apps/mail/redirect-to-other-host   302 to the other host (a server redirect)
  GET  /apps/mail/expire              the first time a session uses it: the session ends and the answer is 302 /login
                                      (the app must sign in again by itself); later it shows session-renewed
  GET  /ocs/v2.php/apps/notifications/api/v2/notifications   one notification with a WEB action to /apps/mail/
  GET  /login (the text LOGIN), /logout (the text LOGOUT)
  host foreign.nodrive-ci.test: /probe, /redirected, /blank, /window-open, /nomail/   another host (links, a
                                      redirect, a new window, window.open, and the NoMail-style menu entry)

  sudo python3 tools/ci/drive-stand-in.py --cert leaf.pem --key leaf.key --log stand-in.jsonl [--workspace]
"""

import argparse
import base64
import hashlib
import hmac
import json
import os
import re
import secrets
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
FOREIGN_HOST = 'foreign.nodrive-ci.test'
PASSPHRASE = 'oc_sessionPassphrase'
SESSION_COOKIE = 'ocstandin01'
USER_ID = 'citest'

# The navigation list of a Nextcloud server 35 (core/ResponseDefinitions.php, CoreNavigationEntry), as
# GET /ocs/v2.php/core/navigation/apps?absolute=false returns it, with the entries the app must leave out.
# Left out by the app: files, activity and photos (NoDrive has its own), the external-site entry, a foreign
# entry over http, a foreign entry with user info (any other https entry would be kept, like NoMail). Kept as an "outside" entry: NoMail (https, another origin),
# exactly as the server app nourax_branding adds it.
NOMAIL_URL = f'https://{FOREIGN_HOST}/nomail/'
APPS = [
    ('dashboard', 'Dashboard', 'dashboard', True), ('files', 'Files', 'files', False),
    ('mail', 'Mail', 'mail', False), ('nourax_nomail', 'NoMail', 'nourax_branding', False),
    ('calendar', 'Calendar', 'calendar', False), ('photos', 'Photos', 'photos', False),
    ('spreed', 'Talk', 'spreed', False), ('activity', 'Activity', 'activity', False),
    ('contacts', 'Contacts', 'contacts', False),
    ('external_index1', 'Wiki', 'external', False),
    ('plainhttp', 'Plain http', 'plainhttp', False), ('userinfo', 'User info', 'userinfo', False),
]
NAV_ENTRIES = []
for _i, (_id, _name, _app, _default) in enumerate(APPS, start=1):
    _entry = {'id': _id, 'order': _i, 'href': f'/apps/{_id}/', 'icon': f'/apps/{_id}/img/app.svg', 'type': 'link',
              'name': _name, 'app': _app, 'active': False, 'classes': '', 'unread': 0}
    if _default:
        _entry['default'] = True
    if _id == 'nourax_nomail':
        _entry['href'] = NOMAIL_URL
        _entry['icon'] = '/apps/nourax_branding/img/nomail.svg'
    if _id == 'plainhttp':
        _entry['href'] = f'http://{FOREIGN_HOST}/plain/'
    if _id == 'userinfo':
        _entry['href'] = f'https://{HOST}@evil.example/apps/x/'
    NAV_ENTRIES.append(_entry)
NAV_BODY = json.dumps({'ocs': {'meta': {'status': 'ok', 'statuscode': 200, 'message': 'OK'}, 'data': NAV_ENTRIES}})
NAV_ETAG = '"' + hashlib.sha256(NAV_BODY.encode()).hexdigest()[:32] + '"'
APP_NAMES = {a[0]: a[1] for a in APPS}

# The other host's pages: path -> (log event, page title)
FOREIGN_PAGES = {
    '/probe': ('foreign-probe', 'Another host'),
    '/redirected': ('foreign-redirect', 'Redirect target'),
    '/blank': ('foreign-blank', 'New window target'),
    '/window-open': ('foreign-window-open', 'window.open target'),
    '/nomail/': ('foreign-nomail', 'NoMail stand-in'),
}

FAR = 'Fri, 31-Dec-2100 23:59:59 GMT'
PAGE_HTML = """<!doctype html>
<html lang="en"><head data-user="{user}" data-requesttoken="ci-stand-in"><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{name} - Nourax Workspace</title>
<style>
 body {{ font-family: -apple-system, system-ui, sans-serif; background: #F8FAFC; color: #0F172A; margin: 0; line-height: 1.45; }}
 header {{ background: #2563EB; color: #fff; padding: 18px 20px; }}
 header h1 {{ margin: 0; font-size: 22px; }}
 main {{ padding: 20px; }}
 .card {{ background: #fff; border: 1px solid #E2E8F0; border-radius: 12px; padding: 14px 16px; margin: 0 0 14px; }}
 a {{ color: #2563EB; }}
 @media (prefers-color-scheme: dark) {{
   body {{ background: #0B1220; color: #F8FAFC; }} .card {{ background: #0F172A; border-color: #1E293B; }}
   a {{ color: #60A5FA; }} }}
</style></head>
<body><header><h1>{name}</h1></header>
<main>
<div class="card"><p>signed-in:{name}</p></div>
<div class="card"><p>Nourax Workspace (CI stand-in for the real server)</p>
<p><a href="https://{foreign}/probe">Open the foreign test site</a></p>
<p><a href="/apps/mail/redirect-to-other-host">Redirect to the other host</a></p>
<p><a href="https://{foreign}/blank" target="_blank">New window to the other host</a></p>
<p><button type="button" onclick="window.open('https://{foreign}/window-open')">window.open to the other host</button></p>
<p><a href="/apps/mail/expire">Expire the session</a></p></div>
{extra}</main></body></html>
"""
SIMPLE_HTML = '<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>{t}</title></head><body><h1>{t}</h1></body></html>'
PROPFIND_BODY = """<?xml version="1.0"?>
<d:multistatus xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns" xmlns:nc="http://nextcloud.org/ns">
<d:response><d:href>/remote.php/dav/files/{user}/</d:href><d:propstat><d:prop>
<d:getlastmodified>Mon, 26 Oct 2026 09:00:00 GMT</d:getlastmodified><d:resourcetype><d:collection/></d:resourcetype>
<d:getetag>"ci0"</d:getetag><oc:fileid>00000001occi</oc:fileid><oc:id>00000001occi</oc:id><oc:permissions>RGDNVCK</oc:permissions>
<oc:size>0</oc:size><d:quota-used-bytes>0</d:quota-used-bytes><d:quota-available-bytes>-3</d:quota-available-bytes>
<oc:owner-id>{user}</oc:owner-id><oc:owner-display-name>Demo User</oc:owner-display-name>
</d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response></d:multistatus>
"""
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

    # --- what a request carries (names and facts only; values are never logged) -------------------------
    def _cookies(self):
        jar = {}
        for part in (self.headers.get('Cookie') or '').split(';'):
            name, _, value = part.strip().partition('=')
            if name:
                jar[name] = value
        return jar

    def _session_id(self):
        return self._cookies().get(SESSION_COOKIE)

    def _record(self, status, extra=None):
        parts = urlsplit(self.path)
        entry = {
            't': round(time.time(), 3),
            'method': self.command,
            'path': parts.path,
            'host': self.headers.get('Host', ''),
            'user_agent': self.headers.get('User-Agent', ''),
            'sni': getattr(self.connection, 'nodrive_sni', None),
            'status': status,
            'conn': self.client_address[1] if len(self.client_address) > 1 else None,
            'has_authorization': self.headers.get('Authorization') is not None,
            'cookie_names': sorted(self._cookies()),
        }
        sid = self._session_id()
        if sid:
            entry['session_hash'] = hashlib.sha256(sid.encode()).hexdigest()[:12]
        if extra:
            entry.update(extra)
        self.server.write_log(entry)

    def _send(self, status, body, ctype, headers=None, cookies=None):
        data = body.encode('utf-8')
        self.send_response(status)
        self.send_header('Content-Type', ctype)
        self.send_header('Content-Length', str(len(data)))
        self.send_header('Cache-Control', 'no-store')
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        for c in cookies or []:
            self.send_header('Set-Cookie', c)
        self.end_headers()
        if self.command != 'HEAD':
            self.wfile.write(data)

    def _json(self, status, obj, headers=None, cookies=None):
        self._send(status, json.dumps(obj), 'application/json; charset=utf-8', headers, cookies)

    # --- workspace mode: the account ---------------------------------------------------------------------
    def _basic_ok(self):
        ws = self.server.workspace
        header = self.headers.get('Authorization') or ''
        if not ws or not header.startswith('Basic '):
            return False
        try:
            user, _, password = base64.b64decode(header[6:]).decode('utf-8').partition(':')
        except Exception:   # noqa: BLE001
            return False
        return hmac.compare_digest(user, ws['user']) and hmac.compare_digest(password, ws['password'])

    def _session_ok(self):
        ws = self.server.workspace
        jar = self._cookies()
        sid, phrase = jar.get(SESSION_COOKIE), jar.get(PASSPHRASE)
        return bool(ws and sid and phrase and hmac.compare_digest(ws['sessions'].get(sid, ''), phrase))

    def _ocs(self, status, data):
        return {'ocs': {'meta': {'status': 'ok' if status == 200 else 'failure', 'statuscode': status,
                                 'message': 'OK' if status == 200 else 'Not found'}, 'data': data}}

    def _session_cookies(self, issued_by):
        """What PHP sends at the sign-in: the session cookie twice (start, then after the new session id),
        the passphrase, the same-site cookies, and a deletion cookie."""
        ws = self.server.workspace
        sid, old, phrase = secrets.token_hex(8), secrets.token_hex(8), secrets.token_hex(16)
        ws['sessions'][sid] = phrase
        if ws['renew_next']:
            # The session that replaces an expired one is not expired again by the expire link
            ws['renewed'].add(sid)
            ws['renew_next'] = False
        self.server.write_log({'t': round(time.time(), 3), 'event': 'session-issued', 'issued_by': issued_by,
                               'issued_hash': hashlib.sha256(sid.encode()).hexdigest()[:12]})
        flags = 'path=/; secure; HttpOnly; SameSite=Lax'
        return [
            f'{SESSION_COOKIE}={old}; {flags}',
            f'{PASSPHRASE}={phrase}; {flags}',
            f'{SESSION_COOKIE}={sid}; {flags}',
            'nc_username=deleted; expires=Thu, 01-Jan-1970 00:00:01 GMT; Max-Age=0; path=/; secure; HttpOnly',
            f'__Host-nc_sameSiteCookielax=true; path=/; httponly; secure; expires={FAR}; Max-Age=31536000; SameSite=lax',
            f'__Host-nc_sameSiteCookiestrict=true; path=/; httponly; secure; expires={FAR}; Max-Age=31536000; SameSite=strict',
        ]

    def _workspace_get(self, path):
        """True when the request was answered."""
        ws = self.server.workspace
        host = (self.headers.get('Host') or '').split(':')[0].lower()
        if host == FOREIGN_HOST:
            if path in FOREIGN_PAGES:
                event, title = FOREIGN_PAGES[path]
                self._record(200, {'event': event})
                self._send(200, SIMPLE_HTML.format(t=title), 'text/html; charset=utf-8')
            else:
                self._record(404)
                self._send(404, SIMPLE_HTML.format(t='Not found'), 'text/html; charset=utf-8')
            return True
        if path == '/ocs/v2.php/cloud/users/' + ws['user']:
            if not self._basic_ok():
                self._record(401)
                self._json(401, self._ocs(401, []))
                return True
            self._record(200)
            self._json(200, self._ocs(200, {'id': ws['user'], 'enabled': True, 'displayname': 'Demo User',
                                            'display-name': 'Demo User', 'email': '', 'language': 'en', 'locale': 'en_US',
                                            'groups': [], 'quota': {'free': 1 << 30, 'used': 0, 'total': 1 << 30,
                                                                    'relative': 0, 'quota': -3}}))
            return True
        if path == '/ocs/v2.php/cloud/user':
            if not self._basic_ok():
                self._record(401)
                self._json(401, self._ocs(401, []))
                return True
            # The app's Workspace hand-off carries ?nodrive=ws; its account setup asks the same path without it
            marked = 'nodrive=ws' in urlsplit(self.path).query.split('&')
            issued_by = 'bootstrap' if marked else 'account-setup'
            self._record(200, {'event': issued_by})
            self._json(200, self._ocs(200, {'id': ws['user'], 'enabled': True, 'display-name': 'Demo User', 'email': '',
                                            'language': 'en', 'locale': 'en_US', 'groups': [],
                                            'quota': {'free': 1 << 30, 'used': 0, 'total': 1 << 30, 'relative': 0, 'quota': -3}}),
                       cookies=self._session_cookies(issued_by))
            return True
        if path in ('/ocs/v1.php/cloud/capabilities', '/ocs/v2.php/cloud/capabilities'):
            if not self._basic_ok():
                self._record(401)
                self._json(401, self._ocs(401, []))
                return True
            self._record(200)
            self._json(200, self._ocs(200, {
                'version': {'major': 35, 'minor': 0, 'micro': 2, 'string': '35.0.2', 'edition': '', 'extendedSupport': False},
                'capabilities': {'core': {'pollinterval': 60, 'webdav-root': 'remote.php/webdav'},
                                 'files': {'bigfilechunking': True, 'undelete': True, 'versioning': True},
                                 'dav': {'chunking': '1.0'},
                                 'notifications': {'ocs-endpoints': ['list', 'get', 'delete', 'delete-all', 'icons',
                                                                     'rich-strings', 'action-web', 'user-status']},
                                 'theming': {'name': 'Nourax Workspace', 'url': 'https://drive.nourax.org', 'slogan': '',
                                             'color': '#2563EB', 'color-text': '#ffffff', 'color-element': '#2563EB',
                                             'color-element-bright': '#2563EB', 'color-element-dark': '#2563EB',
                                             'logo': '', 'background': '#2563EB', 'background-plain': True,
                                             'background-default': False, 'logoheader': '', 'favicon': ''}}}))
            return True
        if path == '/ocs/v2.php/core/navigation/apps':
            if not (self._basic_ok() or self._session_ok()):
                self._record(401)
                self._json(401, self._ocs(401, []))
                return True
            if self.server.nav_delay:
                # The list arrives late, so a test can open the sidebar before it is there
                time.sleep(self.server.nav_delay)
            if self.headers.get('If-None-Match') == NAV_ETAG:
                self._record(304, {'event': 'navigation-304'})
                self.send_response(304)
                self.send_header('ETag', NAV_ETAG)
                self.send_header('Content-Length', '0')
                self.end_headers()
                return True
            self._record(200, {'event': 'navigation'})
            self._send(200, NAV_BODY, 'application/json; charset=utf-8', {'ETag': NAV_ETAG})
            return True
        if path == '/ocs/v2.php/apps/notifications/api/v2/notifications':
            if not self._basic_ok():
                self._record(401)
                self._json(401, self._ocs(401, []))
                return True
            self._record(200, {'event': 'notifications'})
            link = f'https://{HOST}/apps/mail/'
            self._json(200, self._ocs(200, [{
                'notification_id': 1, 'app': 'mail', 'user': ws['user'], 'datetime': '2026-10-27T09:00:00+00:00',
                'object_type': 'message', 'object_id': '1', 'subject': 'New mail from CI', 'message': 'A message waits in Mail',
                'link': link, 'subjectRich': 'New mail from CI', 'messageRich': 'A message waits in Mail',
                'actions': [{'label': 'Open mail', 'link': link, 'type': 'WEB', 'primary': True}]}]))
            return True
        if path.startswith('/ocs/'):
            self._record(404)
            self._json(404, self._ocs(404, []))
            return True
        m = re.match(r'^(?:/index\.php)?/apps/([a-z_0-9]+)(?:/.*)?$', path)
        if m:
            if self._session_ok() and m.group(1) in APP_NAMES:
                name = APP_NAMES[m.group(1)]
                sub = path.rsplit('/', 1)[-1]
                if m.group(1) == 'mail' and sub == 'redirect-to-other-host':
                    self._record(302, {'event': 'redirect-to-other-host'})
                    self._send(302, '', 'text/html; charset=utf-8', {'Location': f'https://{FOREIGN_HOST}/redirected'})
                    return True
                extra = ''
                if m.group(1) == 'mail' and sub == 'expire':
                    sid = self._session_id()
                    if sid not in ws['renewed']:
                        # The session ends here: the next request of the web view would be sent to /login
                        ws['sessions'].pop(sid, None)
                        ws['renew_next'] = True
                        self._record(302, {'event': 'session-expired'})
                        self._send(302, '', 'text/html; charset=utf-8', {'Location': '/login'})
                        return True
                    extra = '<div class="card"><p>session-renewed</p></div>'
                self._record(200, {'event': 'page', 'app': m.group(1), 'sub': sub})
                self._send(200, PAGE_HTML.format(user=ws['user'], name=name, foreign=FOREIGN_HOST, extra=extra),
                           'text/html; charset=utf-8')
            else:
                self._record(302, {'event': 'page-redirect-to-login'})
                self._send(302, '', 'text/html; charset=utf-8', {'Location': '/login'})
            return True
        if path in ('/login', '/index.php/login'):
            self._record(200, {'event': 'login-page'})
            self._send(200, SIMPLE_HTML.format(t='LOGIN'), 'text/html; charset=utf-8')
            return True
        if path in ('/logout', '/index.php/logout'):
            self._record(200, {'event': 'logout-page'})
            self._send(200, SIMPLE_HTML.format(t='LOGOUT'), 'text/html; charset=utf-8')
            return True
        return False

    def do_GET(self):
        path = urlsplit(self.path).path
        if path in ('/status.php', '/index.php/status.php'):
            self._record(200)
            self._json(200, STATUS)
        elif path.startswith('/login/v2/flow/') or path.startswith('/index.php/login/v2/flow/'):
            self._record(200, {'event': 'browser-opened-login-page'})
            self._send(200, FLOW_PAGE, 'text/html; charset=utf-8')
        elif self.server.workspace and self._workspace_get(path):
            return
        else:
            self._record(404)
            self._json(404, {'message': 'not served by the CI stand-in'})

    do_HEAD = do_GET

    def do_PROPFIND(self):
        length = int(self.headers.get('Content-Length') or 0)
        if length:
            self.rfile.read(min(length, 1 << 16))
        ws = self.server.workspace
        path = urlsplit(self.path).path
        if ws and path.startswith('/remote.php/') and self._basic_ok():
            self._record(207)
            self._send(207, PROPFIND_BODY.format(user=ws['user']), 'application/xml; charset=utf-8')
        else:
            self._record(404)
            self._json(404, {'message': 'not served by the CI stand-in'})

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

    def __init__(self, addr, handler, context, log_path, workspace=None, nav_delay=0.0):
        self.context = context
        self.log_path = log_path
        self.nav_delay = nav_delay
        self.workspace = workspace   # None, or {'user', 'password', 'sessions', 'renewed', 'renew_next'}
        super().__init__(addr, handler)

    def server_bind(self):
        self.socket.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
        super().server_bind()

    def write_log(self, entry):
        line = json.dumps(entry, ensure_ascii=False)
        with _log_lock, open(self.log_path, 'a', encoding='utf-8') as f:
            f.write(line + '\n')

    def finish_request(self, request, client_address):
        # Connection timing: accepted -> TLS done -> requests (same "conn" = client port). A long gap
        # before "accepted" is on the client side; a long handshake is the client's certificate check.
        conn = client_address[1] if len(client_address) > 1 else None
        accepted = time.time()
        self.write_log({'t': round(accepted, 3), 'event': 'connection-accepted', 'conn': conn})
        try:
            request = self.context.wrap_socket(request, server_side=True)
            self.write_log({'t': round(time.time(), 3), 'event': 'tls-ok', 'conn': conn,
                            'handshake_s': round(time.time() - accepted, 3)})
        except (ssl.SSLError, OSError) as e:
            self.write_log({'t': round(time.time(), 3), 'event': 'tls-handshake-failed', 'conn': conn,
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
    ap.add_argument('--nav-delay', type=float, default=0.0,
                    help='seconds to wait before the apps list is sent (the sidebar can then open before it arrives)')
    ap.add_argument('--workspace', action='store_true',
                    help='also answer for a signed-in account (NODRIVE_WS_USER, NODRIVE_WS_APP_PASSWORD in the environment)')
    args = ap.parse_args()
    workspace = None
    if args.workspace:
        user, password = os.environ.get('NODRIVE_WS_USER', ''), os.environ.get('NODRIVE_WS_APP_PASSWORD', '')
        if not user or not password:
            sys.exit('drive-stand-in: --workspace needs NODRIVE_WS_USER and NODRIVE_WS_APP_PASSWORD in the environment')
        workspace = {'user': user, 'password': password, 'sessions': {}, 'renewed': set(), 'renew_next': False}

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

    server = DualStackTLSServer(('::', args.port), Handler, ctx, args.log, workspace, args.nav_delay)
    server.write_log({'t': round(time.time(), 3), 'event': 'listening', 'port': args.port, 'workspace': bool(workspace)})
    print(f'drive-stand-in: listening on [::]:{args.port} (IPv4 and IPv6), log {args.log}', flush=True)
    server.serve_forever()


if __name__ == '__main__':
    main()
