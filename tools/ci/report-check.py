#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Nourax
# SPDX-License-Identifier: GPL-3.0-or-later
"""Checks of the problem-report UI test (CI job "screens"), made on what the stand-in saw and kept.

  python3 tools/ci/report-check.py --log stand-in.jsonl --uploads DIR --variants reports-light reports-dark \
          [--walk DIR] [--json out.json]
  python3 tools/ci/report-check.py --self-test        the checks must fail on bad data

The stand-in (tools/ci/drive-stand-in.py --workspace --reports-uploads DIR) writes one JSON line per request (names and
facts only) and saves every uploaded zip under DIR/<variant>/NN-<name>.zip. A "reports-reset" event starts each run, so
the log is cut into one segment per variant. For every variant the checks are:

  a  every request of the run went to drive.nourax.org, with the account's credential, and to no other host
  b  MKCOL of "Problem reports" came before each upload; the first answered 201, later ones 405
  c  every upload was a PUT with `If-None-Match: *` and without an `Overwrite` header; no upload replaced a file
  d  per report: exactly one list of the folder's shares, and exactly one share POST when the list was empty and none
     when it was not; every POST carries shareType 0, permissions 1, shareWith nourax-support, path /Problem reports;
     two POSTs in the run (the first refused, the second accepted)
  e  four zips, in the order manual, manual, unclean-exit, crash; each at most 5,000,000 bytes, a valid zip, the name
     <YYYY-MM-DD_HH-MM-SS>_ios_<version>.zip, and the file name of the upload equals the zip's
  f  report.json at the root with the contract's fields and types; crash.txt only in the crash report and naming the
     exception; the first report's note had its email address replaced, its token removed and its file name kept; at
     least one report holds logs
  g  nothing in any zip holds the throwaway password, its Basic form, a session cookie value, or a Basic/Bearer value
"""
import argparse
import base64
import json
import os
import re
import sys
import tempfile
import zipfile

DRIVE = 'drive.nourax.org'
EXPECTED_KINDS = ['manual', 'manual', 'unclean-exit', 'crash']
MAX_ZIP = 5_000_000
NAME_RE = re.compile(r'^\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}_ios_[0-9A-Za-z.\-]+\.zip$')
FIELDS = ['schema', 'kind', 'app', 'app_version', 'build', 'platform', 'os_version', 'device_model', 'locale',
          'created_utc', 'server_host', 'user_note']
TOKEN = 'ABCDEFGHIJKLMNOPQRSTUVWXYZABCDEFGHIJKLMN'


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


def segments(events):
    """variant -> the events after its reports-reset event, up to the next reset."""
    result, current = {}, None
    for event in events:
        if event.get('event') == 'reports-reset':
            current = event.get('variant')
            result[current] = []
        elif current is not None:
            result[current].append(event)
    return result


def zip_files(uploads, variant):
    folder = os.path.join(uploads, variant)
    if not os.path.isdir(folder):
        return []
    return sorted(os.path.join(folder, n) for n in os.listdir(folder))


def check_variant(variant, events, uploads, user, password):
    problems, facts = [], {}

    def bad(text):
        problems.append(f'{variant}: {text}')

    # a  hosts and credential
    reportish = [e for e in events if str(e.get('event', '')).startswith('report-')]
    others = sorted({e.get('host', '') for e in events if e.get('host') and e.get('host') != DRIVE})
    if others:
        bad(f'requests went to another host: {others}')
    for e in reportish:
        if e.get('host') != DRIVE:
            bad(f'{e.get("event")} went to {e.get("host")}')
        if not e.get('has_authorization'):
            bad(f'{e.get("event")} carried no credential (it must use the account)')
    facts['report_events'] = len(reportish)

    # b, c  MKCOL and PUT
    mkcols = [e for e in events if e.get('event') == 'report-mkcol']
    uploads_ev = [e for e in events if e.get('event') == 'report-upload']
    facts['mkcol_statuses'] = [e.get('status') for e in mkcols]
    facts['uploads'] = [e.get('name') for e in uploads_ev]
    if not mkcols or mkcols[0].get('status') != 201:
        bad(f'the first MKCOL did not answer 201: {facts["mkcol_statuses"]}')
    if any(e.get('status') != 405 for e in mkcols[1:]):
        bad(f'a later MKCOL did not answer 405: {facts["mkcol_statuses"]}')
    seen_mkcol = False
    for e in events:
        if e.get('event') == 'report-mkcol':
            seen_mkcol = True
        elif e.get('event') in ('report-upload', 'report-upload-conflict', 'report-replaced'):
            if not seen_mkcol:
                bad(f'an upload came before MKCOL: {e.get("name")}')
            seen_mkcol = False
    for e in events:
        if e.get('event') in ('report-upload', 'report-upload-conflict', 'report-replaced'):
            if e.get('if_none_match') != '*':
                bad(f'upload {e.get("name")} had no If-None-Match: *')
            if e.get('overwrite_header'):
                bad(f'upload {e.get("name")} sent an Overwrite header')
    if any(e.get('event') == 'report-replaced' for e in events):
        bad('an upload replaced a file that was there')
    if len(uploads_ev) != len(EXPECTED_KINDS):
        bad(f'{len(uploads_ev)} uploads, expected {len(EXPECTED_KINDS)}')
    if len({e.get('name') for e in uploads_ev}) != len(uploads_ev):
        bad('two uploads share a name')

    # d  shares
    posts, groups, current = [], [], None
    for e in events:
        if e.get('event') == 'report-upload':
            current = {'name': e.get('name'), 'lists': [], 'posts': []}
            groups.append(current)
        elif current is not None and e.get('event') == 'report-share-list':
            current['lists'].append(e)
        elif current is not None and e.get('event') == 'report-share-post':
            current['posts'].append(e)
            posts.append(e)
    for g in groups:
        if len(g['lists']) != 1:
            bad(f'{g["name"]}: {len(g["lists"])} lists of the folder\'s shares, expected 1')
            continue
        listed = g['lists'][0].get('shares_listed', 0)
        wanted = 1 if listed == 0 else 0
        if len(g['posts']) != wanted:
            bad(f'{g["name"]}: {len(g["posts"])} share requests with {listed} share(s) listed, expected {wanted}')
    for p in posts:
        if (p.get('shareType'), p.get('permissions'), p.get('shareWith'), p.get('share_path')) != \
                ('0', '1', 'nourax-support', '/Problem reports'):
            bad(f'a share request had the wrong fields: {[p.get(k) for k in ("shareType", "permissions", "shareWith", "share_path")]}')
    facts['share_posts'] = [p.get('refused') for p in posts]
    if facts['share_posts'] != [True, False]:
        bad(f'share requests (refused?) {facts["share_posts"]}, expected [True, False]')

    # e, f, g  the zips
    files = zip_files(uploads, variant)
    facts['zips'] = [os.path.basename(f) for f in files]
    if len(files) != len(EXPECTED_KINDS):
        bad(f'{len(files)} zips saved, expected {len(EXPECTED_KINDS)}')
    kinds, log_entries = [], 0
    needles = []
    if password:
        needles = [password.encode(), base64.b64encode(f'{user}:{password}'.encode())]
    for index, path in enumerate(files):
        base = os.path.basename(path)
        original = base.split('-', 1)[1] if '-' in base else base
        if not NAME_RE.match(original):
            bad(f'{base}: the file name does not match the pattern')
        if index < len(uploads_ev) and uploads_ev[index].get('name') != original:
            bad(f'{base}: not the file the upload named ({uploads_ev[index].get("name")})')
        size = os.path.getsize(path)
        if size > MAX_ZIP:
            bad(f'{base}: {size} bytes, more than {MAX_ZIP}')
        try:
            zf = zipfile.ZipFile(path)
        except zipfile.BadZipFile:
            bad(f'{base}: not a zip file')
            continue
        with zf:
            if zf.testzip() is not None:
                bad(f'{base}: a damaged entry')
            names = zf.namelist()
            for n in names:
                if not (n in ('report.json', 'crash.txt') or (n.startswith('logs/') and len(n) > 5)):
                    bad(f'{base}: unexpected entry {n}')
            if 'report.json' not in names:
                bad(f'{base}: no report.json at the root')
                continue
            try:
                report = json.loads(zf.read('report.json'))
            except ValueError:
                bad(f'{base}: report.json is not JSON')
                continue
            if list(report.keys()) != FIELDS:
                bad(f'{base}: report.json fields/order {list(report.keys())}')
            if report.get('schema') != 1:
                bad(f'{base}: schema {report.get("schema")}')
            for key in FIELDS[1:]:
                if not isinstance(report.get(key), str):
                    bad(f'{base}: {key} is not a string')
            if report.get('app') != 'NoDrive iOS' or report.get('platform') != 'ios':
                bad(f'{base}: app/platform {report.get("app")}/{report.get("platform")}')
            if not str(report.get('created_utc', '')).endswith('Z'):
                bad(f'{base}: created_utc is not UTC with Z')
            if report.get('server_host') != DRIVE:
                bad(f'{base}: server_host {report.get("server_host")}')
            kind = report.get('kind')
            kinds.append(kind)
            has_crash = 'crash.txt' in names
            if has_crash != (kind == 'crash'):
                bad(f'{base}: crash.txt {"present" if has_crash else "missing"} for kind {kind}')
            if kind == 'crash' and has_crash and b'NoDriveUITestException' not in zf.read('crash.txt'):
                bad(f'{base}: crash.txt does not name the exception')
            log_entries += sum(1 for n in names if n.startswith('logs/'))
            if index == 0:
                note = str(report.get('user_note', ''))
                facts['first_note'] = note
                if not note:
                    bad(f'{base}: the note is empty (the UI test typed one)')
                if '@example.com' in note or 'jane.doe' in note and '<email>' not in note:
                    bad(f'{base}: the email address was not replaced in the note')
                if TOKEN in note:
                    bad(f'{base}: the token is still in the note')
                if 'IMG_0001.HEIC' not in note:
                    bad(f'{base}: the file name was not kept in the note')
                facts['note_has_email_placeholder'] = '<email>' in note
            for n in names:
                data = zf.read(n)
                for needle in needles:
                    if needle in data:
                        bad(f'{base}/{n}: holds the throwaway password (or its Basic form)')
                text = data.decode('utf-8', 'replace')
                if re.search(r'(oc_sessionPassphrase|nc_session_id)=[^<\s;"\']', text):
                    bad(f'{base}/{n}: a session cookie value')
                if re.search(r'Authorization:?\s*"?Basic\s+[A-Za-z0-9+/=]{8,}', text):
                    bad(f'{base}/{n}: an Authorization value')
                if re.search(r'Bearer\s+[A-Za-z0-9._~+/=-]{8,}', text):
                    bad(f'{base}/{n}: a Bearer value')
    facts['kinds'] = kinds
    if kinds != EXPECTED_KINDS:
        bad(f'kinds {kinds}, expected {EXPECTED_KINDS}')
    facts['log_entries'] = log_entries
    if files and log_entries == 0:
        bad('no zip holds a logs/ entry')
    return problems, facts


def self_test():
    """The checks must pass on good data and fail on every kind of bad data."""
    failures = []
    password = 'sekret0123456789abcdef0123456789'
    with tempfile.TemporaryDirectory() as tmp:
        def make_zip(path, kind, note='', crash=False, extra=None, log='line\n', pad=0):
            with zipfile.ZipFile(path, 'w', zipfile.ZIP_DEFLATED) as zf:
                report = dict(zip(FIELDS, [1, kind, 'NoDrive iOS', '35.2.1-nourax.1', '7', 'ios', '27.0', 'iPhone17,1',
                                           'en_US', '2026-10-28T11:44:03Z', DRIVE, note]))
                zf.writestr('report.json', json.dumps(report))
                if crash:
                    zf.writestr('crash.txt', 'Name: NoDriveUITestException\n')
                if log is not None:
                    zf.writestr('logs/log.txt', log)
                for n, data in (extra or {}).items():
                    zf.writestr(n, data)
                if pad:
                    zf.writestr('logs/pad.bin', os.urandom(pad))

        def build(name, mutate=None):
            uploads = os.path.join(tmp, name)
            os.makedirs(os.path.join(uploads, 'v'))
            names = ['2026-10-28_11-44-0%d_ios_35.2.1-nourax.1.zip' % i for i in range(4)]
            events = [{'event': 'reports-reset', 'variant': 'v'}]
            note = 'Photos/Holiday 2026/IMG_0001.HEIC froze <email> Bearer <removed>'
            for i, kind in enumerate(EXPECTED_KINDS):
                events.append({'event': 'report-mkcol', 'status': 201 if i == 0 else 405, 'host': DRIVE, 'has_authorization': True})
                events.append({'event': 'report-upload', 'name': names[i], 'size': 100, 'if_none_match': '*',
                               'overwrite_header': False, 'host': DRIVE, 'has_authorization': True, 'status': 201})
                listed = 0 if i < 2 else 1
                events.append({'event': 'report-share-list', 'shares_listed': listed, 'host': DRIVE, 'has_authorization': True})
                if i < 2:
                    events.append({'event': 'report-share-post', 'shareType': '0', 'permissions': '1',
                                   'shareWith': 'nourax-support', 'share_path': '/Problem reports', 'refused': i == 0,
                                   'host': DRIVE, 'has_authorization': True})
                make_zip(os.path.join(uploads, 'v', f'{i + 1:02d}-{names[i]}'), kind, note if i == 0 else '', crash=kind == 'crash')
            if mutate:
                mutate(events, uploads, names)
            return events, uploads

        def run(name, mutate=None):
            events, uploads = build(name, mutate)
            return check_variant('v', events[1:], uploads, 'citest', password)[0]

        if run('good'):
            failures.append(f'good data was rejected: {run("good2")}')

        def expect_bad(label, mutate):
            if not run(label, mutate):
                failures.append(f'bad data was accepted: {label}')

        def drop_header(events, *_):
            next(e for e in events if e.get('event') == 'report-upload')['if_none_match'] = None
        expect_bad('no If-None-Match', drop_header)

        def replaced(events, *_):
            events.append({'event': 'report-replaced', 'name': 'x', 'if_none_match': '*', 'host': DRIVE, 'has_authorization': True})
        expect_bad('a replaced file', replaced)

        def other_host(events, *_):
            events.append({'event': 'report-upload', 'name': 'y', 'if_none_match': '*', 'host': 'example.org', 'has_authorization': True})
        expect_bad('another host', other_host)

        def extra_post(events, *_):
            events.append({'event': 'report-upload', 'name': 'z', 'if_none_match': '*', 'host': DRIVE, 'has_authorization': True})
            events.append({'event': 'report-share-list', 'shares_listed': 1, 'host': DRIVE, 'has_authorization': True})
            events.append({'event': 'report-share-post', 'shareType': '0', 'permissions': '1', 'shareWith': 'nourax-support',
                           'share_path': '/Problem reports', 'refused': False, 'host': DRIVE, 'has_authorization': True})
        expect_bad('a share request although shared', extra_post)

        def wrong_share(events, *_):
            next(e for e in events if e.get('event') == 'report-share-post')['permissions'] = '31'
        expect_bad('wrong permissions', wrong_share)

        def no_credential(events, *_):
            next(e for e in events if e.get('event') == 'report-upload')['has_authorization'] = False
        expect_bad('no credential', no_credential)

        def secret_in_zip(events, uploads, names):
            make_zip(os.path.join(uploads, 'v', f'01-{names[0]}'), 'manual', 'Photos IMG_0001.HEIC', log=f'x {password} y')
        expect_bad('the password in a zip', secret_in_zip)

        def cookie_in_zip(events, uploads, names):
            make_zip(os.path.join(uploads, 'v', f'02-{names[1]}'), 'manual', log='Cookie nc_session_id=abc123def')
        expect_bad('a session cookie in a zip', cookie_in_zip)

        def wrong_order(events, uploads, names):
            make_zip(os.path.join(uploads, 'v', f'03-{names[2]}'), 'crash', crash=True)
        expect_bad('kinds out of order', wrong_order)

        def big_zip(events, uploads, names):
            make_zip(os.path.join(uploads, 'v', f'02-{names[1]}'), 'manual', pad=5_200_000)
        expect_bad('a zip over 5 MB', big_zip)

        def bad_name(events, uploads, names):
            os.rename(os.path.join(uploads, 'v', f'04-{names[3]}'), os.path.join(uploads, 'v', '04-report.zip'))
        expect_bad('a wrong file name', bad_name)

        def raw_note(events, uploads, names):
            make_zip(os.path.join(uploads, 'v', f'01-{names[0]}'), 'manual', 'mail jane.doe@example.com IMG_0001.HEIC')
        expect_bad('an email left in the note', raw_note)

        def no_logs(events, uploads, names):
            for i, kind in enumerate(EXPECTED_KINDS):
                make_zip(os.path.join(uploads, 'v', f'{i + 1:02d}-{names[i]}'), kind, 'Photos IMG_0001.HEIC' if i == 0 else '',
                         crash=kind == 'crash', log=None)
        expect_bad('no logs at all', no_logs)

        def crash_without_text(events, uploads, names):
            make_zip(os.path.join(uploads, 'v', f'04-{names[3]}'), 'crash', crash=False)
        expect_bad('a crash without crash.txt', crash_without_text)

        def no_mkcol(events, *_):
            events.remove(next(e for e in events if e.get('event') == 'report-mkcol'))
        expect_bad('no MKCOL', no_mkcol)

    for f in failures:
        print('SELF-TEST FAIL:', f)
    if failures:
        return 1
    print('report-check self-test: ok (good data passes, 15 kinds of bad data are caught)')
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--log')
    ap.add_argument('--uploads')
    ap.add_argument('--variants', nargs='+')
    ap.add_argument('--walk', help='folder with the UI test output (<variant>/walk.jsonl)')
    ap.add_argument('--json')
    ap.add_argument('--self-test', action='store_true')
    args = ap.parse_args()
    if args.self_test:
        sys.exit(self_test())
    if not (args.log and args.uploads and args.variants):
        ap.error('give --log, --uploads and --variants (or --self-test)')
    user = os.environ.get('NODRIVE_WS_USER', '')
    password = os.environ.get('NODRIVE_WS_APP_PASSWORD', '')
    if not password:
        print('report-check: NODRIVE_WS_APP_PASSWORD is not set')
        sys.exit(1)
    segs = segments(load_log(args.log))
    problems, all_facts = [], {}
    for variant in args.variants:
        if variant not in segs:
            problems.append(f'{variant}: no reports-reset event in the stand-in log (the run never started)')
            continue
        p, facts = check_variant(variant, segs[variant], args.uploads, user, password)
        problems.extend(p)
        if args.walk:
            walk = os.path.join(args.walk, variant, 'walk.jsonl')
            if os.path.exists(walk):
                steps = {}
                with open(walk, encoding='utf-8') as f:
                    for line in f:
                        try:
                            e = json.loads(line)
                        except ValueError:
                            continue
                        if str(e.get('step', '')).startswith(('banner-', 'question')):
                            steps[e['step']] = e.get('seen', e.get('buttons'))
                facts['ui'] = steps
                # Every banner the UI test looked for must have been seen.
                for step, seen in steps.items():
                    if step.startswith('banner-') and seen is not True:
                        problems.append(f'{variant}: the UI test did not see the banner "{step}"')
        all_facts[variant] = facts
        print(f'{variant}: {json.dumps(facts, ensure_ascii=False)}')
    if args.json:
        with open(args.json, 'w', encoding='utf-8') as f:
            json.dump({'ok': not problems, 'problems': problems, 'facts': all_facts}, f, indent=2, ensure_ascii=False)
    for p in problems:
        print('PROBLEM:', p)
    print('report-check: ok' if not problems else f'report-check: {len(problems)} problem(s)')
    sys.exit(1 if problems else 0)


if __name__ == '__main__':
    main()
