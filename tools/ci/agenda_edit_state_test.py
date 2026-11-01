#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Nourax
# SPDX-License-Identifier: GPL-3.0-or-later
"""Self-test of the stand-in's writable state (tools/ci/agenda_edit_state.py): the rules it must keep, with made-up data.
CI runs it in the branding job. The job agenda-replay checks the same rules against the real server."""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import agenda_edit_state as s  # noqa: E402

ICS = 'BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:a\r\nSUMMARY:Dentist\r\nDTSTART:20261030T100000Z\r\nDTEND:20261030T110000Z\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n'
TODO = 'BEGIN:VCALENDAR\r\nBEGIN:VTODO\r\nUID:t\r\nSUMMARY:Draft\r\nEND:VTODO\r\nEND:VCALENDAR\r\n'
NS = 'xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav"'


def report(items):
    rows = ''.join('<d:response><d:href>%s</d:href><d:propstat><d:prop><d:getetag>%s</d:getetag><c:calendar-data>%s</c:calendar-data></d:prop>'
                   '<d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>' % (h, e, t.replace('&', '&amp;').replace('<', '&lt;'))
                   for h, e, t in items)
    return '<?xml version="1.0"?><d:multistatus %s>%s</d:multistatus>' % (NS, rows)


def ocs(data):
    return {'status': 200, 'text': json.dumps({'ocs': {'meta': {}, 'data': data}})}


def task(i, title, start, end, rows, deps=()):
    return {'id': i, 'project_id': 5, 'title': title, 'start_date': start, 'end_date': end, 'status': 'in_progress', 'updated_at': 'x',
            'dependencies': [{'predecessor_id': d} for d in deps], 'resources': rows}


def make(viewer=False, roles_only=False):
    tasks = [task(1, 'A', '2026-10-26 09:00:00', '2026-10-28 17:00:00', [{'resource_id': 1, 'work': 4}, {'resource_id': 10, 'work': None}]),
             task(2, 'B', '2026-10-29 09:00:00', '2026-10-30 17:00:00', [{'resource_id': 1, 'work': 2}], deps=['t-1'])]
    board = {'id': 1, 'labels': [{'id': 7, 'title': 'W'}], 'permissions': {'PERMISSION_MANAGE': False}}
    card = {'id': 21, 'title': 'C', 'description': 'keep', 'type': 'plain', 'order': 1, 'duedate': '2026-10-30T12:00:00+00:00',
            'startdate': '2026-10-28T09:00:00+00:00', 'done': None, 'archived': False, 'lastModified': 5, 'labels': [], 'owner': {'uid': 'mara'}}
    data = {'reports': {'work': {'events': {'text': report([('/remote.php/dav/calendars/ali/work/a.ics', '"e1"', ICS)])},
                                 'todos': {'text': report([('/remote.php/dav/calendars/ali/work/t.ics', '"t1"', TODO)])}}},
            'gantt': {'my-tasks': ocs({'has_linked_resource': True, 'tasks': [{'id': 1, 'title': 'A'}, {'id': 2, 'title': 'B'}]}),
                      'projects': ocs([{'id': 5, 'owner_id': 'mara', 'permission': 'viewer' if viewer else 'editor', 'roles_only_assignment': roles_only}]),
                      'resources': ocs([{'id': 1, 'type': 'person'}, {'id': 10, 'type': 'person'}, {'id': 11, 'type': 'person'}]),
                      'projects/5/tasks': ocs(tasks)},
            'deck': {'boards': {'status': 200, 'text': json.dumps([board])},
                     'stacks': {'1': {'status': 200, 'text': json.dumps([{'id': 2, 'cards': [card]}])}}}}
    return s.EditState('ali', data)


def main():
    path = '/remote.php/dav/calendars/ali/work/a.ics'
    st = make()
    # CalDAV
    code, text, _, hdr = st.dispatch('GET', path, {}, b'', True)
    assert code == 200 and hdr['ETag'] == '"e1"' and 'Dentist' in text
    assert st.dispatch('PUT', path, {'If-Match': '"zz"'}, b'x', True)[0] == 412
    assert st.dispatch('PUT', path, {}, b'x', True)[0] == 400
    code, _, _, hdr = st.dispatch('PUT', path, {'If-Match': '"e1"'}, ICS.replace('Dentist', 'Moved').encode(), True)
    assert code == 204 and hdr['ETag'] != '"e1"'
    assert 'Moved' in st.dispatch('REPORT', '/remote.php/dav/calendars/ali/work/', {}, b'name="VEVENT"', True)[1]
    new = '/remote.php/dav/calendars/ali/work/n.ics'
    assert st.dispatch('PUT', new, {'If-None-Match': '*'}, ICS.encode(), True)[0] == 201
    assert st.dispatch('PUT', new, {'If-None-Match': '*'}, ICS.encode(), True)[0] == 412
    etag = st.dispatch('GET', new, {}, b'', True)[3]['ETag']
    assert st.dispatch('DELETE', new, {'If-Match': '"no"'}, b'', True)[0] == 412
    assert st.dispatch('DELETE', new, {'If-Match': etag}, b'', True)[0] == 204
    assert st.dispatch('GET', new, {}, b'', True)[0] == 404
    # a to-do that is completed leaves the to-do report
    todo = '/remote.php/dav/calendars/ali/work/t.ics'
    done = TODO.replace('END:VTODO', 'STATUS:COMPLETED\r\nCOMPLETED:20261030T100000Z\r\nEND:VTODO')
    assert st.dispatch('PUT', todo, {'If-Match': '"t1"'}, done.encode(), True)[0] == 204
    assert 'Draft' not in st.dispatch('REPORT', '/remote.php/dav/calendars/ali/work/', {}, b'name="VTODO"', True)[1]
    # touch: the version changes when the app reads the object to write it
    st = make()
    st.touch = True
    assert st.dispatch('GET', path, {}, b'', True)[3]['ETag'] != '"e1"'
    # NoGantt
    st = make()
    g = s.GANTT
    assert st.dispatch('PUT', g + 'tasks/1', {}, b'{}', False)[0] == 412
    body = json.dumps({'end_date': '2026-10-31 17:00:00', 'adjust_lag': True, 'deck_confirmed': False}).encode()
    code, text, _, _ = st.dispatch('PUT', g + 'tasks/1', {}, body, True)
    data = json.loads(text)['ocs']['data']
    assert code == 200 and [p['title'] for p in data['propagated']] == ['B'] and data['op_id'].startswith('op-')
    tasks = json.loads(st.dispatch('GET', g + 'projects/5/tasks', {}, b'', True)[1])['ocs']['data']
    assert tasks[1]['start_date'].startswith('2026-11-02')   # the next working day after Saturday the 31st
    assert st.dispatch('POST', g + 'changes/%s/revert' % data['op_id'], {}, b'{}', True)[0] == 200
    tasks = json.loads(st.dispatch('GET', g + 'projects/5/tasks', {}, b'', True)[1])['ocs']['data']
    assert tasks[1]['start_date'].startswith('2026-10-29') and tasks[0]['end_date'].startswith('2026-10-28')
    rows = lambda *ids: json.dumps({'resources': [{'resource_id': i, 'work': None} for i in ids]}).encode()  # noqa: E731
    assert st.dispatch('PUT', g + 'tasks/1', {}, rows(1, 10, 11, 1, 10), True)[0] == 400
    code, text, _, _ = st.dispatch('PUT', g + 'tasks/1', {}, rows(1, 99), True)
    assert code == 200 and [r['resource_id'] for r in json.loads(text)['ocs']['data']['task']['resources']] == [1]   # 99 is dropped silently
    assert make(viewer=True).dispatch('PUT', g + 'tasks/1', {}, b'{}', True)[0] == 403
    assert make(roles_only=True).dispatch('PUT', g + 'tasks/1', {}, rows(1, 11), True)[0] == 400
    mine = json.loads(st.dispatch('GET', g + 'my-tasks', {}, b'', True)[1])['ocs']['data']['tasks']
    assert len(mine) == 2
    st.dispatch('PUT', g + 'tasks/2', {}, json.dumps({'status': 'done'}).encode(), True)
    assert len(json.loads(st.dispatch('GET', g + 'my-tasks', {}, b'', True)[1])['ocs']['data']['tasks']) == 1
    # Deck: a full replace clears what is not sent
    st = make()
    d = s.DECK
    card = d + 'boards/1/stacks/2/cards/21'
    assert st.dispatch('PUT', card, {}, json.dumps({'title': 'C2'}).encode(), True)[0] == 400
    code, text, _, _ = st.dispatch('PUT', card, {}, json.dumps({'title': 'C2', 'owner': 'mara'}).encode(), True)
    out = json.loads(text)
    assert code == 200 and out['description'] == '' and out['startdate'] is None and out['duedate'] is None
    boolean = json.dumps({'title': 'C3', 'owner': 'mara', 'done': True}).encode()
    assert st.dispatch('PUT', card, {}, boolean, True)[0] == 500   # the real Deck: done is a date, a boolean is an error
    full = json.dumps({'title': 'C3', 'owner': 'mara', 'description': 'keep', 'startdate': 'S', 'duedate': 'D', 'done': '2026-10-30T10:00:00+00:00'}).encode()
    out = json.loads(st.dispatch('PUT', card, {}, full, True)[1])
    assert out['description'] == 'keep' and out['startdate'] == 'S' and out['done'] and out['lastModified'] > 5
    assert st.dispatch('PUT', card + '/assignLabel', {}, json.dumps({'labelId': 7}).encode(), True)[0] == 200
    assert [x['id'] for x in json.loads(st.dispatch('GET', card, {}, b'', True)[1])['labels']] == [7]
    assert st.dispatch('PUT', card + '/removeLabel', {}, json.dumps({'labelId': 7}).encode(), True)[0] == 200
    assert json.loads(st.dispatch('GET', card, {}, b'', True)[1])['labels'] == []
    assert st.dispatch('POST', d + 'boards/1/labels', {}, json.dumps({'title': 'N'}).encode(), True)[0] == 403
    print('agenda_edit_state_test: ok')


if __name__ == '__main__':
    main()
