#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Nourax
# SPDX-License-Identifier: GPL-3.0-or-later
"""Reads the stand-in's log of the NoAgenda shard and checks what the app did (CI only).

  1. only drive.nourax.org was asked (the Host header of every agenda request);
  2. every NoAgenda request had the OCS-APIRequest header (the CSRF pass);
  3. no write method was used (the core step only reads): GET, PROPFIND and REPORT, plus the CI control path;
  4. no request went to the Deck calendar (the app reads Deck through its REST API);
  5. the app really read each home: calendars, NoGantt and NoBoard.
  python3 tools/ci/agenda-check.py <stand-in.jsonl> [--self-test]
"""
import json
import sys

READ_METHODS = {'GET', 'PROPFIND', 'REPORT', 'HEAD'}


def check(lines):
    entries = [json.loads(x) for x in lines if x.strip()]
    agenda = [e for e in entries if e.get('agenda')]
    problems = []
    if not agenda:
        problems.append('no NoAgenda request in the stand-in log')
    for e in agenda:
        host = (e.get('host') or '').split(':')[0].lower()
        if host != 'drive.nourax.org':
            problems.append('a request went to %r: %s %s' % (host, e.get('method'), e.get('path')))
        if not e.get('ocs_header'):
            problems.append('no OCS-APIRequest header: %s %s' % (e.get('method'), e.get('path')))
    for e in entries:
        if e.get('method') not in READ_METHODS and not str(e.get('path', '')).startswith(('/__ci/', '/index.php/login', '/login')) \
                and e.get('path') not in ('/ocs/v2.php/core/apppassword',):
            if e.get('agenda') or str(e.get('path', '')).startswith(('/remote.php/dav/', '/ocs/v2.php/apps/nc_gantt', '/index.php/apps/deck')):
                problems.append('a write method on a NoAgenda path: %s %s' % (e.get('method'), e.get('path')))
        if '/remote.php/dav/calendars/' in str(e.get('path', '')) and 'app-generated' in str(e.get('path', '')):
            problems.append('the Deck calendar was read: %s' % e.get('path'))
    paths = ' '.join(str(e.get('path')) for e in agenda)
    for name, needle in (('calendars', '/remote.php/dav/calendars/'), ('NoGantt', '/apps/nc_gantt/'), ('NoBoard', '/apps/deck/api/')):
        if needle not in paths:
            problems.append('the app never read ' + name)
    return problems


def self_test():
    good = [{'agenda': True, 'host': 'drive.nourax.org', 'ocs_header': True, 'method': 'PROPFIND', 'path': '/remote.php/dav/calendars/ali/'},
            {'agenda': True, 'host': 'drive.nourax.org', 'ocs_header': True, 'method': 'GET', 'path': '/ocs/v2.php/apps/nc_gantt/api/v1/my-tasks'},
            {'agenda': True, 'host': 'drive.nourax.org', 'ocs_header': True, 'method': 'GET', 'path': '/index.php/apps/deck/api/v1.0/boards'}]
    assert check([json.dumps(x) for x in good]) == []
    bad_host = good + [dict(good[0], host='evil.example')]
    assert any('evil.example' in p for p in check([json.dumps(x) for x in bad_host]))
    no_header = good + [dict(good[0], ocs_header=False)]
    assert any('OCS-APIRequest' in p for p in check([json.dumps(x) for x in no_header]))
    write = good + [dict(good[0], method='PUT', path='/remote.php/dav/calendars/ali/work/x.ics')]
    assert any('write method' in p for p in check([json.dumps(x) for x in write]))
    deck_cal = good + [dict(good[0], method='REPORT', path='/remote.php/dav/calendars/ali/app-generated--deck--board-1/')]
    assert any('Deck calendar' in p for p in check([json.dumps(x) for x in deck_cal]))
    assert any('no NoAgenda request' in p for p in check([]))
    print('agenda-check: self-test ok')


if __name__ == '__main__':
    if len(sys.argv) > 1 and sys.argv[1] == '--self-test':
        self_test()
        sys.exit(0)
    with open(sys.argv[1], encoding='utf-8') as fh:
        found = check(fh.readlines())
    for p in found:
        print('PROBLEM:', p)
    print('agenda-check: %d problem(s)' % len(found))
    sys.exit(1 if found else 0)
