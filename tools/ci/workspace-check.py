#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Nourax
# SPDX-License-Identifier: GPL-3.0-or-later
"""Checks of the Workspace apps feature against the stand-in's request log (CI job "screens").

  python3 tools/ci/workspace-check.py stand-in.jsonl [--json out.json]     the safety checks
  python3 tools/ci/workspace-check.py --debug-only iOSClient/Workspace/NCUITestAccount.swift
  python3 tools/ci/workspace-check.py --scan-secret DIR...                 no throwaway password in any file

The log (tools/ci/drive-stand-in.py --workspace) holds one JSON line per request: host, path without query,
whether an Authorization header came, the NAMES of the cookies, a hash of the session id. Values are never logged.

  a  Authorization only on /ocs/, /remote.php/, /status.php and /index.php/avatar of drive.nourax.org; never on a
     page (/apps/..., /index.php/apps/...), and the app did send it on the sign-in request and the apps list
  b  no request to the other host carries Authorization or one of our cookies, and the other host was reached
     (the link opened in the browser panel)
  c  the throwaway password (environment NODRIVE_WS_APP_PASSWORD) is in no logged field
  d  at least one page of the account's server was served to a web view with session cookies (HTTP 200)
  e  the login page was never served, and no page request was sent back to /login (no sign-in page for the user)
  f  every session the pages used was issued by a sign-in request of the app (no stale web data), one per open
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


def check_log(path):
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
        problems.append('a: the app never sent its sign-in request (GET /ocs/v2.php/cloud/user)')
    if not navs:
        problems.append('a: the app never asked for the apps list with its sign-in header')
    facts['sign_in_requests'] = len(boots)
    facts['apps_list_requests'] = len(navs)
    facts['authorized_paths'] = sorted({e['path'] for e in drive if e.get('has_authorization')})

    # b
    for e in foreign:
        if e.get('has_authorization'):
            problems.append(f"b: Authorization sent to the other host ({e['path']})")
        leaked = [c for c in e.get('cookie_names', []) if c in OUR_COOKIES]
        if leaked:
            problems.append(f"b: our cookies sent to the other host: {leaked}")
    probes = [e for e in foreign if e.get('event') == 'foreign-probe']
    if not probes:
        problems.append('b: the other host was never reached (the link did not open in the browser panel)')
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
    issued = {e['issued_hash'] for e in entries if e.get('event') == 'session-issued'}
    used = {e['session_hash'] for e in pages if e.get('session_hash')}
    stale = used - issued
    for h in sorted(stale):
        problems.append(f'f: a page used a session no sign-in request of the app issued ({h})')
    if len(boots) < len(used):
        problems.append(f'f: {len(used)} sessions used by pages but only {len(boots)} sign-in requests')
    facts['sessions_issued'] = len(issued)
    facts['sessions_used_by_pages'] = len(used)

    return problems, facts


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
    ap.add_argument('--json')
    ap.add_argument('--debug-only')
    ap.add_argument('--scan-secret', nargs='+')
    args = ap.parse_args()
    if args.debug_only:
        problems = check_debug_only(args.debug_only)
        facts = {}
    elif args.scan_secret:
        problems = scan_secret(args.scan_secret)
        facts = {}
    elif args.log:
        problems, facts = check_log(args.log)
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
