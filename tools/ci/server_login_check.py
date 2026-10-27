#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Nourax
# SPDX-License-Identifier: GPL-3.0-or-later
"""Proof, on a real Nextcloud 35.0.2 server, of the app's sign-in for the in-app web view.

Run by CI (job server-login) through tools/ci/server-app-login.sh against a throwaway server in Docker on
the runner. It never contacts drive.nourax.org. Credentials come from the environment
(NODRIVE_WS_USER, NODRIVE_WS_PW_TOKEN, NODRIVE_WS_SSO_TOKEN, NODRIVE_WS_LOGIN_PASSWORD) and are never printed.

For each app password (P: created with a login password; S: without one, like a "Log in with Nourax" user):
  3  the app's one request (GET cloud/user with Basic, no redirects) answers 200, the right user id and the
     session cookies (oc_sessionPassphrase, oc<id>, nc_sameSiteCookielax, nc_sameSiteCookiestrict)
  4  a page request with only those cookies is signed in; without oc_sessionPassphrase it is not
  5  the navigation list works with the cookies, gives an ETag and answers 304 to If-None-Match
  6  controls: no credentials -> login redirect; wrong app password -> 401 and nothing is signed in
  7  (information) the same page with the Basic header directly
  8  a web "Log out" keeps the app signed in; a revoked app password ends the web session at once
  9  the web view user agents are not sent to /unsupported (Playwright, Chrome)
Writes a Markdown report (names and status codes only) to <out>/report.md and the step summary.
"""
import argparse
import base64
import http.client
import json
import os
import re
import subprocess
import sys
import time
import urllib.parse

API_UA = 'Mozilla/5.0 (iOS) Nextcloud-iOS/35.2.1 NoDrive'
# The user agents of the in-app web view: primary, and the fallback if the primary is sent to /unsupported.
WEB_UA_PRIMARY = ('Mozilla/5.0 (iPhone; CPU iPhone OS 18_6 like Mac OS X) AppleWebKit/605.1.15 '
                  '(KHTML, like Gecko) Mobile/15E148 NoDrive')
WEB_UA_FALLBACK = ('Mozilla/5.0 (iPhone; CPU iPhone OS 18_6 like Mac OS X) AppleWebKit/605.1.15 '
                   '(KHTML, like Gecko) Version/18.6 Mobile/15E148 Safari/604.1 NoDrive')
PASSPHRASE = 'oc_sessionPassphrase'
SESSION_RE = re.compile(r'^oc[a-z0-9]{10}$')

lines = []
failures = []


def say(text=''):
    print(text, flush=True)
    lines.append(text)


def check(ok, what, detail=''):
    mark = 'PASS' if ok else 'FAIL'
    say(f'- {mark}  {what}' + (f'  ({detail})' if detail else ''))
    if not ok:
        failures.append(what)
    return ok


def info(what, detail=''):
    say(f'- info  {what}' + (f'  ({detail})' if detail else ''))


class Server:
    def __init__(self, port, user):
        self.port, self.user = port, user

    def request(self, method, path, cookies=None, basic=None, headers=None, ua=API_UA):
        conn = http.client.HTTPConnection('localhost', self.port, timeout=90)
        h = {'User-Agent': ua, 'Accept': 'application/json', 'OCS-APIRequest': 'true'}
        if basic is not None:
            h['Authorization'] = 'Basic ' + base64.b64encode(f'{self.user}:{basic}'.encode()).decode()
        if cookies:
            h['Cookie'] = '; '.join(f'{k}={v}' for k, v in cookies.items())
        h.update(headers or {})
        conn.request(method, path, headers=h)
        resp = conn.getresponse()
        body = resp.read()
        set_cookies = resp.msg.get_all('Set-Cookie') or []
        out = (resp.status, {k.lower(): v for k, v in resp.getheaders()}, body, set_cookies)
        conn.close()
        return out


def jar_from(set_cookies):
    """name -> value of the cookies that stay (a deletion cookie removes the name); names only are printed."""
    jar = {}
    counts = {}
    for sc in set_cookies:
        first, *attrs = [p.strip() for p in sc.split(';')]
        name, _, value = first.partition('=')
        counts[name] = counts.get(name, 0) + 1
        attr = {a.split('=')[0].lower(): a.partition('=')[2] for a in attrs}
        if value in ('', 'deleted') or attr.get('max-age', '1').lstrip('-').isdigit() and int(attr.get('max-age', '1')) <= 0:
            jar.pop(name, None)
        else:
            jar[name] = value
    return jar, counts


def signed_in(srv, jar):
    status, hdrs, body, _ = srv.request('GET', '/index.php/apps/dashboard/', cookies=jar, headers={'Accept': 'text/html'},
                                        ua=WEB_UA_PRIMARY)
    text = body.decode('utf-8', 'replace')
    return status == 200 and f'data-user="{srv.user}"' in text, status, hdrs.get('location', ''), text


def occ(container, *args, env=None):
    cmd = ['docker', 'exec', '-u', 'www-data']
    for k, v in (env or {}).items():
        cmd += ['-e', f'{k}={v}']
    cmd += [container, 'php', 'occ', *args]
    return subprocess.run(cmd, capture_output=True, text=True, timeout=120)


def run_token(srv, kind, token, out, container, login_password):
    say(f'\n## App password {kind}')
    user = srv.user
    # 3. the app's one request
    status, hdrs, body, set_cookies = srv.request('GET', '/ocs/v2.php/cloud/user?format=json&nodrive=ws', basic=token)
    jar, counts = jar_from(set_cookies)
    check(status == 200, f'{kind}/3 bootstrap request answers 200', f'status {status}')
    try:
        uid = json.loads(body)['ocs']['data']['id']
    except Exception:
        uid = None
    check(uid == user, f'{kind}/3 the answer names the account user', f'id matches: {uid == user}')
    names = sorted(counts)
    info(f'{kind}/3 Set-Cookie names and counts', ', '.join(f'{n} x{c}' for n, c in sorted(counts.items())))
    check(PASSPHRASE in jar, f'{kind}/3 cookie {PASSPHRASE}')
    check(any(SESSION_RE.match(n) for n in jar), f'{kind}/3 session cookie oc<10 chars>')
    check('nc_sameSiteCookielax' in jar and 'nc_sameSiteCookiestrict' in jar, f'{kind}/3 same-site cookies')
    check(not any(n.lower().startswith('authorization') for n in names), f'{kind}/3 no credential in cookie names')

    # 4. page with cookies only
    ok, st, loc, text = signed_in(srv, jar)
    check(ok, f'{kind}/4 dashboard with the cookies only is signed in', f'status {st}')
    m = re.search(r'data-requesttoken="([^"]+)"', text)
    request_token = m.group(1) if m else ''
    # The negative control uses a session of its own: a request without the passphrase makes the server drop that session.
    _, _, _, sc_b = srv.request('GET', '/ocs/v2.php/cloud/user?format=json&nodrive=ws', basic=token)
    jar_b, _ = jar_from(sc_b)
    partial = {k: v for k, v in jar_b.items() if k != PASSPHRASE}
    ok2, st2, loc2, _ = signed_in(srv, partial)
    check(not ok2 and st2 in (302, 303) and 'login' in loc2,
          f'{kind}/4 without {PASSPHRASE} the page is not signed in', f'status {st2}, redirect to login: {"login" in loc2}')

    # 5. navigation list
    status, hdrs, body, _ = srv.request('GET', '/ocs/v2.php/core/navigation/apps?absolute=false&format=json', cookies=jar,
                                        ua=WEB_UA_PRIMARY)
    check(status == 200, f'{kind}/5 navigation list with cookies only', f'status {status}')
    etag = hdrs.get('etag', '')
    entries = []
    try:
        entries = json.loads(body)['ocs']['data']
    except Exception:
        pass
    check(isinstance(entries, list) and len(entries) > 0, f'{kind}/5 the list has entries', f'{len(entries)} entries')
    with open(os.path.join(out, f'navigation-apps-{kind}.json'), 'w', encoding='utf-8') as f:
        json.dump(json.loads(body) if body else {}, f, indent=2)
    fields = sorted({k for e in entries for k in e})
    info(f'{kind}/5 entry fields', ', '.join(fields))
    info(f'{kind}/5 entry ids', ', '.join(str(e.get('id')) for e in entries))
    check(any(e.get('id') == 'files' for e in entries), f'{kind}/5 files is in the list (the app leaves it out)')
    check(all(str(e.get('href', '')).startswith('/') for e in entries), f'{kind}/5 absolute=false gives paths')
    if etag:
        status304, _, _, _ = srv.request('GET', '/ocs/v2.php/core/navigation/apps?absolute=false&format=json',
                                         cookies=jar, headers={'If-None-Match': etag}, ua=WEB_UA_PRIMARY)
        check(status304 == 304, f'{kind}/5 If-None-Match answers 304', f'status {status304}')
    else:
        check(False, f'{kind}/5 ETag header present')
    _, _, abody, _ = srv.request('GET', '/ocs/v2.php/core/navigation/apps?absolute=true&format=json', cookies=jar,
                                 ua=WEB_UA_PRIMARY)
    try:
        absolute = json.loads(abody)['ocs']['data']
        rel = {e['id']: e['href'] for e in entries}
        same = all(a['href'].endswith(rel.get(a['id'], '\0')) for a in absolute)
        check(same, f'{kind}/5 absolute=true hrefs end with the absolute=false paths')
    except Exception as e:  # noqa: BLE001
        check(False, f'{kind}/5 absolute=true list readable', type(e).__name__)

    # 6. controls
    st, hdrs, _, _ = srv.request('GET', '/index.php/apps/dashboard/', headers={'Accept': 'text/html'})
    check(st in (302, 303) and 'login' in hdrs.get('location', ''), f'{kind}/6 no credentials -> login redirect', f'status {st}')
    st, _, _, wrong_cookies = srv.request('GET', '/ocs/v2.php/cloud/user?format=json&nodrive=ws', basic=token[::-1])
    wjar, _ = jar_from(wrong_cookies)
    wok, _, _, _ = signed_in(srv, wjar)
    check(st == 401 and not wok, f'{kind}/6 wrong app password -> 401, nothing signed in', f'status {st}')

    # 7. information only: the Basic header on a page directly (method A, not used by the app)
    st, _, body, _ = srv.request('GET', '/index.php/apps/dashboard/', basic=token, headers={'Accept': 'text/html'})
    info(f'{kind}/7 Basic header directly on a page (not used)', f'status {st}')

    # 8. web logout keeps the app signed in
    if request_token:
        srv.request('GET', '/index.php/logout?requesttoken=' + urllib.parse.quote(request_token), cookies=jar, ua=WEB_UA_PRIMARY)
    ok3, st3, _, _ = signed_in(srv, jar)
    check(not ok3, f'{kind}/8 after a web log-out the cookies are signed out', f'status {st3}')
    status, _, _, set_cookies = srv.request('GET', '/ocs/v2.php/cloud/user?format=json&nodrive=ws', basic=token)
    jar2, _ = jar_from(set_cookies)
    again, _, _, _ = signed_in(srv, jar2)
    check(status == 200 and again, f'{kind}/8 the app password still works after the web log-out', f'status {status}')

    # revoke: a fresh app password, a session from it, then delete it on the server
    if container and login_password:
        r = occ(container, 'user:auth-tokens:add', '--password-from-env', '--name', f'revoke-{kind}', user,
                env={'NC_PASS': login_password})
        tok = (r.stdout.strip().splitlines() or [''])[-1].strip()
        if len(tok) >= 32:
            st, _, _, sc = srv.request('GET', '/ocs/v2.php/cloud/user?format=json&nodrive=ws', basic=tok)
            rjar, _ = jar_from(sc)
            before, _, _, _ = signed_in(srv, rjar)
            lst = occ(container, 'user:auth-tokens:list', '--output=json', user)
            token_id = None
            try:
                for row in json.loads(lst.stdout):
                    if row.get('name') == f'revoke-{kind}':
                        token_id = row.get('id')
            except Exception:
                pass
            if token_id is not None:
                occ(container, 'user:auth-tokens:delete', user, str(token_id))
                # The server looks the token up through a short cache: the session ends within seconds.
                started, after, waited = time.time(), True, 0.0
                while after and time.time() - started < 90:
                    after, _, _, _ = signed_in(srv, rjar)
                    waited = time.time() - started
                    if after:
                        time.sleep(3)
                check(before and not after, f'{kind}/8 revoking the app password ends the web session within 90 s',
                      f'signed in before: {before}; ended after {waited:.0f} s: {not after}')
            else:
                check(False, f'{kind}/8 revoke test: token id found', lst.stdout[:80].replace(tok, '***'))
        else:
            check(False, f'{kind}/8 revoke test: app password created')


def ua_check(port, user, token, out):
    say('\n## 9. Web view user agents (Playwright with Chrome; /unsupported check)')
    srv = Server(port, user)
    _, _, _, sc = srv.request('GET', '/ocs/v2.php/cloud/user?format=json&nodrive=ws', basic=token)
    jar, _ = jar_from(sc)
    try:
        from playwright.sync_api import sync_playwright
    except ImportError:
        check(False, '9 playwright is installed')
        return
    results = {}
    with sync_playwright() as p:
        # The runner's own Chrome: no browser download and no system packages (those took 22 minutes of apt once).
        # The check is about a JavaScript test of navigator.userAgent, so the engine does not matter.
        try:
            browser = p.chromium.launch(channel='chrome')
        except Exception:  # noqa: BLE001
            browser = p.chromium.launch()
        for label, ua in (('primary', WEB_UA_PRIMARY), ('fallback', WEB_UA_FALLBACK),
                          ('api-ua (expected: rejected)', API_UA)):
            ctx = browser.new_context(user_agent=ua)
            ctx.add_cookies([{'name': k, 'value': v, 'url': f'http://localhost:{port}'} for k, v in jar.items()])
            page = ctx.new_page()
            try:
                page.goto(f'http://localhost:{port}/index.php/apps/dashboard/', wait_until='networkidle', timeout=90000)
                page.wait_for_timeout(4000)
                path = urllib.parse.urlsplit(page.url).path
                who = page.evaluate('() => document.head && document.head.dataset ? document.head.dataset.user || "" : ""')
                ok = '/unsupported' not in path and '/login' not in path and who == user
                results[label] = ok
                info(f'9 {label}', f'final path {path}, signed in as expected user: {who == user}')
                if label == 'primary':
                    page.screenshot(path=os.path.join(out, 'webview-ua-primary.png'))
            except Exception as e:  # noqa: BLE001
                results[label] = False
                info(f'9 {label}', f'error {type(e).__name__}')
            ctx.close()
        browser.close()
    check(results.get('primary', False), '9 the primary web view user agent is accepted (not /unsupported)')
    info('9 fallback user agent accepted', str(results.get('fallback', False)))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--container', default='nodrive-ci-server')
    ap.add_argument('--out', default='build/server-login')
    ap.add_argument('--no-ua', action='store_true')
    args = ap.parse_args()
    os.makedirs(args.out, exist_ok=True)
    port = int(os.environ['NODRIVE_WS_PORT'])
    user = os.environ['NODRIVE_WS_USER']
    srv = Server(port, user)
    say('# Server login check (Nextcloud server 35.0.2 in Docker, throwaway)')
    status, _, body, _ = srv.request('GET', '/status.php')
    ver = json.loads(body).get('versionstring') if status == 200 else None
    check(ver == '35.0.2', 'server version 35.0.2', str(ver))
    # a brute-force throttle can follow the controls below; keep the pace calm
    for kind, key in (('P', 'NODRIVE_WS_PW_TOKEN'), ('S', 'NODRIVE_WS_SSO_TOKEN')):
        run_token(srv, kind, os.environ[key], args.out, args.container, os.environ.get('NODRIVE_WS_LOGIN_PASSWORD', ''))
        time.sleep(2)
    if not args.no_ua:
        ua_check(port, user, os.environ['NODRIVE_WS_PW_TOKEN'], args.out)
    say(f'\nResult: {"FAILED: " + "; ".join(failures) if failures else "all checks passed"}')
    report = '\n'.join(lines) + '\n'
    with open(os.path.join(args.out, 'report.md'), 'w', encoding='utf-8') as f:
        f.write(report)
    summary = os.environ.get('GITHUB_STEP_SUMMARY')
    if summary:
        with open(summary, 'a', encoding='utf-8') as f:
            f.write(report)
    secrets = [os.environ.get(k, '') for k in ('NODRIVE_WS_PW_TOKEN', 'NODRIVE_WS_SSO_TOKEN', 'NODRIVE_WS_LOGIN_PASSWORD')]
    if any(s and s in report for s in secrets):
        print('report contains a secret value', file=sys.stderr)
        os.remove(os.path.join(args.out, 'report.md'))
        return 2
    return 1 if failures else 0


if __name__ == '__main__':
    sys.exit(main())
