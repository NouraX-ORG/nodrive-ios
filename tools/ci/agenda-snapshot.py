#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Nourax
# SPDX-License-Identifier: GPL-3.0-or-later
"""Records the real answers the app reads, per seeded user (CI only; the throwaway server on localhost).

The simulator job cannot reach this server (macOS runners have no Docker), so the stand-in (tools/ci/drive-stand-in.py
--agenda, tools/ci/agenda_stand_in.py) replays these answers. The requests are the app's own: the bodies come from the
AGENDA-BODY markers of iOSClient/NoAgenda/NCAgendaDAVXML.swift. The snapshot holds no password, cookie or token; it is
scanned for the seeded app passwords before it is written.
Output: <out>/agenda-snapshot.json
"""
import argparse
import datetime
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import agenda_common as c  # noqa: E402
import server_agenda_check as chk  # noqa: E402

GANTT = '/ocs/v2.php/apps/nc_gantt/api/v1/'
DECK = '/index.php/apps/deck/api/v1.0/'
SNAPSHOT_USERS = ['ali', 'mara', 'olaf']


def window(day):
    """The app's sync window: the first day of the previous month to 12 months after the current month starts."""
    first = day.replace(day=1)
    start = (first - datetime.timedelta(days=1)).replace(day=1)
    end = first.replace(year=first.year + 1)
    return c.ics_time(c.utc(start, 0)), c.ics_time(c.utc(end, 0))


def text_of(user, method, path, body=None, headers=None):
    status, hdrs, data = c.request_retry(user, method, path, body, headers)
    return {'status': status, 'text': data.decode('utf-8', 'replace'), 'etag': hdrs.get('etag')}


def json_of(user, path):
    status, _, data = c.request_retry(user, 'GET', path, None, {'Accept': 'application/json'})
    return {'status': status, 'text': data.decode('utf-8', 'replace')}


def record_user(user, day, bodies):
    out = {}
    out['cloud/user'] = json_of(user, '/ocs/v2.php/cloud/user?format=json')
    out['capabilities'] = json_of(user, '/ocs/v2.php/cloud/capabilities?format=json')
    xml = {'Depth': '0', 'Content-Type': 'application/xml'}
    out['principal'] = text_of(user, 'PROPFIND', '/remote.php/dav/principals/users/%s/' % user, bodies['principal'], xml)
    out['home'] = text_of(user, 'PROPFIND', '/remote.php/dav/calendars/%s/' % user, bodies['home'], dict(xml, Depth='1'))
    start, end = window(day)
    events = bodies['events'].replace('{{START}}', start).replace('{{END}}', end)
    reports = {}
    for uri in sorted(set(re.findall(r'/remote\.php/dav/calendars/%s/([^/<]+)/' % re.escape(user), out['home']['text']))):
        if uri in ('trashbin', 'inbox', 'outbox'):
            continue
        path = '/remote.php/dav/calendars/%s/%s/' % (user, uri)
        reports[uri] = {'events': text_of(user, 'REPORT', path, events, dict(xml, Depth='1')),
                        'todos': text_of(user, 'REPORT', path, bodies['todos'], dict(xml, Depth='1'))}
    out['reports'] = reports
    gantt = {}
    for name in ('my-tasks', 'projects', 'resources', 'settings', 'task-sync', 'capacity-check'):
        gantt[name] = json_of(user, GANTT + name + '?format=json')
    try:
        projects = json.loads(gantt['projects']['text'])['ocs']['data']
    except (ValueError, KeyError, TypeError):
        projects = []
    for p in projects if isinstance(projects, list) else []:
        for sub in ('tasks', 'milestones', 'subprojects', 'shares'):
            gantt['projects/%d/%s' % (p['id'], sub)] = json_of(user, GANTT + 'projects/%d/%s?format=json' % (p['id'], sub))
    out['gantt'] = gantt
    deck = {'boards': json_of(user, DECK + 'boards?details=true'), 'stacks': {}}
    try:
        boards = json.loads(deck['boards']['text'])
    except ValueError:
        boards = []
    for b in boards if isinstance(boards, list) else []:
        deck['stacks'][str(b['id'])] = json_of(user, DECK + 'boards/%d/stacks' % b['id'])
    out['deck'] = deck
    out['registry'] = text_of(user, 'GET', '/remote.php/dav/files/%s/NoAgenda/agent-registry.json' % user)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--out', default='build/agenda-server')
    args = ap.parse_args()
    day = c.seed_day()
    bodies = chk.swift_bodies()
    snapshot = {'version': 1, 'seed_day': day.isoformat(), 'users': {}}
    for user in SNAPSHOT_USERS:
        snapshot['users'][user] = record_user(user, day, bodies)
        print('recorded', user, 'calendars:', sorted(snapshot['users'][user]['reports']))
    text = json.dumps(snapshot, indent=1)
    if c.secrets_in(text) or 'Authorization' in text:
        sys.exit('agenda-snapshot: the snapshot holds a secret; not written')
    os.makedirs(args.out, exist_ok=True)
    with open(os.path.join(args.out, 'agenda-snapshot.json'), 'w') as fh:
        fh.write(text)
    print('agenda-snapshot: %d bytes' % len(text))


if __name__ == '__main__':
    main()
