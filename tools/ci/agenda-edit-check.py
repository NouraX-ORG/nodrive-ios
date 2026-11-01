#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Nourax
# SPDX-License-Identifier: GPL-3.0-or-later
"""Reads the stand-in's log of the NoAgenda editing runs and checks what the app wrote (CI only).

  1. only drive.nourax.org was asked, and every NoAgenda request had the OCS-APIRequest header;
  2. every write is one of the writes of design section 9, and nothing else:
       CalDAV   PUT of an .ics object with If-Match (edit) or If-None-Match: * (new), DELETE of an .ics object with If-Match;
       NoGantt  PUT tasks/<id>, POST changes/<id>/revert (Undo); never a DELETE;
       Deck     PUT of a card, assignLabel, removeLabel, POST of a label; never a DELETE;
       nothing is written to the files of the account (WebDAV files), and the Deck calendar is never asked;
  3. the runs did write: an edit with If-Match, a new object with If-None-Match, a NoGantt task, and a Deck card or label
     is not required here (the unit tests and the replay job cover Deck);
  4. connections that were dropped on purpose (the offline run) are the only requests without an answer.
  python3 tools/ci/agenda-edit-check.py <stand-in-edit.jsonl> [--self-test]
"""
import json
import re
import sys

WRITE_METHODS = {'PUT', 'POST', 'DELETE'}
ICS = re.compile(r'^/remote\.php/dav/calendars/[^/]+/[^/]+/[^/]+\.ics$')
GANTT_PUT = re.compile(r'^/ocs/v2\.php/apps/nc_gantt/api/v1/tasks/\d+$')
GANTT_REVERT = re.compile(r'^/ocs/v2\.php/apps/nc_gantt/api/v1/changes/[^/]+/revert$')
DECK_CARD = re.compile(r'^/index\.php/apps/deck/api/v1\.0/boards/\d+/stacks/\d+/cards/\d+(/assignLabel|/removeLabel)?$')
DECK_LABEL = re.compile(r'^/index\.php/apps/deck/api/v1\.0/boards/\d+/labels$')


def check(lines):
    entries = [json.loads(x) for x in lines if x.strip()]
    agenda = [e for e in entries if e.get('agenda')]
    problems = []
    if not agenda:
        problems.append('no NoAgenda request in the stand-in log')
    seen = {'edit': False, 'create': False, 'gantt': False}
    for e in agenda:
        host = (e.get('host') or '').split(':')[0].lower()
        if host != 'drive.nourax.org':
            problems.append('a request went to %r: %s %s' % (host, e.get('method'), e.get('path')))
        if not e.get('ocs_header'):
            problems.append('no OCS-APIRequest header: %s %s' % (e.get('method'), e.get('path')))
    for e in entries:
        method, path = e.get('method'), str(e.get('path', ''))
        if '/remote.php/dav/calendars/' in path and 'app-generated' in path:
            problems.append('the Deck calendar was read: %s' % path)
        if method not in WRITE_METHODS:
            continue
        if path.startswith(('/__ci/', '/index.php/login', '/login')) or path == '/ocs/v2.php/core/apppassword':
            continue
        if not (e.get('agenda') or path.startswith(('/remote.php/dav/', '/ocs/v2.php/apps/nc_gantt', '/index.php/apps/deck'))):
            continue
        status = e.get('status')
        if path.startswith('/remote.php/dav/files/'):
            problems.append('a write to the account files: %s %s' % (method, path))
        elif ICS.match(path):
            if method == 'PUT':
                if e.get('if_none_match') == '*':
                    seen['create'] = seen['create'] or status in (200, 201, 204)
                elif e.get('if_match'):
                    seen['edit'] = seen['edit'] or status in (200, 201, 204)
                else:
                    problems.append('a calendar PUT without If-Match and without If-None-Match: %s' % path)
            elif method == 'DELETE':
                if not e.get('if_match'):
                    problems.append('a calendar DELETE without If-Match: %s' % path)
            else:
                problems.append('a %s on a calendar object: %s' % (method, path))
        elif GANTT_PUT.match(path) and method == 'PUT':
            seen['gantt'] = seen['gantt'] or status in (200, 201)
        elif GANTT_REVERT.match(path) and method == 'POST':
            pass
        elif DECK_CARD.match(path) and method == 'PUT':
            pass
        elif DECK_LABEL.match(path) and method == 'POST':
            pass
        else:
            problems.append('a write that is not one of design section 9: %s %s' % (method, path))
    for name, text in (('edit', 'an edit with If-Match'), ('create', 'a new object with If-None-Match: *'), ('gantt', 'a NoGantt task')):
        if not seen[name]:
            problems.append('the runs never wrote ' + text)
    return problems


def self_test():
    base = {'agenda': True, 'host': 'drive.nourax.org', 'ocs_header': True, 'status': 204}
    good = [dict(base, method='PUT', path='/remote.php/dav/calendars/ali/work/a.ics', if_match=True),
            dict(base, method='PUT', path='/remote.php/dav/calendars/ali/work/b.ics', if_none_match='*', status=201),
            dict(base, method='PUT', path='/ocs/v2.php/apps/nc_gantt/api/v1/tasks/5', status=200),
            dict(base, method='DELETE', path='/remote.php/dav/calendars/ali/work/b.ics', if_match=True),
            dict(base, method='PUT', path='/index.php/apps/deck/api/v1.0/boards/1/stacks/2/cards/3/assignLabel', status=200)]
    assert check([json.dumps(x) for x in good]) == []

    def bad(entry, needle):
        found = check([json.dumps(x) for x in good + [entry]])
        assert any(needle in p for p in found), (needle, found)
    bad(dict(base, method='DELETE', path='/ocs/v2.php/apps/nc_gantt/api/v1/tasks/5'), 'not one of design section 9')
    bad(dict(base, method='DELETE', path='/index.php/apps/deck/api/v1.0/boards/1/stacks/2/cards/3'), 'not one of design section 9')
    bad(dict(base, method='PUT', path='/remote.php/dav/calendars/ali/work/c.ics'), 'without If-Match')
    bad(dict(base, method='DELETE', path='/remote.php/dav/calendars/ali/work/c.ics'), 'DELETE without If-Match')
    bad(dict(base, method='PUT', path='/remote.php/dav/files/ali/NoAgenda/agent-registry.json', if_match=True), 'account files')
    bad(dict(base, method='GET', path='/remote.php/dav/calendars/ali/app-generated--deck--board-1/x.ics'), 'Deck calendar')
    bad(dict(base, host='evil.example', method='GET', path='/x'), 'evil.example')
    bad(dict(base, ocs_header=False, method='GET', path='/x'), 'OCS-APIRequest')
    assert any('never wrote' in p for p in check([json.dumps(good[0])]))
    assert any('no NoAgenda request' in p for p in check([]))
    print('agenda-edit-check: self-test ok')


if __name__ == '__main__':
    if len(sys.argv) > 1 and sys.argv[1] == '--self-test':
        self_test()
        sys.exit(0)
    with open(sys.argv[1], encoding='utf-8') as fh:
        found = check(fh.readlines())
    for p in found:
        print('PROBLEM:', p)
    print('agenda-edit-check: %d problem(s)' % len(found))
    sys.exit(1 if found else 0)
