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
  g  before any profile was built, the app asked who the new password belongs to: one GET ocs/v2.php/cloud/user per grant,
     with Basic auth of the new password and OCS-APIRequest, answered 200, right after the grant
  h  the loopback server's own records (devicesync-server.jsonl, written by the app's Debug hook: method, status and byte
     count only): per variant, whether Safari's request reached the server and got 200 with the profile. Always reported;
     with --require-safari-fetch (on once the simulator's Safari is known to fetch) a variant without a served profile fails
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
    identity = [e for e in device if e['event'] == 'device-identity-check']
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
    # g
    if len(identity) != len(grants):
        problems.append(f'g: {len(identity)} identity checks for {len(grants)} grants')
    for e in identity:
        if e.get('method') != 'GET' or e.get('path') != '/ocs/v2.php/cloud/user':
            problems.append(f"g: the identity check was {e.get('method')} {e.get('path')}")
        if not e.get('has_authorization') or not e.get('ocs_api_request'):
            problems.append('g: the identity check lacked its Basic header or OCS-APIRequest')
        if e.get('status') != 200:
            problems.append(f"g: the identity check was answered {e.get('status')}")
        if e.get('user_agent') != DEVICE_UA:
            problems.append(f"g: the identity check came with the user agent {e.get('user_agent')!r}")
    waiting = False
    for e in device:
        if e['event'] == 'device-grant':
            waiting = True
        elif e['event'] == 'device-identity-check':
            waiting = False
        elif e['event'] in ('device-flow-start', 'device-apppassword-revoked') and waiting:
            problems.append('g: a grant was not followed by its identity check')
            waiting = False
    return problems, {'starts': len(starts), 'pages': len(pages), 'polls': len(polls), 'grants': len(grants),
                      'revocations': len(revoked), 'identity_checks': len(identity)}


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


def check_server_records(records, label, require_fetch=False):
    """The loopback server's records of one variant (two sign-ins): did Safari's request reach it, was the profile served?"""
    problems = []
    listening = [r for r in records if r.get('event') == 'profile-server-listening']
    requests = [r for r in records if r.get('event') == 'profile-request']
    served = [r for r in records if r.get('event') == 'profile-served']
    ok = [r for r in requests if r.get('status') == 200]
    facts = {'listening': len(listening), 'requests': len(requests), 'requests_200': len(ok), 'served': len(served),
             'methods': sorted({str(r.get('method')) for r in requests}), 'bytes': [r.get('count') for r in served]}
    if not records:
        problems.append(f'h: {label}: the app wrote no records of the loopback server (the Debug hook did not run)')
        return problems, facts
    if not listening:
        problems.append(f'h: {label}: the loopback server never reported that it listens')
    if len(ok) != len(served):
        problems.append(f'h: {label}: {len(ok)} requests answered 200 but {len(served)} profile-served records')
    for r in served:
        if not isinstance(r.get('count'), int) or r['count'] <= 0:
            problems.append(f"h: {label}: a served profile had the byte count {r.get('count')!r}")
    for r in requests:
        if set(r) - {'event', 'method', 'status', 't'}:
            problems.append(f'h: {label}: a request record holds more than the method and the status')
    if require_fetch and not served:
        problems.append(f'h: {label}: Safari never fetched the profile from the loopback server '
                        f'(listening {len(listening)}, requests {len(requests)})')
    return problems, facts


def check_variant(walk, variant, lint=True, require_fetch=False):
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
    p, f = check_server_records(read_records(os.path.join(folder, 'devicesync-server.jsonl')), variant, require_fetch)
    problems += p
    facts['loopback'] = f
    try:
        with open(os.path.join(folder, 'apple-screens.json'), encoding='utf-8') as fh:
            facts['apple'] = json.load(fh)
    except (OSError, ValueError):
        facts['apple'] = {}
    return problems, facts


def run(log, walk, variants, lint=True, require_fetch=False):
    events = load_log(log)
    problems, facts = check_log(events, variants)
    per_variant = {}
    for variant in variants:
        p, f = check_variant(walk, variant, lint, require_fetch)
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
                {'event': 'device-identity-check', 'method': 'GET', 'path': '/ocs/v2.php/cloud/user', 'host': DRIVE,
                 'user_agent': ua, 'has_authorization': True, 'ocs_api_request': True, 'status': 200},
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

    def identity(ev):
        return [e for e in ev if e['event'] == 'device-identity-check']

    expect(lambda ev: ev[0].update(host='evil.example.com'), 'a')
    expect(lambda ev: ev.remove(identity(ev)[0]), 'g')
    expect(lambda ev: identity(ev)[0].update(ocs_api_request=False), 'g')
    expect(lambda ev: identity(ev)[0].update(status=401), 'g')
    expect(lambda ev: identity(ev)[0].update(path='/ocs/v2.php/cloud/users/ali'), 'g')
    expect(lambda ev: ev[0].update(user_agent='Mozilla'), 'b')
    expect(lambda ev: ev[0].update(has_authorization=True), 'b')
    expect(lambda ev: ev.pop(0), 'b')
    expect(lambda ev: ev.__delitem__(2), 'c')
    expect(lambda ev: ev.__setitem__(1, ev[4]) or ev.pop(2) and None, 'c')
    expect(lambda ev: [e for e in ev if e['event'] == 'device-apppassword-revoked'][0].update(has_authorization=False), 'd')
    expect(lambda ev: ev.remove([e for e in ev if e['event'] == 'device-apppassword-revoked'][0]), 'd')
    expect(lambda ev: ev.append({'event': 'device-apppassword-refused', 'host': DRIVE, 'user_agent': DEVICE_UA}), 'd')

    good_records = [{'event': 'profile-server-listening'}, {'event': 'profile-request', 'method': 'GET', 'status': 200},
                    {'event': 'profile-served', 'count': 1500}, {'event': 'profile-server-closed'}]
    found, facts = check_server_records(good_records, 'good', require_fetch=True)
    assert not found and facts['served'] == 1, found
    quiet = [r for r in good_records if r['event'] not in ('profile-request', 'profile-served')]
    for records, require, what in (
            ([], False, 'no records'),
            ([r for r in good_records if r['event'] != 'profile-server-listening'], False, 'never listened'),
            ([r for r in good_records if r['event'] != 'profile-served'], False, 'a 200 without a served record'),
            ([dict(r, count=0) if r['event'] == 'profile-served' else r for r in good_records], False, 'a served profile of 0 bytes'),
            ([dict(r, path='/x') if r['event'] == 'profile-request' else r for r in good_records], False, 'a path in a request record'),
            (quiet, True, 'Safari never fetched')):
        found, _ = check_server_records(records, 'bad', require_fetch=require)
        assert any(p.startswith('h:') for p in found), what
        bad += 1
    found, _ = check_server_records(quiet, 'quiet')
    assert not found, 'a fetch that is not required is only reported'

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
    ap.add_argument('--require-safari-fetch', action='store_true',
                    help='a variant in which Safari never fetched the profile from the loopback server fails')
    ap.add_argument('--self-test', action='store_true')
    args = ap.parse_args()
    if args.self_test:
        self_test()
        return
    if not (args.log and args.walk and args.variants):
        ap.error('give --log, --walk and --variants (or --self-test)')
    problems, facts = run(args.log, args.walk, args.variants, require_fetch=args.require_safari_fetch)
    for variant, f in (facts.get('variants') or {}).items():
        loop = f.get('loopback') or {}
        print(f"devicesync-check: {variant}: Safari's request reached the loopback server and the profile was served: "
              f"{'YES' if loop.get('served') else 'NO'} (listening {loop.get('listening', 0)}, requests {loop.get('requests', 0)}, "
              f"answered 200 {loop.get('requests_200', 0)}, profile bytes served {loop.get('bytes', [])})")
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
          f"{facts['identity_checks']} identity check(s), {len(args.variants)} variant(s))")


if __name__ == '__main__':
    main()
