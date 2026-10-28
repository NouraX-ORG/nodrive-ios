#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Nourax
# SPDX-License-Identifier: GPL-3.0-or-later
"""Round 3 checks on a real Nextcloud 35.0.2 server (throwaway, in Docker on the runner; never drive.nourax.org).

Run by CI (job server-login) through `tools/ci/server-app-login.sh round3`. Credentials come from the environment
(NODRIVE_WS_USER, NODRIVE_WS_PW_TOKEN, NODRIVE_WS_PORT) and are never printed.

Smart conflicts (feature "conflicts"):
  A1  the PROPFIND body of the app (iOSClient/SmartConflicts/NCConflictProbe.swift, between the markers
      PROPFIND-BODY-BEGIN and PROPFIND-BODY-END) is sent as it is:
        - a file of 12345 bytes -> 207 with d:getcontentlength 12345 in a 200 propstat, and oc:size equal
        - a name that does not exist -> 404
        - a folder -> d:collection in d:resourcetype (200 propstat) and d:getcontentlength only in a 404 propstat
  A2  the shape of these answers (namespaced element paths) is the shape of the fixtures in the unit tests
      (Tests/NextcloudUnitTests/NoDriveSmartConflictsTests.swift: fileAnswer, folderAnswer), so the fixtures
      stay the real shape (a drift check).
  A3  a PUT of the same name with another size replaces the file (this is what "Keep the phone copy" relies on),
      and the size read by the probe follows it.
Writes a Markdown report (names, sizes and status codes only) to <out>/round3.md and the step summary.
"""
import argparse
import base64
import http.client
import os
import re
import sys
import xml.etree.ElementTree as ET

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
PROBE_SWIFT = os.path.join(ROOT, 'iOSClient', 'SmartConflicts', 'NCConflictProbe.swift')
TESTS_SWIFT = os.path.join(ROOT, 'Tests', 'NextcloudUnitTests', 'NoDriveSmartConflictsTests.swift')
UA = 'Mozilla/5.0 (iOS) Nextcloud-iOS/35.2.1 NoDrive'

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


def swift_literal(text, name):
    """The multi-line string literal `<name> = \"\"\"...\"\"\"` of a Swift file, indentation removed as Swift does."""
    m = re.search(r'\b' + re.escape(name) + r' = """\n(.*?)\n([ \t]*)"""', text, re.S)
    if not m:
        raise SystemExit(f'literal {name} not found')
    indent = m.group(2)
    return '\n'.join(ln[len(indent):] if ln.startswith(indent) else ln for ln in m.group(1).split('\n'))


def probe_body():
    with open(PROBE_SWIFT, encoding='utf-8') as f:
        text = f.read()
    m = re.search(r'// PROPFIND-BODY-BEGIN\n(.*?)// PROPFIND-BODY-END', text, re.S)
    if not m:
        raise SystemExit('PROPFIND-BODY markers not found in NCConflictProbe.swift')
    return swift_literal(m.group(1), 'requestBodyText')


def paths(xml_text):
    """The set of namespaced element paths of an answer, text and attributes left out."""
    out = set()

    def walk(node, prefix):
        path = prefix + '/' + node.tag
        out.add(path)
        for child in node:
            walk(child, path)
    walk(ET.fromstring(xml_text), '')
    return out


def read_state(xml_bytes):
    """Python twin of NCPropfindSizeParser: ('file', size) | ('folder',) | ('unknown',)."""
    root = ET.fromstring(xml_bytes)
    response = root.find('{DAV:}response')
    if response is None:
        return ('unknown',)
    length, collection = None, False
    for propstat in response.findall('{DAV:}propstat'):
        status = (propstat.findtext('{DAV:}status') or '').split()
        if len(status) < 2 or status[1] != '200':
            continue
        prop = propstat.find('{DAV:}prop')
        if prop is None:
            continue
        if prop.find('{DAV:}resourcetype/{DAV:}collection') is not None:
            collection = True
        if prop.find('{DAV:}getcontentlength') is not None:
            length = (prop.findtext('{DAV:}getcontentlength') or '').strip()
    if collection:
        return ('folder',)
    if length is not None and length.isdigit():
        return ('file', int(length))
    return ('unknown',)


class Server:
    def __init__(self, port, user, password):
        self.port, self.user = port, user
        self.auth = 'Basic ' + base64.b64encode(f'{user}:{password}'.encode()).decode()

    def request(self, method, path, body=None, headers=None):
        conn = http.client.HTTPConnection('localhost', self.port, timeout=90)
        h = {'User-Agent': UA, 'Authorization': self.auth, 'OCS-APIRequest': 'true'}
        h.update(headers or {})
        conn.request(method, path, body=body, headers=h)
        resp = conn.getresponse()
        data = resp.read()
        conn.close()
        return resp.status, data

    def propfind(self, path, body):
        return self.request('PROPFIND', path, body=body.encode(),
                            headers={'Depth': '0', 'Content-Type': 'application/xml'})


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--out', default='build/server-login')
    args = ap.parse_args()
    port = int(os.environ.get('NODRIVE_WS_PORT', '8080'))
    user = os.environ['NODRIVE_WS_USER']
    srv = Server(port, user, os.environ['NODRIVE_WS_PW_TOKEN'])
    base = f'/remote.php/dav/files/{user}/Round3Check'
    body = probe_body()

    say('## Round 3 server checks (Nextcloud 35.0.2, throwaway)')
    say()
    say('### Smart conflicts: the size the app reads')
    check('getcontentlength' in body and 'resourcetype' in body, 'the app asks for getcontentlength and resourcetype')

    status, _ = srv.request('MKCOL', base)
    check(status in (201, 405), 'folder for the checks exists', f'MKCOL {status}')
    status, _ = srv.request('MKCOL', base + '/Folder')
    check(status in (201, 405), 'a folder named Folder exists', f'MKCOL {status}')

    payload = bytes(range(256)) * 48 + b'x' * (12345 - 256 * 48)
    assert len(payload) == 12345
    status, _ = srv.request('PUT', base + '/IMG_0001.HEIC', body=payload)
    check(status in (201, 204), 'a file of 12345 bytes is uploaded', f'PUT {status}')

    status, data = srv.propfind(base + '/IMG_0001.HEIC', body)
    check(status == 207, 'PROPFIND of the file answers 207', str(status))
    file_state = read_state(data) if status == 207 else ('unknown',)
    check(file_state == ('file', 12345), 'the file answer has getcontentlength 12345 in a 200 propstat', str(file_state))
    root = ET.fromstring(data) if status == 207 else None
    oc_size = root.findtext('.//{http://owncloud.org/ns}size') if root is not None else None
    check(oc_size == '12345', 'oc:size is the same', str(oc_size))
    file_paths = paths(data) if status == 207 else set()

    status, _ = srv.propfind(base + '/Missing.HEIC', body)
    check(status == 404, 'a name that does not exist answers 404', str(status))

    status, data = srv.propfind(base + '/Folder', body)
    check(status == 207, 'PROPFIND of a folder answers 207', str(status))
    folder_state = read_state(data) if status == 207 else ('unknown',)
    check(folder_state == ('folder',), 'a folder is told apart (d:collection)', str(folder_state))
    if status == 207:
        propstats = ET.fromstring(data).findall('.//{DAV:}propstat')
        in_404 = [p for p in propstats if (p.findtext('{DAV:}status') or '').split()[1:2] == ['404']
                  and p.find('{DAV:}prop/{DAV:}getcontentlength') is not None]
        check(len(in_404) == 1, 'a folder reports getcontentlength only in a 404 propstat', f'{len(in_404)} propstat(s)')
    folder_paths = paths(data) if status == 207 else set()

    say()
    say('### The unit-test fixtures keep the real shape')
    with open(TESTS_SWIFT, encoding='utf-8') as f:
        tests = f.read()
    for name, real in (('fileAnswer', file_paths), ('folderAnswer', folder_paths)):
        fixture = paths(swift_literal(tests, name))
        check(fixture == real, f'{name}: same element paths as the real answer',
              f'only fixture: {sorted(fixture - real)}; only real: {sorted(real - fixture)}')

    say()
    say('### Keep the phone copy: a PUT of the same name replaces the file')
    status, _ = srv.request('PUT', base + '/IMG_0001.HEIC', body=b'y' * 777)
    check(status in (201, 204), 'the file is uploaded again with another size', f'PUT {status}')
    status, data = srv.propfind(base + '/IMG_0001.HEIC', body)
    check(status == 207 and read_state(data) == ('file', 777), 'the size read follows the replacement',
          str(read_state(data) if status == 207 else status))

    say()
    say(f'{len(failures)} failure(s)' if failures else 'all round 3 server checks passed')
    os.makedirs(args.out, exist_ok=True)
    with open(os.path.join(args.out, 'round3.md'), 'w', encoding='utf-8') as f:
        f.write('\n'.join(lines) + '\n')
    summary = os.environ.get('GITHUB_STEP_SUMMARY')
    if summary:
        with open(summary, 'a', encoding='utf-8') as f:
            f.write('\n'.join(lines) + '\n')
    sys.exit(1 if failures else 0)


if __name__ == '__main__':
    main()
