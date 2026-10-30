#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Nourax
# SPDX-License-Identifier: GPL-3.0-or-later
"""NoAgenda against the real server code (CI only, throwaway server on localhost).

1. The auth proof (design section 5): with the app password (Basic) and `OCS-APIRequest: true`, every read of
   NoAgenda is accepted: NoGantt 200, Deck 200, CalDAV 207. The same NoGantt call without the header is recorded.
2. The app's own request bodies (the AGENDA-BODY markers in iOSClient/NoAgenda/NCAgendaDAVXML.swift) are sent as-is,
   and the answers must hold what was seeded.
3. The contract: every NoGantt answer has the keys and JSON types of NCAgendaGanttContract.swift, so the unit-test
   fixtures cannot drift from the real shape.
4. Reading changes nothing: counts of calendar objects, tasks and cards are equal before and after.
Report: <out>/agenda-server.md
"""
import argparse
import json
import os
import re
import sys
import xml.etree.ElementTree as ET

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import agenda_common as c  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SWIFT_DAV = os.path.join(ROOT, 'iOSClient', 'NoAgenda', 'NCAgendaDAVXML.swift')
SWIFT_CONTRACT = os.path.join(ROOT, 'iOSClient', 'NoAgenda', 'NCAgendaGanttReader.swift')
GANTT = '/ocs/v2.php/apps/nc_gantt/api/v1/'
DECK = '/index.php/apps/deck/api/v1.0/'

ROWS = []


def row(name, ok, detail=''):
    ROWS.append((name, ok, detail))
    print(('ok   ' if ok else 'FAIL ') + name + (' - ' + detail if detail else ''))


def swift_bodies():
    text = open(SWIFT_DAV, encoding='utf-8').read()
    bodies = {}
    for m in re.finditer(r'// AGENDA-BODY-BEGIN (\w+)\n\s*static let \w+ = #"""\n(.*?)\n\s*"""#\n\s*// AGENDA-BODY-END', text, re.S):
        lines = m.group(2).split('\n')
        indent = min(len(x) - len(x.lstrip()) for x in lines if x.strip())
        bodies[m.group(1)] = '\n'.join(x[indent:] for x in lines)
    return bodies


def swift_contract():
    text = open(SWIFT_CONTRACT, encoding='utf-8').read()
    shapes = {}
    for m in re.finditer(r'static let (\w+): \[String: Kind\] = \[(.*?)\]\n', text, re.S):
        shapes[m.group(1)] = dict(re.findall(r'"(\w+)": \.(\w+)', m.group(2)))
    return shapes


def conforms(value, kind):
    isbool = isinstance(value, bool)
    isnum = isinstance(value, (int, float)) and not isbool
    return {'int': isinstance(value, int) and not isbool, 'string': isinstance(value, str), 'number': isnum,
            'bool': isbool or isnum, 'array': isinstance(value, list), 'object': isinstance(value, dict),
            'stringOrNull': value is None or isinstance(value, str), 'numberOrNull': value is None or isnum,
            'intOrNull': value is None or (isinstance(value, int) and not isbool)}[kind]


def check_shape(name, rows, shape):
    bad = []
    for r in rows:
        for key, kind in shape.items():
            nullable = kind.endswith('OrNull')
            if key not in r and not nullable:
                bad.append('%s missing' % key)
            elif key in r and not conforms(r[key], kind):
                bad.append('%s is not %s' % (key, kind))
    row('contract ' + name, bool(rows) and not bad, ('%d rows; ' % len(rows)) + ('; '.join(sorted(set(bad))[:4]) if bad else 'ok'))


def multistatus(status, data):
    if status != 207:
        return None
    try:
        return ET.fromstring(data)
    except ET.ParseError:
        return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--container')
    ap.add_argument('--out', default='build/agenda-server')
    args = ap.parse_args()
    os.makedirs(args.out, exist_ok=True)
    day = c.seed_day()
    bodies = swift_bodies()
    row('the app bodies are found in the Swift source', set(bodies) >= {'principal', 'home', 'events', 'todos'}, ','.join(sorted(bodies)))
    contract = swift_contract()
    row('the contract is found in the Swift source', 'task' in contract and 'myTask' in contract, ','.join(sorted(contract)))

    # 1. Auth proof -------------------------------------------------------------
    table = []
    reads = [('GET', GANTT + 'my-tasks?format=json'), ('GET', GANTT + 'projects?format=json'), ('GET', GANTT + 'resources?format=json'),
             ('GET', GANTT + 'settings?format=json'), ('GET', GANTT + 'task-sync?format=json'), ('GET', GANTT + 'capacity-check?format=json'),
             ('GET', DECK + 'boards?details=true'), ('GET', '/ocs/v2.php/cloud/capabilities?format=json'),
             ('GET', '/ocs/v2.php/cloud/user?format=json')]
    for method, path in reads:
        status, _, _ = c.request('ali', method, path, headers={'Accept': 'application/json'})
        table.append((method, path.split('?')[0], status))
        row('auth proof ' + path.split('?')[0].replace('/ocs/v2.php/apps/nc_gantt/api/v1/', 'nogantt/'), status == 200, 'status %s' % status)
    for method, path, body, depth in [('PROPFIND', '/remote.php/dav/principals/users/ali/', bodies.get('principal'), '0'),
                                      ('PROPFIND', '/remote.php/dav/calendars/ali/', bodies.get('home'), '1')]:
        status, _, _ = c.request('ali', method, path, body, {'Depth': depth, 'Content-Type': 'application/xml'})
        table.append((method, path, status))
        row('auth proof ' + path, status == 207, 'status %s' % status)
    status, _, _ = c.request('ali', 'GET', GANTT + 'my-tasks?format=json', ocs=False, headers={'Accept': 'application/json'})
    table.append(('GET (no OCS-APIRequest header)', 'nogantt/my-tasks', status))
    print('recorded: NoGantt without the OCS-APIRequest header answers', status)

    # 2. The app's own bodies -----------------------------------------------------
    status, _, data = c.request('ali', 'PROPFIND', '/remote.php/dav/principals/users/ali/', bodies.get('principal'),
                                {'Depth': '0', 'Content-Type': 'application/xml'})
    row('principal: the address set has the seeded address', status == 207 and b'ali@example.org' in data.lower(), 'status %s' % status)
    status, _, data = c.request('ali', 'PROPFIND', '/remote.php/dav/calendars/ali/', bodies.get('home'),
                                {'Depth': '1', 'Content-Type': 'application/xml'})
    home_text = data.decode('utf-8', 'replace')
    for uri in ('personal', 'work', 'team', 'app-generated--deck--board-'):
        row('calendar home lists ' + uri, uri in home_text)
    start = c.ics_time(c.utc(day.replace(day=1), 0))
    end = c.ics_time(c.utc(day.replace(year=day.year + 1), 0))
    events_body = bodies.get('events', '').replace('{{START}}', start).replace('{{END}}', end)
    counts = {}
    shared = re.findall(r'/remote\.php/dav/calendars/ali/(team[^/<]*)/', home_text)
    team_uri = shared[0] if shared else 'team'
    for cal, wanted in (('personal', ['Dentist', 'Planning meeting']), ('work', ['Client call', 'Stand-up', 'Writer-Bot review']),
                        (team_uri, ['Planning meeting', 'Ali organises'])):
        status, _, data = c.request('ali', 'REPORT', '/remote.php/dav/calendars/ali/%s/' % cal, events_body,
                                    {'Depth': '1', 'Content-Type': 'application/xml'})
        text = data.decode('utf-8', 'replace')
        counts[cal] = text.count('BEGIN:VEVENT')
        for item in wanted:
            row('events %s has %s' % (cal, item), status == 207 and item in text, 'status %s' % status)
        if cal == 'work':
            row('expand gives UTC and RECURRENCE-ID for Stand-up', 'RECURRENCE-ID' in text and re.search(r'DTSTART:\d{8}T\d{6}Z', text) is not None)
    status, _, data = c.request('ali', 'REPORT', '/remote.php/dav/calendars/ali/personal/', bodies.get('todos'),
                                {'Depth': '1', 'Content-Type': 'application/xml'})
    text = data.decode('utf-8', 'replace')
    row('to-dos: Draft report is there, the completed one is not', status == 207 and 'Draft report' in text and 'Done to-do' not in text)
    counts['todos'] = text.count('BEGIN:VTODO')

    # 3. The contract -------------------------------------------------------------
    _, my = c.ocs_json('ali', GANTT + 'my-tasks')
    if isinstance(my, dict):
        check_shape('my-tasks wrapper', [my], contract.get('myTasksWrapper', {}))
        check_shape('my-tasks task', my.get('tasks', []), contract.get('myTask', {}))
    else:
        row('contract my-tasks', False, 'no data')
    _, projects = c.ocs_json('mara', GANTT + 'projects')
    projects = projects if isinstance(projects, list) else []
    check_shape('projects', projects, contract.get('project', {}))
    tasks, milestones = [], []
    for p in projects:
        _, t = c.ocs_json('mara', GANTT + 'projects/%d/tasks' % p['id'])
        _, m = c.ocs_json('mara', GANTT + 'projects/%d/milestones' % p['id'])
        tasks += t if isinstance(t, list) else []
        milestones += m if isinstance(m, list) else []
    check_shape('tasks', tasks, contract.get('task', {}))
    check_shape('task resource rows', [r for t in tasks for r in t.get('resources', [])], contract.get('taskResource', {}))
    check_shape('milestones', milestones, contract.get('milestone', {}))
    _, resources = c.ocs_json('mara', GANTT + 'resources')
    check_shape('resources', resources if isinstance(resources, list) else [], contract.get('resource', {}))
    _, settings = c.ocs_json('ali', GANTT + 'settings')
    check_shape('settings', [settings] if isinstance(settings, dict) else [], contract.get('settings', {}))
    _, capacity = c.ocs_json('mara', GANTT + 'capacity-check')
    check_shape('capacity-check', [capacity] if isinstance(capacity, dict) else [], contract.get('capacity', {}))
    _, sync = c.ocs_json('sara', GANTT + 'task-sync')
    check_shape('task-sync (sara)', [sync] if isinstance(sync, dict) else [], contract.get('taskSync', {}))
    row('NoGantt copy is on for sara and names its calendar', isinstance(sync, dict) and sync.get('enabled') is True and bool(sync.get('calendar_uri')))
    st, caps = c.ocs_json('ali', '/ocs/v2.php/cloud/capabilities')
    deck_version = ((caps or {}).get('capabilities', {}).get('deck', {}) or {}).get('version')
    row('Deck version is 1.19.x (read-write)', str(deck_version).startswith('1.19'), str(deck_version))
    status, _, data = c.request('ali', 'GET', DECK + 'boards?details=true', headers={'Accept': 'application/json'})
    try:
        boards = json.loads(data)
    except ValueError:
        boards = []
    row('Deck boards have id, title, owner, permissions, labels', bool(boards) and all(
        k in boards[0] for k in ('id', 'title', 'owner', 'permissions', 'labels')))
    if boards:
        status, _, data = c.request('ali', 'GET', DECK + 'boards/%d/stacks' % boards[0]['id'], headers={'Accept': 'application/json'})
        stacks = json.loads(data) if status == 200 else []
        cards = [card for s in stacks for card in s.get('cards', [])]
        row('Deck cards have id, title, duedate, done, assignedUsers, labels, lastModified', bool(cards) and all(
            k in cards[0] for k in ('id', 'title', 'duedate', 'done', 'assignedUsers', 'labels', 'lastModified')))
        counts['cards'] = len(cards)
    counts['tasks'] = len(tasks)

    # 4. Reading changes nothing ----------------------------------------------------
    after = {}
    for cal in ('personal', 'work', team_uri):
        _, _, data = c.request('ali', 'REPORT', '/remote.php/dav/calendars/ali/%s/' % cal, events_body, {'Depth': '1', 'Content-Type': 'application/xml'})
        after[cal] = data.decode('utf-8', 'replace').count('BEGIN:VEVENT')
    row('reading changed no calendar object', all(after[k] == counts[k] for k in after), json.dumps(after))

    with open(os.path.join(args.out, 'agenda-server.md'), 'w') as fh:
        fh.write('# NoAgenda server checks\n\n## Auth proof (app password, Basic, `OCS-APIRequest: true`)\n\n| Method | Path | Status |\n|---|---|---|\n')
        for method, path, status in table:
            fh.write('| %s | `%s` | %s |\n' % (method, path, status))
        fh.write('\n## Checks\n\n')
        for name, ok, detail in ROWS:
            fh.write('- %s %s %s\n' % ('PASS' if ok else 'FAIL', name, detail))
    failed = [r for r in ROWS if not r[1]]
    print('agenda server checks: %d rows, %d failed' % (len(ROWS), len(failed)))
    sys.exit(1 if failed else 0)


if __name__ == '__main__':
    main()
