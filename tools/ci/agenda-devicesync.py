#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Nourax
# SPDX-License-Identifier: GPL-3.0-or-later
"""Device calendar and contacts sync against the real server code (phase "device-sync"; CI only; the throwaway server on localhost).

The app's own sign-in (Login Flow v2, tools/ci/drive-stand-in.py replays it for the simulator) and the profile it hands to
iOS are proven here on a real Nextcloud 35, as the first-build checks of the desktop (plans/noagenda-ios-plan.md, 5.7):

  1  POST /index.php/login/v2 with the user agent "NoDrive Calendar & Contacts (iPhone)" answers the poll endpoint, the token and
     the login address (the body is the app's own: nothing else is sent)
  2  a browser (Playwright, the runner's Chrome) plays the person: it signs in as Ali and allows access
  3  the poll answers {server, loginName, appPassword}; the server names the person's account
  4  `occ user:auth-tokens:list ali` shows a token named "NoDrive Calendar & Contacts (iPhone)" (the name in the web security settings)
  5  the new password does a CalDAV PROPFIND of calendars/ali/ (207), a CardDAV PROPFIND of addressbooks/users/ali/ (207) and a
     PROPFIND of principals/users/ali/ (207, the address the profile names)
  6  DELETE ocs/v2.php/core/apppassword with that password revokes it (200); the same PROPFINDs are then 401 and the token is gone
  7  the server's own Apple profile (/remote.php/dav/provisioning/apple-provisioning.mobileconfig), fetched once with
     overwriteprotocol=https set for that step only: its key names are recorded. It has no CalDAVPassword and no CardDAVPassword,
     so iOS would ask for a password; that is why the app builds its own profile
The password and the poll token are never printed or written. Report: <out>/devicesync.md
"""
import argparse
import base64
import http.client
import json
import os
import plistlib
import re
import subprocess
import sys
import urllib.parse

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import agenda_common as c  # noqa: E402

DEVICE_UA = 'NoDrive Calendar & Contacts (iPhone)'
CONTAINER = os.environ.get('NODRIVE_AGENDA_CONTAINER', 'nodrive-ci-agenda')
ROWS = []
SECRETS = []


def row(name, ok, detail=''):
    ROWS.append((name, ok, detail))
    print(('ok   ' if ok else 'FAIL ') + name + (' - ' + detail if detail else ''))


def info(name, detail):
    ROWS.append((name, None, detail))
    print('info ' + name + ' - ' + detail)


def base():
    return 'http://localhost:%d' % c.port()


def req(method, path, body=None, headers=None, auth=None):
    conn = http.client.HTTPConnection('localhost', c.port(), timeout=60)
    hdrs = dict(headers or {})
    if auth:
        hdrs['Authorization'] = 'Basic ' + base64.b64encode(('%s:%s' % auth).encode()).decode()
    if isinstance(body, str):
        body = body.encode()
    conn.request(method, path, body=body, headers=hdrs)
    resp = conn.getresponse()
    data = resp.read()
    out = (resp.status, {k.lower(): v for k, v in resp.getheaders()}, data)
    conn.close()
    return out


def occ(*args):
    done = subprocess.run(['docker', 'exec', '-u', 'www-data', CONTAINER, 'php', 'occ'] + list(args), capture_output=True, text=True)
    return done.returncode, done.stdout


def token_names():
    code, out = occ('user:auth-tokens:list', 'ali', '--output=json')
    if code != 0:
        return None
    try:
        rows = json.loads(out)
    except ValueError:
        return None
    return [r.get('name', '') for r in rows if isinstance(r, dict)]


PROPFIND = ('<?xml version="1.0"?><d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/></d:prop></d:propfind>')


def propfind(path, auth):
    return req('PROPFIND', path, PROPFIND, {'Depth': '0', 'Content-Type': 'application/xml; charset=utf-8', 'User-Agent': DEVICE_UA}, auth)[0]


def grant_in_browser(url, login_password, out):
    """The person's part: sign in as Ali, allow access. Returns True when the server says the account is connected."""
    from playwright.sync_api import sync_playwright
    if not url.startswith(base() + '/'):
        row('2 the browser opens only the throwaway server', False, 'the login address is not on it')
        return False
    shots = os.path.join(out, 'devicesync-shots')
    os.makedirs(shots, exist_ok=True)
    done = False
    with sync_playwright() as p:
        try:
            browser = p.chromium.launch(channel='chrome')
        except Exception:  # noqa: BLE001
            browser = p.chromium.launch()
        context = browser.new_context(viewport={'width': 1200, 'height': 800}, locale='en-GB')
        page = context.new_page()
        page.set_default_timeout(30000)
        page.goto(url, wait_until='domcontentloaded')
        for step in range(1, 16):
            page.wait_for_timeout(1000)
            try:
                body = page.inner_text('body', timeout=5000)
            except Exception:  # noqa: BLE001
                body = ''
            page.screenshot(path=os.path.join(shots, 'step%02d.png' % step))
            low = body.lower()
            if 'account connected' in low or 'close this window' in low:
                done = True
                break
            try:
                user_field = page.locator('input[name="user"]')
                if user_field.count() and user_field.first.is_visible():
                    user_field.first.fill('ali')
                    page.fill('input[name="password"]', login_password)
                    page.locator('button[type="submit"]').first.click()
                    continue
                for role in ('button', 'link'):
                    for label in (r'^\s*grant access\s*$', r'^\s*log in\s*$'):
                        item = page.get_by_role(role, name=re.compile(label, re.I))
                        if item.count() and item.first.is_visible():
                            item.first.click()
                            raise StopIteration
            except StopIteration:
                continue
            except Exception as e:  # noqa: BLE001  (a page changed while we looked at it: look again)
                print('grant: step %d: %s' % (step, type(e).__name__))
        context.close()
        browser.close()
    return done


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--out', default='build/agenda-server')
    args = ap.parse_args()
    os.makedirs(args.out, exist_ok=True)
    login_password = os.environ.get('NODRIVE_AGENDA_LOGIN_PW_ALI', '')
    if not login_password:
        raise SystemExit('no login password for ali in the environment')

    before = token_names() or []

    # 1 start
    status, _, data = req('POST', '/index.php/login/v2', None, {'User-Agent': DEVICE_UA, 'Accept': 'application/json'})
    row('1 POST /index.php/login/v2 starts the sign-in', status == 200, 'status %s' % status)
    try:
        flow = json.loads(data.decode())
        poll_endpoint, poll_token, login_url = flow['poll']['endpoint'], flow['poll']['token'], flow['login']
        SECRETS.append(poll_token)
    except (ValueError, KeyError):
        row('1 the answer has poll.endpoint, poll.token and login', False, 'unreadable')
        return finish(args.out)
    row('1 the answer has poll.endpoint, poll.token and login', True)
    row('1 the login address and the poll endpoint are on the server that was asked',
        login_url.startswith(base() + '/') and poll_endpoint.startswith(base() + '/'), '')

    # 2 the person
    connected = False
    try:
        connected = grant_in_browser(login_url, login_password, args.out)
    except ImportError:
        info('2 the browser', 'Playwright is not installed')
    row('2 a browser signed in as Ali and allowed access (the server says "Account connected")', connected, '')

    # 3 poll
    grant = None
    if connected:
        form = urllib.parse.urlencode({'token': poll_token})
        status, _, data = req('POST', urllib.parse.urlsplit(poll_endpoint).path, form,
                               {'User-Agent': DEVICE_UA, 'Content-Type': 'application/x-www-form-urlencoded', 'Accept': 'application/json'})
        row('3 the poll answers 200 after the grant', status == 200, 'status %s' % status)
        try:
            grant = json.loads(data.decode())
        except ValueError:
            grant = None
    if grant:
        SECRETS.append(grant.get('appPassword', ''))
        row('3 the answer has server, loginName and appPassword', all(grant.get(k) for k in ('server', 'loginName', 'appPassword')), '')
        row('3 loginName is ali', grant.get('loginName') == 'ali', '')
        row('3 server is the server that was asked (same origin)', urllib.parse.urlsplit(grant.get('server', '')).netloc == 'localhost:%d' % c.port(), '')
    else:
        row('3 the poll gave a password', False, 'no grant')
        return finish(args.out)
    auth = ('ali', grant['appPassword'])

    # 4 token name
    names = token_names()
    row('4 occ user:auth-tokens:list shows "%s"' % DEVICE_UA, bool(names) and DEVICE_UA in names,
        'tokens now: %d, before: %d' % (len(names or []), len(before)))

    # 5 the DAV homes the profile names
    for name, path in (('CalDAV calendars/ali/', '/remote.php/dav/calendars/ali/'),
                       ('CardDAV addressbooks/users/ali/', '/remote.php/dav/addressbooks/users/ali/'),
                       ('principals/users/ali/ (CalDAVPrincipalURL, CardDAVPrincipalURL)', '/remote.php/dav/principals/users/ali/')):
        status = propfind(path, auth)
        row('5 the new password does a PROPFIND of ' + name + ' (207)', status == 207, 'status %s' % status)

    # 6 revoke
    status, _, _ = req('DELETE', '/ocs/v2.php/core/apppassword', None,
                        {'OCS-APIRequest': 'true', 'User-Agent': DEVICE_UA, 'Accept': 'application/json'}, auth)
    row('6 DELETE ocs/v2.php/core/apppassword with that password revokes it (200)', status == 200, 'status %s' % status)
    for name, path in (('CalDAV', '/remote.php/dav/calendars/ali/'), ('CardDAV', '/remote.php/dav/addressbooks/users/ali/')):
        status = propfind(path, auth)
        row('6 after the revocation the %s PROPFIND is 401' % name, status == 401, 'status %s' % status)
    names = token_names()
    row('6 the token is gone', names is not None and DEVICE_UA not in names, 'tokens now: %d' % len(names or []))

    # 7 the server's own Apple profile
    server_profile(args.out)
    return finish(args.out)


def server_profile(out):
    code, _ = occ('config:system:set', 'overwriteprotocol', '--value=https')
    try:
        status, headers, data = req('GET', '/remote.php/dav/provisioning/apple-provisioning.mobileconfig', None,
                                     {'OCS-APIRequest': 'true', 'User-Agent': 'NoDrive-CI'}, ('ali', c.token('ali')))
    finally:
        occ('config:system:delete', 'overwriteprotocol')
    info('7 the server\'s own Apple profile', 'status %s, content type %s, %d bytes' % (status, headers.get('content-type', '?'), len(data)))
    lines = []
    keys = set()
    try:
        root = plistlib.loads(data)
        for payload in root.get('PayloadContent', []):
            if isinstance(payload, dict):
                keys |= set(payload)
                lines.append('%s: %s' % (payload.get('PayloadType'), payload.get('PayloadDisplayName')))
                for k in payload:
                    if k.endswith('AccountDescription'):
                        lines.append('  %s = %s' % (k, payload[k]))
        info('7 the profile\'s payloads', '; '.join(lines) or 'none')
        row('7 the server\'s profile has no CalDAVPassword and no CardDAVPassword (so iOS would ask for one)',
            'CalDAVPassword' not in keys and 'CardDAVPassword' not in keys, 'keys: ' + ', '.join(sorted(keys)))
        names = ' '.join(lines)
        info('7 does the profile carry the NoDrive name?', 'it names: ' + names + (' (the server\'s own theming name, not the app\'s "NoDrive Calendar & Contacts")' if 'NoDrive' not in names else ''))
    except Exception:  # noqa: BLE001
        text = data.decode('utf-8', 'replace')[:160].replace('\n', ' ')
        info('7 the answer is not a profile', text)


def finish(out):
    text = ['# Device calendar and contacts sync against a throwaway Nextcloud 35 (phase device-sync)', '',
            'Names, status codes and counts only. The password and the poll token are never written.', '',
            '| Check | Result | Detail |', '|---|---|---|']
    for name, ok, detail in ROWS:
        text.append('| %s | %s | %s |' % (name, {True: 'PASS', False: 'FAIL', None: 'info'}[ok], detail.replace('|', '/')))
    report = '\n'.join(text) + '\n'
    leaked = [s for s in SECRETS if s and s in report]
    if leaked:
        raise SystemExit('a secret value is in the report')
    with open(os.path.join(out, 'devicesync.md'), 'w', encoding='utf-8') as f:
        f.write(report)
    summary = os.environ.get('GITHUB_STEP_SUMMARY')
    if summary:
        with open(summary, 'a', encoding='utf-8') as f:
            f.write(report)
    failed = [r for r in ROWS if r[1] is False]
    print('devicesync: %d checks, %d failed' % (len([r for r in ROWS if r[1] is not None]), len(failed)))
    return 1 if failed else 0


if __name__ == '__main__':
    sys.exit(main())
