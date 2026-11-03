#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Nourax
# SPDX-License-Identifier: GPL-3.0-or-later
"""Checks of the device-sync UI test (CI job "screens", shard device-sync), made on what the stand-in saw and what the
app wrote.

  python3 tools/ci/devicesync-check.py --log stand-in.jsonl --walk SHOTS --variants devicesync-light devicesync-dark \
          [--json out.json]
  python3 tools/ci/devicesync-check.py --self-test        the checks must fail on bad data

Each variant runs two sign-ins (test1: installed, test2: "It didn't work"). The stand-in
(tools/ci/drive-stand-in.py --workspace --device-sync) writes one JSON line per request (names and facts only), never the
throwaway password or the poll token. The checks:

  a  every sign-in request went to drive.nourax.org, and to no other host
  b  every sign-in start was a POST /index.php/login/v2 with the user agent "NoDrive Calendar & Contacts (iPhone)"
     (the name of the app password in the server's security settings), without an Authorization header
  c  every start was followed by the flow page (opened on drive.nourax.org) and a grant; no poll before the page was
     opened was answered with a grant; every poll carried that user agent
  d  "It didn't work" revoked the password: one DELETE ocs/v2.php/core/apppassword per variant, with Basic auth of the
     new password and OCS-APIRequest, answered 200; nothing was refused
  e  the redacted copy of the profile the app built, per variant: a property list with Apple's keys, the passwords
     replaced, the host and principal of the account, no name of the upstream product; `plutil -lint` agrees when it exists
  f  the UI test's own records: profile checked, "It didn't work" shown, removal steps shown; Apple's own screens are
     reported (PASS or NOT VERIFIED), never failing
"""
import argparse
import json
import os
import plistlib
import shutil
import subprocess
import sys
import tempfile

DRIVE = 'drive.nourax.org'
DEVICE_UA = 'NoDrive Calendar & Contacts (iPhone)'
TOP_KEYS = {'PayloadType', 'PayloadVersion', 'PayloadIdentifier', 'PayloadUUID', 'PayloadDisplayName',
            'PayloadOrganization', 'PayloadDescription', 'PayloadRemovalDisallowed', 'PayloadContent'}


def load_log(path):
    events = []
    with open(path, encoding='utf-8') as f:
        for line in f:
            line = line.strip()
            if line:
                try:
                    events.append(json.loads(line))
                except ValueError:
                    pass
    return events


def check_log(events, variants):
    problems = []
    device = [e for e in events if str(e.get('event', '')).startswith(('device-', 'browser-opened-device'))]
    starts = [e for e in device if e['event'] == 'device-flow-start']
    pages = [e for e in device if e['event'] == 'browser-opened-device-flow']
    polls = [e for e in device if e['event'] == 'device-poll']
    grants = [e for e in device if e['event'] == 'device-grant']
    revoked = [e for e in device if e['event'] == 'device-apppassword-revoked']
    refused = [e for e in device if e['event'] == 'device-apppassword-refused']
    expected = 2 * len(variants)
    # a
    for e in device:
        if e.get('host') != DRIVE:
            problems.append(f"a: a device sign-in request went to host {e.get('host')!r}")
    # b
    if len(starts) != expected:
        problems.append(f'b: {len(starts)} sign-in starts, {expected} expected (two per variant)')
    for e in starts:
        if e.get('method') != 'POST' or e.get('path') != '/index.php/login/v2':
            problems.append(f"b: a start was {e.get('method')} {e.get('path')}")
        if e.get('user_agent') != DEVICE_UA:
            problems.append(f"b: a start came with the user agent {e.get('user_agent')!r}")
        if e.get('has_authorization'):
            problems.append('b: a start carried an Authorization header')
    # c
    if len(pages) != len(starts):
        problems.append(f'c: {len(pages)} flow pages opened for {len(starts)} starts')
    for e in pages:
        if not str(e.get('path', '')).startswith('/login/v2/flow/'):
            problems.append(f"c: the flow page path was {e.get('path')!r}")
    if len(grants) != len(starts):
        problems.append(f'c: {len(grants)} grants for {len(starts)} starts')
    for e in polls + grants:
        if e.get('user_agent') != DEVICE_UA:
            problems.append(f"c: a poll came with the user agent {e.get('user_agent')!r}")
    opened = False
    for e in device:
        if e['event'] == 'device-flow-start':
            opened = False
        elif e['event'] == 'browser-opened-device-flow':
            opened = True
        elif e['event'] == 'device-grant' and not opened:
            problems.append('c: a grant before the flow page was opened')
    # d
    if len(revoked) != len(variants):
        problems.append(f'd: {len(revoked)} revocations, {len(variants)} expected (one per variant)')
    for e in revoked:
        if e.get('method') != 'DELETE' or e.get('path') not in ('/ocs/v2.php/core/apppassword', '/index.php/ocs/v2.php/core/apppassword'):
            problems.append(f"d: the revocation was {e.get('method')} {e.get('path')}")
        if not e.get('has_authorization') or not e.get('ocs_api_request'):
            problems.append('d: the revocation lacked its Basic header or OCS-APIRequest')
        if e.get('status') != 200:
            problems.append(f"d: the revocation was answered {e.get('status')}")
        if e.get('user_agent') != DEVICE_UA:
            problems.append(f"d: the revocation came with the user agent {e.get('user_agent')!r}")
    if refused:
        problems.append(f'd: {len(refused)} revocation(s) were refused')
    return problems, {'starts': len(starts), 'pages': len(pages), 'polls': len(polls), 'grants': len(grants),
                      'revocations': len(revoked)}


def check_profile(path, label, lint=True):
    problems = []
    try:
        with open(path, 'rb') as f:
            data = f.read()
        root = plistlib.loads(data)
    except (OSError, ValueError, plistlib.InvalidFileException) as e:
        return [f'e: {label}: the redacted profile cannot be read: {e}'], {}
    if lint and shutil.which('plutil'):
        done = subprocess.run(['plutil', '-lint', path], capture_output=True, text=True)
        if done.returncode != 0:
            problems.append(f'e: {label}: plutil -lint says: {done.stdout.strip()} {done.stderr.strip()}')
    if set(root) != TOP_KEYS:
        problems.append(f'e: {label}: top-level keys differ: {sorted(set(root) ^ TOP_KEYS)}')
    if root.get('PayloadType') != 'Configuration' or root.get('PayloadVersion') != 1:
        problems.append(f'e: {label}: wrong PayloadType or PayloadVersion')
    if root.get('PayloadDisplayName') != 'NoDrive Calendar & Contacts' or root.get('PayloadOrganization') != 'Nourax':
        problems.append(f'e: {label}: wrong name or organisation')
    if root.get('PayloadRemovalDisallowed') is not False:
        problems.append(f'e: {label}: the profile must be removable')
    content = root.get('PayloadContent') or []
    if [c.get('PayloadType') for c in content] != ['com.apple.caldav.account', 'com.apple.carddav.account']:
        problems.append(f'e: {label}: the payloads are not CalDAV then CardDAV')
    for c, prefix in zip(content, ('CalDAV', 'CardDAV')):
        keys = {prefix + k for k in ('AccountDescription', 'HostName', 'Port', 'UseSSL', 'Username', 'Password', 'PrincipalURL')}
        if not keys <= set(c):
            problems.append(f'e: {label}: the {prefix} payload misses {sorted(keys - set(c))}')
            continue
        if c[prefix + 'Password'] != '<redacted>':
            problems.append(f'e: {label}: the {prefix} password is not redacted')
        if c[prefix + 'HostName'] != DRIVE or c[prefix + 'Port'] != 443 or c[prefix + 'UseSSL'] is not True:
            problems.append(f'e: {label}: the {prefix} host, port or SSL is wrong')
        if not str(c[prefix + 'PrincipalURL']).startswith(f'https://{DRIVE}/remote.php/dav/principals/users/'):
            problems.append(f'e: {label}: the {prefix} principal URL is wrong')
        if c.get('PayloadIdentifier', '').rsplit('.', 1)[0] != root.get('PayloadIdentifier'):
            problems.append(f'e: {label}: the {prefix} payload identifier does not extend the profile identifier')
    if b'nextcloud' in data.lower():
        problems.append(f'e: {label}: the profile names the upstream product')
    return problems, {'payloads': len(content)}


def read_records(path):
    records = []
    try:
        with open(path, encoding='utf-8') as f:
            for line in f:
                try:
                    records.append(json.loads(line))
                except ValueError:
                    pass
    except OSError:
        pass
    return records


def check_variant(walk, variant, lint=True):
    problems, facts = [], {}
    folder = os.path.join(walk, variant)
    p, f = check_profile(os.path.join(folder, 'devicesync-profile-redacted.mobileconfig'), variant, lint)
    problems += p
    facts.update(f)
    steps = {r.get('step') for r in read_records(os.path.join(folder, 'walk.jsonl'))}
    for step, what in (('profile-checked', 'the profile was checked'), ('didnt-work', '"It didn\'t work" was shown'),
                       ('removal', 'the removal steps were shown'), ('waiting', 'the waiting step was shown')):
        if step not in steps:
            problems.append(f'f: {variant}: the UI test did not record that {what}')
    try:
        with open(os.path.join(folder, 'apple-screens.json'), encoding='utf-8') as fh:
            facts['apple'] = json.load(fh)
    except (OSError, ValueError):
        facts['apple'] = {}
    return problems, facts


def run(log, walk, variants, lint=True):
    events = load_log(log)
    problems, facts = check_log(events, variants)
    per_variant = {}
    for variant in variants:
        p, f = check_variant(walk, variant, lint)
        problems += p
        per_variant[variant] = f
    facts['variants'] = per_variant
    return problems, facts


# ---------------------------------------------------------------------------------------------------------------
def _good_log(variants):
    events = []
    for _ in variants:
        for n in range(2):
            ua = DEVICE_UA
            events += [
                {'event': 'device-flow-start', 'method': 'POST', 'path': '/index.php/login/v2', 'host': DRIVE, 'user_agent': ua, 'has_authorization': False, 'status': 200},
                {'event': 'device-poll', 'host': DRIVE, 'user_agent': ua, 'status': 404},
                {'event': 'browser-opened-device-flow', 'method': 'GET', 'path': '/login/v2/flow/x', 'host': DRIVE, 'user_agent': 'Mozilla', 'status': 200},
                {'event': 'device-poll', 'host': DRIVE, 'user_agent': ua, 'status': 404},
                {'event': 'device-grant', 'host': DRIVE, 'user_agent': ua, 'status': 200},
            ]
            if n == 1:
                events.append({'event': 'device-apppassword-revoked', 'method': 'DELETE', 'path': '/ocs/v2.php/core/apppassword', 'host': DRIVE,
                               'user_agent': ua, 'has_authorization': True, 'ocs_api_request': True, 'status': 200})
    return events


def _good_profile():
    def payload(prefix, kind):
        return {'PayloadType': f'com.apple.{kind}.account', 'PayloadVersion': 1, 'PayloadIdentifier': 'a.b.x.' + kind, 'PayloadUUID': 'u',
                'PayloadDisplayName': 'n', prefix + 'AccountDescription': 'NoDrive', prefix + 'HostName': DRIVE, prefix + 'Port': 443,
                prefix + 'UseSSL': True, prefix + 'Username': 'citest', prefix + 'Password': '<redacted>',
                prefix + 'PrincipalURL': f'https://{DRIVE}/remote.php/dav/principals/users/citest/'}
    return {'PayloadType': 'Configuration', 'PayloadVersion': 1, 'PayloadIdentifier': 'a.b.x', 'PayloadUUID': 'u',
            'PayloadDisplayName': 'NoDrive Calendar & Contacts', 'PayloadOrganization': 'Nourax', 'PayloadDescription': 'd',
            'PayloadRemovalDisallowed': False,
            'PayloadContent': [payload('CalDAV', 'caldav'), payload('CardDAV', 'carddav')]}


def self_test():
    variants = ['v1', 'v2']
    problems, _ = check_log(_good_log(variants), variants)
    assert not problems, problems
    bad = 0

    def expect(mutate, letter):
        nonlocal bad
        events = _good_log(variants)
        mutate(events)
        found, _ = check_log(events, variants)
        assert any(p.startswith(letter + ':') for p in found), (letter, found)
        bad += 1

    expect(lambda ev: ev[0].update(host='evil.example.com'), 'a')
    expect(lambda ev: ev[0].update(user_agent='Mozilla'), 'b')
    expect(lambda ev: ev[0].update(has_authorization=True), 'b')
    expect(lambda ev: ev.pop(0), 'b')
    expect(lambda ev: ev.__delitem__(2), 'c')
    expect(lambda ev: ev.__setitem__(1, ev[4]) or ev.pop(2) and None, 'c')
    expect(lambda ev: [e for e in ev if e['event'] == 'device-apppassword-revoked'][0].update(has_authorization=False), 'd')
    expect(lambda ev: ev.remove([e for e in ev if e['event'] == 'device-apppassword-revoked'][0]), 'd')
    expect(lambda ev: ev.append({'event': 'device-apppassword-refused', 'host': DRIVE, 'user_agent': DEVICE_UA}), 'd')

    tmp = tempfile.mkdtemp()
    try:
        good = os.path.join(tmp, 'good.mobileconfig')
        with open(good, 'wb') as f:
            plistlib.dump(_good_profile(), f)
        problems, _ = check_profile(good, 'good', lint=False)
        assert not problems, problems

        def profile_expect(mutate, letter='e'):
            nonlocal bad
            profile = _good_profile()
            mutate(profile)
            path = os.path.join(tmp, f'bad{bad}.mobileconfig')
            with open(path, 'wb') as fh:
                plistlib.dump(profile, fh)
            found, _ = check_profile(path, 'bad', lint=False)
            assert found, 'a bad profile passed'
            bad += 1

        profile_expect(lambda p: p['PayloadContent'][0].update(CalDAVPassword='secret-value'))
        profile_expect(lambda p: p['PayloadContent'][1].update(CardDAVHostName='nextcloud.example.com'))
        profile_expect(lambda p: p.update(PayloadDisplayName='Nextcloud'))
        profile_expect(lambda p: p.update(PayloadRemovalDisallowed=True))
        profile_expect(lambda p: p['PayloadContent'].pop())
        profile_expect(lambda p: p['PayloadContent'][0].update(CalDAVPort=8443))
        profile_expect(lambda p: p.pop('PayloadOrganization'))
        found, _ = check_profile(os.path.join(tmp, 'missing'), 'missing', lint=False)
        assert found
        bad += 1
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    print(f'devicesync-check self-test: ok (good data passes, {bad} kinds of bad data are caught)')


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--log')
    ap.add_argument('--walk')
    ap.add_argument('--variants', nargs='+')
    ap.add_argument('--json')
    ap.add_argument('--self-test', action='store_true')
    args = ap.parse_args()
    if args.self_test:
        self_test()
        return
    if not (args.log and args.walk and args.variants):
        ap.error('give --log, --walk and --variants (or --self-test)')
    problems, facts = run(args.log, args.walk, args.variants)
    for variant, f in (facts.get('variants') or {}).items():
        for name, result in sorted((f.get('apple') or {}).items()):
            print(f'devicesync-check: {variant}: Apple screen {name}: {result}')
    if args.json:
        with open(args.json, 'w', encoding='utf-8') as fh:
            json.dump({'ok': not problems, 'problems': problems, 'facts': facts}, fh, indent=2, sort_keys=True)
    for p in problems:
        print('devicesync-check: PROBLEM:', p)
    if problems:
        sys.exit(1)
    print(f"devicesync-check: ok ({facts['starts']} sign-ins, {facts['grants']} grants, {facts['revocations']} revocation(s), "
          f"{len(args.variants)} variant(s))")


if __name__ == '__main__':
    main()
