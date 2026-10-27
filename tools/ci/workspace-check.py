#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Nourax
# SPDX-License-Identifier: GPL-3.0-or-later
"""Checks of the Workspace apps feature against the stand-in's request log (CI job "screens").

  python3 tools/ci/workspace-check.py stand-in.jsonl [--walk DIR] [--json out.json]     the safety checks
  python3 tools/ci/workspace-check.py --self-test                          the checks must fail on bad logs
  python3 tools/ci/workspace-check.py --debug-only iOSClient/Workspace/NCUITestAccount.swift
  python3 tools/ci/workspace-check.py --scan-secret DIR...                 no throwaway password in any file

The log (tools/ci/drive-stand-in.py --workspace) holds one JSON line per request: host, path without query,
whether an Authorization header came, the NAMES of the cookies, a hash of the session id. Values are never logged.
The app's Workspace sign-in request carries ?nodrive=ws and is logged as "bootstrap"; the account setup asks the same
path without it and is logged as "account-setup", so the two are never mixed up. The UI test writes walk.jsonl
(one per variant, under --walk) with the time of every app launch.

  a  Authorization only on /ocs/, /remote.php/, /status.php and /index.php/avatar of drive.nourax.org; never on a
     page (/apps/..., /index.php/apps/...), and the app did send it on a Workspace sign-in request (a "bootstrap",
     not the account setup) and on the apps list
  b  no request to the other host carries Authorization or one of our cookies, and the other host was reached by
     every route the UI test takes: a link, a server redirect, a new window, window.open and the NoMail entry
  c  the throwaway password (environment NODRIVE_WS_APP_PASSWORD) is in no logged field
  d  at least one page of the account's server was served to a web view with session cookies (HTTP 200)
  e  the login page was never served, and no page request was sent back to /login (no sign-in page for the user)
  f  no session left from an earlier launch: every session a page used was issued by a Workspace sign-in request
     ("bootstrap") after the app was launched for that page (launch times from walk.jsonl), and the app was
     launched more than once (the second launch must again sign in by itself)
  g  session expiry: a session ended on the server, the app signed in again (a new "bootstrap"), and the page then
     came with the new session and without any login page
"""

import argparse
import json
import os
import re
import sys

DRIVE = 'drive.nourax.org'
FOREIGN = 'foreign.nodrive-ci.test'
AUTH_OK = ('/ocs/', '/remote.php/', '/status.php', '/index.php/avatar', '/index.php/status.php')
OUR_COOKIES = ('oc_sessionPassphrase', 'ocstandin01', '__Host-nc_sameSiteCookielax', '__Host-nc_sameSiteCookiestrict')
PAGE_RE = re.compile(r'^(?:/index\.php)?/apps/')


FOREIGN_EVENTS = ('foreign-probe', 'foreign-redirect', 'foreign-blank', 'foreign-window-open', 'foreign-nomail')


def read_launches(walk_dir):
    """The start times of every app launch the UI test recorded (walk.jsonl of the workspace variants)."""
    times = []
    if not walk_dir:
        return times
    for root, _, files in os.walk(walk_dir):
        if 'walk.jsonl' not in files or not os.path.basename(root).startswith('workspace'):
            continue
        with open(os.path.join(root, 'walk.jsonl'), encoding='utf-8') as f:
            for line in f:
                try:
                    entry = json.loads(line)
                except ValueError:
                    continue
                if entry.get('step') == 'launch-begin' and 't' in entry:
                    times.append(float(entry['t']))
    return sorted(times)


def check_log(path, walk_dir=None):
    entries = []
    with open(path, encoding='utf-8') as f:
        for line in f:
            if line.strip():
                entries.append(json.loads(line))
    problems, facts = [], {}
    requests = [e for e in entries if 'method' in e]
    drive = [e for e in requests if e.get('host', '').split(':')[0] == DRIVE]
    foreign = [e for e in requests if e.get('host', '').split(':')[0] == FOREIGN]

    # a
    bad_auth = [e for e in drive if e.get('has_authorization') and not e['path'].startswith(AUTH_OK)]
    for e in bad_auth:
        problems.append(f"a: Authorization sent to {e['method']} {e['path']}")
    page_auth = [e for e in drive if e.get('has_authorization') and PAGE_RE.match(e['path'])]
    for e in page_auth:
        problems.append(f"a: Authorization on a page request {e['path']}")
    boots = [e for e in drive if e.get('event') == 'bootstrap']
    navs = [e for e in drive if e['path'] == '/ocs/v2.php/core/navigation/apps' and e.get('has_authorization')]
    if not boots:
        problems.append('a: the app never sent its Workspace sign-in request (GET /ocs/v2.php/cloud/user?nodrive=ws)')
    if not navs:
        problems.append('a: the app never asked for the apps list with its sign-in header')
    facts['sign_in_requests'] = len(boots)
    facts['account_setup_requests'] = len([e for e in drive if e.get('event') == 'account-setup'])
    facts['apps_list_requests'] = len(navs)
    facts['authorized_paths'] = sorted({e['path'] for e in drive if e.get('has_authorization')})

    # b
    for e in foreign:
        if e.get('has_authorization'):
            problems.append(f"b: Authorization sent to the other host ({e['path']})")
        leaked = [c for c in e.get('cookie_names', []) if c in OUR_COOKIES]
        if leaked:
            problems.append(f"b: our cookies sent to the other host: {leaked}")
    reached = {e.get('event') for e in foreign}
    for event in FOREIGN_EVENTS:
        if event not in reached:
            problems.append(f'b: the other host never saw {event} (that route did not open the browser panel)')
    facts['other_host_requests'] = len(foreign)

    # c
    password = os.environ.get('NODRIVE_WS_APP_PASSWORD', '')
    if password:
        with open(path, encoding='utf-8') as f:
            if password in f.read():
                problems.append('c: the throwaway password appears in the request log')
    else:
        problems.append('c: NODRIVE_WS_APP_PASSWORD is not set, cannot check the log for it')

    # d
    pages = [e for e in drive if e.get('event') == 'page' and e['status'] == 200]
    with_cookies = [e for e in pages if 'oc_sessionPassphrase' in e.get('cookie_names', [])]
    if not with_cookies:
        problems.append('d: no page of the account was served with session cookies')
    facts['pages_served'] = sorted({e['path'] for e in pages})

    # e
    login = [e for e in drive if e.get('event') in ('login-page', 'page-redirect-to-login')]
    for e in login:
        problems.append(f"e: a login page was served ({e['path']})")

    # f
    issued = {e['issued_hash']: e for e in entries if e.get('event') == 'session-issued'}
    launches = read_launches(walk_dir)
    used = {}
    for e in pages:
        if e.get('session_hash'):
            used.setdefault(e['session_hash'], []).append(e)
    for h, served in sorted(used.items()):
        info = issued.get(h)
        if info is None:
            problems.append(f'f: a page used a session no sign-in request of the app issued ({h})')
            continue
        if info.get('issued_by') != 'bootstrap':
            problems.append(f'f: a page used a session of the account setup, not of a Workspace sign-in ({h})')
        for page in served:
            before = [t for t in launches if t <= page['t']]
            if before and info['t'] < before[-1]:
                problems.append(f'f: a page used a session issued before the last app launch ({h}, {page["path"]})')
                break
    if len(boots) < len(used):
        problems.append(f'f: {len(used)} sessions used by pages but only {len(boots)} sign-in requests')
    if walk_dir is not None:
        if len(launches) < 2:
            problems.append(f'f: {len(launches)} app launch(es) recorded; the test must launch the app again '
                            '(a second launch must sign in by itself)')
        for i, start in enumerate(launches):
            end = launches[i + 1] if i + 1 < len(launches) else float('inf')
            if not any(start <= e['t'] < end for e in pages):
                problems.append(f'f: no page was served after app launch {i + 1}')
    facts['sessions_issued'] = len(issued)
    facts['sessions_used_by_pages'] = len(used)
    facts['app_launches'] = len(launches)

    # g
    expired = [e for e in drive if e.get('event') == 'session-expired']
    if not expired:
        problems.append('g: the session was never ended on the server (the expiry route did not run)')
    for e in expired:
        again = [b for b in boots if b['t'] > e['t']]
        renewed = [p for p in pages if p['t'] > e['t'] and p.get('sub') == 'expire']
        if not again:
            problems.append('g: the session ended and the app never signed in again')
        elif not renewed:
            problems.append('g: the app signed in again but the page did not come back with the new session')
    facts['sessions_expired'] = len(expired)

    return problems, facts


def _good_log():
    """A log of a correct run: two launches, each signs in by itself, opens Mail, and takes every route."""
    t = 1000.0
    log = []

    def add(**kw):
        nonlocal t
        t += 1
        kw.setdefault('t', t)
        log.append(kw)

    launches = []
    sessions = {}
    for n in (1, 2):
        launches.append({'step': 'launch-begin', 't': t + 0.5})
        # the account setup (same path as the Workspace sign-in, but no marker) and its own session
        add(method='GET', path='/ocs/v2.php/cloud/user', host=DRIVE, event='account-setup', status=200, has_authorization=True)
        add(event='session-issued', issued_by='account-setup', issued_hash=f'setup{n}')
        add(method='GET', path='/ocs/v2.php/core/navigation/apps', host=DRIVE, status=200, has_authorization=True)
        add(method='GET', path='/ocs/v2.php/cloud/user', host=DRIVE, event='bootstrap', status=200, has_authorization=True)
        sessions[n] = f'boot{n}'
        add(event='session-issued', issued_by='bootstrap', issued_hash=sessions[n])
        add(method='GET', path='/apps/mail/', host=DRIVE, event='page', status=200, has_authorization=False,
            cookie_names=['oc_sessionPassphrase', 'ocstandin01'], session_hash=sessions[n], sub='')
    add(method='GET', path='/apps/mail/expire', host=DRIVE, event='session-expired', status=302, has_authorization=False,
        cookie_names=['oc_sessionPassphrase'], session_hash=sessions[2])
    add(method='GET', path='/ocs/v2.php/cloud/user', host=DRIVE, event='bootstrap', status=200, has_authorization=True)
    add(event='session-issued', issued_by='bootstrap', issued_hash='renewed')
    add(method='GET', path='/apps/mail/expire', host=DRIVE, event='page', status=200, has_authorization=False,
        cookie_names=['oc_sessionPassphrase', 'ocstandin01'], session_hash='renewed', sub='expire')
    for event in FOREIGN_EVENTS:
        add(method='GET', path='/' + event, host=FOREIGN, event=event, status=200, has_authorization=False, cookie_names=[])
    return log, launches


def self_test():
    """The checks above must be able to fail: each broken copy of a good log has to produce a problem."""
    import copy
    import tempfile
    problems = []

    def run(log, launches, expect, label, walk=True):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, 'stand-in.jsonl')
            with open(path, 'w', encoding='utf-8') as f:
                for e in log:
                    f.write(json.dumps(e) + '\n')
            walk_dir = None
            if walk:
                folder = os.path.join(tmp, 'workspace-light')
                os.makedirs(folder)
                with open(os.path.join(folder, 'walk.jsonl'), 'w', encoding='utf-8') as f:
                    for e in launches:
                        f.write(json.dumps(e) + '\n')
                walk_dir = tmp
            found, _ = check_log(path, walk_dir)
            if expect is None and found:
                problems.append(f'self-test: the good log failed ({label}): {found}')
            if expect is not None and not any(p.startswith(expect) for p in found):
                problems.append(f'self-test: "{label}" was not caught (wanted a "{expect}" problem, got {found})')

    old_password = os.environ.get('NODRIVE_WS_APP_PASSWORD')
    os.environ['NODRIVE_WS_APP_PASSWORD'] = 'self-test-password'
    try:
        log, launches = _good_log()
        run(log, launches, None, 'good run')

        # a: the Workspace sign-in request is missing, only the account setup is there
        broken = [e for e in copy.deepcopy(log) if e.get('event') != 'bootstrap']
        run(broken, launches, 'a:', 'no Workspace sign-in request (the account setup does not count)')

        # a: Authorization on a page
        broken = copy.deepcopy(log)
        next(e for e in broken if e.get('event') == 'page')['has_authorization'] = True
        run(broken, launches, 'a:', 'Authorization on a page')

        # b: a cookie reached the other host
        broken = copy.deepcopy(log)
        next(e for e in broken if e.get('event') == 'foreign-probe')['cookie_names'] = ['oc_sessionPassphrase']
        run(broken, launches, 'b:', 'cookie sent to the other host')

        # b: a route never reached the other host
        broken = [e for e in copy.deepcopy(log) if e.get('event') != 'foreign-nomail']
        run(broken, launches, 'b:', 'NoMail never opened in the panel')

        # e: the login page was served
        broken = copy.deepcopy(log)
        broken.append({'t': 9999, 'method': 'GET', 'path': '/login', 'host': DRIVE, 'event': 'login-page', 'status': 200})
        run(broken, launches, 'e:', 'login page served')

        # f: a page used a session of an earlier launch
        broken = copy.deepcopy(log)
        second = [e for e in broken if e.get('event') == 'page' and e.get('session_hash') == 'boot2'][0]
        second['session_hash'] = 'boot1'
        run(broken, launches, 'f:', 'session of the first launch used after the second')

        # f: a page used the session of the account setup
        broken = copy.deepcopy(log)
        next(e for e in broken if e.get('event') == 'page')['session_hash'] = 'setup1'
        run(broken, launches, 'f:', 'session of the account setup used by a page')

        # f: the app was launched once only
        run(log, launches[:1], 'f:', 'one launch only')

        # f: no launch markers at all
        run(log, [], 'f:', 'no launch markers')

        # g: the session never ended
        broken = [e for e in copy.deepcopy(log) if e.get('event') != 'session-expired']
        run(broken, launches, 'g:', 'no expiry')

        # g: the session ended and the app never signed in again
        broken = copy.deepcopy(log)
        index = next(i for i, e in enumerate(broken) if e.get('event') == 'session-expired')
        broken = [e for i, e in enumerate(broken) if not (i > index and e.get('event') in ('bootstrap', 'session-issued', 'page'))]
        run(broken, launches, 'g:', 'no new sign-in after the expiry')
    finally:
        if old_password is None:
            os.environ.pop('NODRIVE_WS_APP_PASSWORD', None)
        else:
            os.environ['NODRIVE_WS_APP_PASSWORD'] = old_password
    return problems


def check_debug_only(path):
    with open(path, encoding='utf-8') as f:
        text = f.read()
    problems = []
    lines = text.splitlines()
    first = next((i for i, ln in enumerate(lines) if ln.strip() == '#if DEBUG'), None)
    els = next((i for i, ln in enumerate(lines) if ln.strip() == '#else'), None)
    if first is None or els is None or first > els:
        problems.append(f'{path}: the account code must sit inside "#if DEBUG ... #else (empty stub) ... #endif"')
    elif any(k in '\n'.join(lines[els:]) for k in ('createAccount', 'NODRIVE_UITEST_ACCOUNT', 'password')):
        problems.append(f'{path}: the Release stub (after #else) must not hold the account code')
    # nothing but comments and imports before the first #if DEBUG
    if first is not None:
        for ln in lines[:first]:
            s = ln.strip()
            if s and not s.startswith(('//', 'import ')):
                problems.append(f'{path}: code before "#if DEBUG": {s}')
    return problems


def scan_secret(dirs):
    password = os.environ.get('NODRIVE_WS_APP_PASSWORD', '')
    if not password:
        return ['NODRIVE_WS_APP_PASSWORD is not set']
    needle = password.encode()
    problems, scanned = [], 0
    for top in dirs:
        for root, _, files in os.walk(top):
            for name in files:
                p = os.path.join(root, name)
                try:
                    with open(p, 'rb') as f:
                        data = f.read()
                except OSError:
                    continue
                scanned += 1
                if needle in data:
                    problems.append(f'the throwaway password is in {p}')
    print(f'scanned {scanned} files')
    return problems


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('log', nargs='?')
    ap.add_argument('--walk', help='folder with the UI test output (workspace-*/walk.jsonl)')
    ap.add_argument('--self-test', action='store_true')
    ap.add_argument('--json')
    ap.add_argument('--debug-only')
    ap.add_argument('--scan-secret', nargs='+')
    args = ap.parse_args()
    if args.self_test:
        problems = self_test()
        facts = {}
    elif args.debug_only:
        problems = check_debug_only(args.debug_only)
        facts = {}
    elif args.scan_secret:
        problems = scan_secret(args.scan_secret)
        facts = {}
    elif args.log:
        problems, facts = check_log(args.log, args.walk)
    else:
        ap.error('give the request log, --debug-only FILE or --scan-secret DIR...')
    for k, v in facts.items():
        print(f'{k}: {v}')
    for p in problems:
        print('PROBLEM:', p)
    print('workspace-check:', 'ok' if not problems else f'{len(problems)} problem(s)')
    if args.json:
        with open(args.json, 'w', encoding='utf-8') as f:
            json.dump({'ok': not problems, 'problems': problems, 'facts': facts}, f, indent=2)
    return 0 if not problems else 1


if __name__ == '__main__':
    sys.exit(main())
