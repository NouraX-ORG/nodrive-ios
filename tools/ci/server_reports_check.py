#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Nourax
# SPDX-License-Identifier: GPL-3.0-or-later
"""Problem reports: what the app relies on, checked on a real Nextcloud 35.0.2 server (throwaway, in Docker on the
runner; never drive.nourax.org).

Run by CI (job server-login) through `tools/ci/server-app-login.sh reports`. Credentials come from the environment
(NODRIVE_WS_USER, NODRIVE_WS_PW_TOKEN, NODRIVE_WS_PORT) and are never printed. The account `nourax-support` is created
here with a random password that is masked and never printed.

  B1  MKCOL of the folder "Problem reports": 201, then 405 (the app treats both as "the folder is there")
  B2  PUT with `If-None-Match: *`: 201 for a new name; the same name again: 412 and the content is unchanged
      (the app never replaces a report); a PUT without that header would replace the file (204): this is why the
      app always sends it
  B3  a read-only share to the user `nourax-support` before that account exists: not accepted (status and OCS message
      recorded: the stand-in of the simulator test copies this answer)
  B4  after `occ user:add nourax-support`: the same request is accepted, share_type 0 and permissions 1, and the list
      of the folder's shares (GET shares?path=/Problem reports) shows it
  B5  as `nourax-support`: the folder and the report are visible and can be read (200), and cannot be changed
      (PUT is refused) or deleted
Writes a Markdown report (names, sizes and status codes only) to <out>/reports.md and the step summary.
"""
import argparse
import base64
import http.client
import json
import os
import secrets
import subprocess
import sys
import urllib.parse

UA = 'Mozilla/5.0 (iOS) Nextcloud-iOS/35.2.1 NoDrive'
FOLDER = 'Problem reports'
SUPPORT = 'nourax-support'

lines = []
failures = []


def say(text=''):
    print(text, flush=True)
    lines.append(text)


def check(ok, what, detail=''):
    say(f'- {"PASS" if ok else "FAIL"}  {what}' + (f'  ({detail})' if detail else ''))
    if not ok:
        failures.append(what)
    return ok


class Server:
    def __init__(self, port, user, password):
        self.port, self.user = port, user
        self.auth = 'Basic ' + base64.b64encode(f'{user}:{password}'.encode()).decode()

    def request(self, method, path, body=None, headers=None):
        conn = http.client.HTTPConnection('localhost', self.port, timeout=90)
        h = {'User-Agent': UA, 'Authorization': self.auth, 'OCS-APIRequest': 'true', 'Accept': 'application/json'}
        h.update(headers or {})
        conn.request(method, path, body=body, headers=h)
        resp = conn.getresponse()
        data = resp.read()
        conn.close()
        return resp.status, data

    @staticmethod
    def dav(user, rest=''):
        base = f'/remote.php/dav/files/{urllib.parse.quote(user)}'
        return f'{base}/{urllib.parse.quote(rest)}' if rest else base

    def share(self, path, share_with):
        form = urllib.parse.urlencode({'path': path, 'shareType': '0', 'shareWith': share_with, 'permissions': '1'})
        status, data = self.request('POST', '/ocs/v2.php/apps/files_sharing/api/v1/shares', body=form.encode(),
                                    headers={'Content-Type': 'application/x-www-form-urlencoded'})
        try:
            ocs = json.loads(data)['ocs']
        except (ValueError, KeyError):
            ocs = {'meta': {}, 'data': {}}
        return status, ocs


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--container', default='nodrive-ci-server')
    ap.add_argument('--out', default='build/server-login')
    args = ap.parse_args()
    port = int(os.environ.get('NODRIVE_WS_PORT', '8080'))
    user = os.environ['NODRIVE_WS_USER']
    owner = Server(port, user, os.environ['NODRIVE_WS_PW_TOKEN'])

    say('## Problem reports: server checks (Nextcloud 35.0.2, throwaway)')
    say()
    say('### B1 The folder')
    status, _ = owner.request('MKCOL', owner.dav(user, FOLDER))
    check(status == 201, 'MKCOL "Problem reports" is created', str(status))
    status, _ = owner.request('MKCOL', owner.dav(user, FOLDER))
    check(status == 405, 'MKCOL again answers 405 (already there)', str(status))

    say()
    say('### B2 Never replace a report')
    name = '2026-10-28_11-44-03_ios_35.2.1-nourax.1.zip'
    first = b'PK-first-' + bytes(range(256)) * 4
    second = b'PK-second-' + b'z' * 300
    path = owner.dav(user, f'{FOLDER}/{name}')
    status, _ = owner.request('PUT', path, body=first, headers={'If-None-Match': '*'})
    check(status == 201, 'PUT with If-None-Match: * creates a new name', str(status))
    status, _ = owner.request('PUT', path, body=second, headers={'If-None-Match': '*'})
    check(status == 412, 'the same name again answers 412', str(status))
    status, data = owner.request('GET', path)
    check(status == 200 and data == first, 'the content is unchanged after the 412', f'GET {status}, {len(data)} bytes')
    other = owner.dav(user, f'{FOLDER}/2026-10-28_11-44-04_ios_35.2.1-nourax.1.zip')
    status, _ = owner.request('PUT', other, body=second, headers={'If-None-Match': '*'})
    check(status == 201, 'a name one second later is accepted', str(status))
    # Documents why the header is needed: without it the same name is replaced.
    status, _ = owner.request('PUT', other, body=first)
    check(status in (200, 204), 'a PUT without If-None-Match would replace the file (the app never sends it that way)', str(status))

    say()
    say('### B3 The share before the account exists')
    status, ocs = owner.share('/' + FOLDER, SUPPORT)
    accepted = status in (200, 201) and ocs.get('meta', {}).get('statuscode') == 200
    check(not accepted, 'a read-only share to a user that does not exist is not accepted',
          f'HTTP {status}, OCS statuscode {ocs.get("meta", {}).get("statuscode")}, message "{ocs.get("meta", {}).get("message")}"')
    check(status == 404, 'the answer is HTTP 404 (the simulator stand-in answers 404 "Sharee does not exist")', str(status))
    status, data = owner.request('GET', '/ocs/v2.php/apps/files_sharing/api/v1/shares?path=' + urllib.parse.quote('/' + FOLDER))
    listed = json.loads(data)['ocs']['data'] if status == 200 else None
    check(status == 200 and listed == [], 'the folder has no share yet', f'{status}, {listed}')

    say()
    say('### B4 After the account exists')
    support_password = secrets.token_hex(16)
    print(f'::add-mask::{support_password}', flush=True)
    # The value goes through the environment, never on a command line ("-e OC_PASS" takes it from there).
    done = subprocess.run(['docker', 'exec', '-u', 'www-data', '-e', 'OC_PASS', args.container,
                           'php', 'occ', 'user:add', '--password-from-env', '--display-name', 'Nourax Support', SUPPORT],
                          capture_output=True, text=True, env={**os.environ, 'OC_PASS': support_password})
    check(done.returncode == 0, f'occ user:add {SUPPORT}', f'exit {done.returncode}')
    status, ocs = owner.share('/' + FOLDER, SUPPORT)
    data = ocs.get('data') or {}
    check(status == 200 and ocs.get('meta', {}).get('statuscode') == 200, 'the same request is accepted',
          f'HTTP {status}, OCS {ocs.get("meta", {}).get("statuscode")} {ocs.get("meta", {}).get("message")}')
    check(isinstance(data, dict) and int(data.get('share_type', -1)) == 0, 'share_type is 0 (a user)', str(data.get('share_type')))
    check(isinstance(data, dict) and int(data.get('permissions', -1)) == 1, 'permissions is 1 (read only)', str(data.get('permissions')))
    status, raw = owner.request('GET', '/ocs/v2.php/apps/files_sharing/api/v1/shares?path=' + urllib.parse.quote('/' + FOLDER))
    listed = json.loads(raw)['ocs']['data'] if status == 200 else []
    check(any(str(s.get('share_with')) == SUPPORT and int(s.get('share_type', -1)) == 0 for s in listed),
          'GET shares?path=/Problem reports lists the share to nourax-support', f'{len(listed)} share(s)')

    say()
    say('### B5 What Nourax Support can do')
    support = Server(port, SUPPORT, support_password)
    status, data = support.request('GET', support.dav(SUPPORT, f'{FOLDER}/{name}'))
    check(status == 200 and data == first, 'the report can be read', f'GET {status}')
    status, _ = support.request('PUT', support.dav(SUPPORT, f'{FOLDER}/support-note.txt'), body=b'x')
    check(status in (401, 403, 409), 'a file cannot be added to the shared folder (read only)', str(status))
    status, _ = support.request('PUT', support.dav(SUPPORT, f'{FOLDER}/{name}'), body=b'changed')
    check(status in (401, 403, 409), 'the report cannot be changed', str(status))
    status, _ = support.request('DELETE', support.dav(SUPPORT, f'{FOLDER}/{name}'))
    check(status in (401, 403, 409), 'the report cannot be deleted', str(status))
    status, data = owner.request('GET', path)
    check(status == 200 and data == first, 'the owner still has the original report', f'GET {status}')

    say()
    say(f'{len(failures)} failure(s)' if failures else 'all problem-report server checks passed')
    os.makedirs(args.out, exist_ok=True)
    with open(os.path.join(args.out, 'reports.md'), 'w', encoding='utf-8') as f:
        f.write('\n'.join(lines) + '\n')
    summary = os.environ.get('GITHUB_STEP_SUMMARY')
    if summary:
        with open(summary, 'a', encoding='utf-8') as f:
            f.write('\n'.join(lines) + '\n')
    sys.exit(1 if failures else 0)


if __name__ == '__main__':
    main()
