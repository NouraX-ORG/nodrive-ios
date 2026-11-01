# SPDX-FileCopyrightText: 2026 Nourax
# SPDX-License-Identifier: GPL-3.0-or-later
"""The writable state of the NoAgenda stand-in (CI only; Python standard library only).

The stand-in (tools/ci/agenda_stand_in.py) answers the app from the real server's recorded answers
(tools/ci/agenda-snapshot.py). For the editing step it must also take writes. This module keeps the recorded answers of
one user as a small state and applies the writes with the rules of the real server code that the CI job
"agenda-replay" measured:

  CalDAV   GET an object with its ETag; PUT with If-Match (412 on another version) or If-None-Match: * (412 when the
           name exists); DELETE with If-Match; a REPORT answers from the objects (to-dos without COMPLETED).
  NoGantt  PUT tasks/{id}: viewers get 403; more than 4 resources 400 too_many_resources; a new person in a roles-only
           project 400 roles_only_assignment; a resource that is not visible is dropped silently; dates move the tasks that
           depend on it ("propagated"); POST changes/{op}/revert puts them back.
  Deck     the card update is a full replace (a field that is not sent is cleared: description, startdate, duedate, done);
           assignLabel, removeLabel, and a new label only where the user may manage the board.

It is pure (no sockets): tools/ci/agenda-replay.py uses it too, to check that it answers like the real server.
Modes for the state screenshots: "touch" bumps the version of an object when the app reads it to write it (the item
"changed somewhere else"), "offline-all" is handled by the caller (the connection is dropped).
"""
import copy
import datetime
import hashlib
import json
import re
import xml.etree.ElementTree as ET
from xml.sax.saxutils import escape

DAV = '{DAV:}'
CALDAV = '{urn:ietf:params:xml:ns:caldav}'
GANTT = '/ocs/v2.php/apps/nc_gantt/api/v1/'
DECK = '/index.php/apps/deck/api/v1.0/'
NS = ('xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav" xmlns:cs="http://calendarserver.org/ns/" '
      'xmlns:a="http://apple.com/ns/ical/" xmlns:oc="http://owncloud.org/ns" xmlns:nc="http://nextcloud.org/ns"')


def _ocs(data, status=200, message='OK'):
    return {'ocs': {'meta': {'status': 'ok' if status == 200 else 'failure', 'statuscode': status, 'message': message}, 'data': data}}


def _now():
    return datetime.datetime.now(datetime.timezone.utc)


def _stamp():
    return _now().strftime('%Y-%m-%d %H:%M:%S')


class EditState:
    def __init__(self, user, data):
        self.user = user
        self.data = data
        self.touch = False
        self.touched = set()
        self.counter = 0
        self.dirty_calendars = set()
        self.objects = {}            # calendar uri -> {href: {'etag', 'ics'}}
        self.ops = {}
        self.gantt = {}              # path key -> parsed JSON ('projects/N/tasks', 'my-tasks', ...)
        self.gantt_dirty = set()
        self.deck_stacks = {}        # board id -> list of stacks (with cards)
        self.deck_dirty = set()
        self.boards = None
        self.boards_dirty = False
        self._parse_calendars()

    # ----------------------------------------------------------------------------------------- helpers
    def _next(self):
        self.counter += 1
        return self.counter

    def _etag(self, text):
        return '"' + hashlib.sha1((text + str(self._next())).encode()).hexdigest()[:20] + '"'

    @staticmethod
    def _json(entry):
        try:
            return json.loads(entry['text'])
        except (ValueError, KeyError, TypeError):
            return None

    # ----------------------------------------------------------------------------------------- CalDAV
    def _parse_calendars(self):
        for uri, reports in (self.data.get('reports') or {}).items():
            objs = {}
            for kind in ('events', 'todos'):
                try:
                    root = ET.fromstring(reports[kind]['text'])
                except (ET.ParseError, KeyError):
                    continue
                for response in root.iter(DAV + 'response'):
                    href = (response.findtext(DAV + 'href') or '').strip()
                    etag = None
                    ics = None
                    for prop in response.iter(DAV + 'prop'):
                        etag = prop.findtext(DAV + 'getetag') or etag
                        ics = prop.findtext(CALDAV + 'calendar-data') or ics
                    if href and ics:
                        objs[href] = {'etag': etag, 'ics': ics}
            self.objects[uri] = objs

    def _find_object(self, path):
        for uri, objs in self.objects.items():
            if path in objs:
                return uri, objs[path]
        return None, None

    def _calendar_uri_of(self, path):
        m = re.match(r'^/remote\.php/dav/calendars/[^/]+/([^/]+)/[^/]+\.ics$', path)
        return m.group(1) if m else None

    def report(self, uri, kind):
        """The REPORT answer of one calendar; the recorded text while nothing changed."""
        reports = (self.data.get('reports') or {}).get(uri)
        if reports is None:
            return None
        if uri not in self.dirty_calendars:
            return reports[kind]['text']
        parts = ['<?xml version="1.0"?><d:multistatus %s>' % NS]
        for href, obj in self.objects.get(uri, {}).items():
            is_todo = 'BEGIN:VTODO' in obj['ics']
            if (kind == 'todos') != is_todo:
                continue
            if is_todo and re.search(r'^(COMPLETED:|STATUS:COMPLETED)', obj['ics'], re.M):
                continue
            parts.append('<d:response><d:href>%s</d:href><d:propstat><d:prop><d:getetag>%s</d:getetag>'
                         '<c:calendar-data>%s</c:calendar-data></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>'
                         % (escape(href), escape(obj['etag'] or ''), escape(obj['ics'])))
        parts.append('</d:multistatus>')
        return ''.join(parts)

    def calendar_object(self, method, path, headers, body):
        uri = self._calendar_uri_of(path)
        if uri is None or uri not in self.objects:
            return 404, '', 'text/plain', {}
        objs = self.objects[uri]
        text = body.decode('utf-8', 'replace') if body else ''
        if method == 'GET':
            obj = objs.get(path)
            if obj is None:
                return 404, '', 'text/plain', {}
            if self.touch and path not in self.touched:
                # The item "changed somewhere else" between the app's read and its write.
                self.touched.add(path)
                obj['etag'] = self._etag(obj['ics'])
                self.dirty_calendars.add(uri)
            return 200, obj['ics'], 'text/calendar; charset=utf-8', {'ETag': obj['etag']}
        if method == 'PUT':
            existing = objs.get(path)
            if headers.get('If-None-Match') == '*':
                if existing is not None:
                    return 412, '', 'text/plain', {}
            elif headers.get('If-Match') is not None:
                if existing is None or existing['etag'] != headers.get('If-Match'):
                    return 412, '', 'text/plain', {}
            else:
                return 400, '', 'text/plain', {}
            etag = self._etag(text)
            objs[path] = {'etag': etag, 'ics': text}
            self.dirty_calendars.add(uri)
            return (204 if existing else 201), '', 'text/plain', {'ETag': etag}
        if method == 'DELETE':
            existing = objs.get(path)
            if existing is None:
                return 404, '', 'text/plain', {}
            if headers.get('If-Match') != existing['etag']:
                return 412, '', 'text/plain', {}
            del objs[path]
            self.dirty_calendars.add(uri)
            return 204, '', 'text/plain', {}
        return 405, '', 'text/plain', {}

    # ----------------------------------------------------------------------------------------- NoGantt
    def _gantt_json(self, key):
        if key not in self.gantt:
            entry = (self.data.get('gantt') or {}).get(key)
            parsed = self._json(entry) if entry else None
            self.gantt[key] = parsed
        return self.gantt[key]

    def gantt_get(self, key):
        """The recorded answer, or the changed one. None when there is no recorded answer."""
        entry = (self.data.get('gantt') or {}).get(key)
        if entry is None:
            return None
        if key in self.gantt_dirty:
            return entry['status'], json.dumps(self.gantt[key]), 'application/json; charset=utf-8', {}
        return entry['status'], entry['text'], 'application/json; charset=utf-8', {}

    def _tasks_of(self, pid):
        parsed = self._gantt_json('projects/%d/tasks' % pid)
        return parsed['ocs']['data'] if parsed else []

    def _projects(self):
        parsed = self._gantt_json('projects')
        return parsed['ocs']['data'] if parsed else []

    def _find_task(self, task_id):
        for project in self._projects():
            for task in self._tasks_of(project['id']):
                if task['id'] == task_id:
                    return project, task
        return None, None

    @staticmethod
    def _date(text):
        return datetime.datetime.strptime(text[:10], '%Y-%m-%d').date()

    def _set_dates(self, task, start=None, end=None):
        for key, value in (('start_date', start), ('end_date', end)):
            if value:
                task[key] = value

    def _touch_my_tasks(self, task):
        mine = self._gantt_json('my-tasks')
        if not mine:
            return
        rows = mine['ocs']['data'].get('tasks', [])
        for row in list(rows):
            if row['id'] == task['id']:
                for key in ('start_date', 'end_date', 'manual_progress', 'status'):
                    if key in task:
                        row[key] = task[key]
                if task.get('status') == 'done':
                    rows.remove(row)
        self.gantt_dirty.add('my-tasks')

    def gantt_write(self, method, path, body):
        rest = path[len(GANTT):]
        m = re.match(r'^tasks/(\d+)$', rest)
        if method == 'PUT' and m:
            return self._gantt_put(int(m.group(1)), body)
        m = re.match(r'^changes/([^/]+)/revert$', rest)
        if method == 'POST' and m:
            return self._gantt_revert(m.group(1))
        return None

    def _gantt_put(self, task_id, body):
        project, task = self._find_task(task_id)
        if task is None:
            return 404, json.dumps(_ocs([], 404, 'not found')), 'application/json', {}
        if project.get('permission') == 'viewer' and project.get('owner_id') != self.user:
            return 403, json.dumps(_ocs([], 403, 'forbidden')), 'application/json', {}
        try:
            payload = json.loads(body.decode('utf-8') or '{}')
        except ValueError:
            return 400, json.dumps(_ocs([], 400, 'invalid_json')), 'application/json', {}
        before = [copy.deepcopy(task)]
        propagated = []
        if 'resources' in payload:
            rows = payload['resources'] or []
            if len(rows) > 4:
                return 400, json.dumps(_ocs([], 400, 'too_many_resources')), 'application/json', {}
            visible = {r['id'] for r in (self._gantt_json('resources') or {}).get('ocs', {}).get('data', [])}
            current = {r['resource_id'] for r in task.get('resources', [])}
            known = {r['id']: r for r in (self._gantt_json('resources') or {}).get('ocs', {}).get('data', [])}
            result = []
            for index, row in enumerate(rows):
                rid = row.get('resource_id')
                if rid not in visible:
                    continue   # dropped silently, like the real server
                if project.get('roles_only_assignment') and rid not in current and known.get(rid, {}).get('type') == 'person':
                    return 400, json.dumps(_ocs([], 400, 'roles_only_assignment')), 'application/json', {}
                result.append({'id': 9000 + self._next(), 'task_id': task_id, 'resource_id': rid, 'work': row.get('work'), 'sort_order': index})
            task['resources'] = result
        old_end = task.get('end_date')
        self._set_dates(task, payload.get('start_date'), payload.get('end_date'))
        if payload.get('end_date') and old_end and self._date(payload['end_date']) > self._date(old_end) and payload.get('adjust_lag'):
            new_end = self._date(payload['end_date'])
            for other in self._tasks_of(project['id']):
                if any(dep.get('predecessor_id') == 't-%d' % task_id for dep in other.get('dependencies', [])):
                    start = self._date(other['start_date'])
                    if start < new_end:
                        before.append(copy.deepcopy(other))
                        delta = datetime.timedelta(days=(new_end - start).days)
                        for key in ('start_date', 'end_date'):
                            other[key] = (self._date(other[key]) + delta).isoformat() + other[key][10:]
                        other['updated_at'] = _stamp()
                        propagated.append({'id': other['id'], 'title': other['title']})
        for key in ('manual_progress', 'progress_mode', 'status'):
            if key in payload:
                task[key] = payload[key]
        task['updated_at'] = _stamp()
        op = 'op-%d' % self._next()
        self.ops[op] = (project['id'], before)
        self.gantt_dirty.add('projects/%d/tasks' % project['id'])
        self._touch_my_tasks(task)
        data = {'task': task, 'propagated': propagated, 'op_id': op, 'deck': None}
        return 200, json.dumps(_ocs(data)), 'application/json; charset=utf-8', {}

    def _gantt_revert(self, op):
        entry = self.ops.pop(op, None)
        if entry is None:
            return 404, json.dumps(_ocs([], 404, 'unknown change')), 'application/json', {}
        pid, before = entry
        tasks = self._tasks_of(pid)
        for old in before:
            for index, task in enumerate(tasks):
                if task['id'] == old['id']:
                    old['updated_at'] = _stamp()
                    tasks[index] = old
                    self._touch_my_tasks(old)
        self.gantt_dirty.add('projects/%d/tasks' % pid)
        return 200, json.dumps(_ocs({'reverted': True})), 'application/json; charset=utf-8', {}

    # ----------------------------------------------------------------------------------------- Deck
    def _stacks(self, board):
        key = str(board)
        if key not in self.deck_stacks:
            entry = ((self.data.get('deck') or {}).get('stacks') or {}).get(key)
            parsed = self._json(entry) if entry else None
            self.deck_stacks[key] = parsed
        return self.deck_stacks[key]

    def _boards(self):
        if self.boards is None:
            self.boards = self._json((self.data.get('deck') or {}).get('boards') or {}) or []
        return self.boards

    def _find_card(self, board, stack, card):
        for s in self._stacks(board) or []:
            if s.get('id') == stack:
                for c in s.get('cards') or []:
                    if c.get('id') == card:
                        return s, c
        return None, None

    def deck_get(self, rest):
        if rest == 'boards':
            entry = (self.data.get('deck') or {}).get('boards')
            if entry and self.boards_dirty:
                return entry['status'], json.dumps(self._boards()), 'application/json; charset=utf-8', {}
            return (entry['status'], entry['text'], 'application/json; charset=utf-8', {}) if entry else None
        m = re.match(r'^boards/(\d+)/stacks$', rest)
        if m:
            entry = ((self.data.get('deck') or {}).get('stacks') or {}).get(m.group(1))
            if not entry:
                return None
            if m.group(1) in self.deck_dirty:
                return entry['status'], json.dumps(self._stacks(m.group(1))), 'application/json; charset=utf-8', {}
            return entry['status'], entry['text'], 'application/json; charset=utf-8', {}
        m = re.match(r'^boards/(\d+)$', rest)
        if m:
            for board in self._boards():
                if board['id'] == int(m.group(1)):
                    return 200, json.dumps(board), 'application/json; charset=utf-8', {}
            return 404, json.dumps({'message': 'not found'}), 'application/json', {}
        m = re.match(r'^boards/(\d+)/stacks/(\d+)/cards/(\d+)$', rest)
        if m:
            board, stack, card = (int(x) for x in m.groups())
            _, found = self._find_card(board, stack, card)
            if found is None:
                return 404, json.dumps({'message': 'not found'}), 'application/json', {}
            if self.touch and ('card', card) not in self.touched:
                self.touched.add(('card', card))
                found['lastModified'] = int(found.get('lastModified') or 0) + 1000
                self.deck_dirty.add(str(board))
            return 200, json.dumps(found), 'application/json; charset=utf-8', {}
        return None

    def deck_write(self, method, rest, body):
        try:
            payload = json.loads(body.decode('utf-8') or '{}')
        except ValueError:
            return 400, json.dumps({'message': 'invalid json'}), 'application/json', {}
        m = re.match(r'^boards/(\d+)/labels$', rest)
        if method == 'POST' and m:
            board = int(m.group(1))
            for b in self._boards():
                if b['id'] == board:
                    if not (b.get('permissions') or {}).get('PERMISSION_MANAGE'):
                        return 403, json.dumps({'message': 'forbidden'}), 'application/json', {}
                    next_id = max([l['id'] for bb in self._boards() for l in bb.get('labels', [])] + [0]) + 1
                    label = {'id': next_id, 'title': payload.get('title', ''), 'color': payload.get('color', ''), 'boardId': board}
                    b.setdefault('labels', []).append(label)
                    self.boards_dirty = True
                    return 200, json.dumps(label), 'application/json; charset=utf-8', {}
            return 404, json.dumps({'message': 'not found'}), 'application/json', {}
        m = re.match(r'^boards/(\d+)/stacks/(\d+)/cards/(\d+)(/assignLabel|/removeLabel)?$', rest)
        if method == 'PUT' and m:
            board, stack, card = (int(x) for x in m.groups()[:3])
            _, found = self._find_card(board, stack, card)
            if found is None:
                return 404, json.dumps({'message': 'not found'}), 'application/json', {}
            action = m.group(4)
            if action:
                if action == '/assignLabel':
                    label = next((l for b in self._boards() if b['id'] == board for l in b.get('labels', []) if l['id'] == payload.get('labelId')), None)
                    if label is None:
                        return 404, json.dumps({'message': 'label not found'}), 'application/json', {}
                    if not any(x['id'] == label['id'] for x in found.get('labels', [])):
                        found.setdefault('labels', []).append(dict(label))
                else:
                    found['labels'] = [x for x in found.get('labels', []) if x['id'] != payload.get('labelId')]
                found['lastModified'] = int(found.get('lastModified') or 0) + 1
                self.deck_dirty.add(str(board))
                return 200, json.dumps([]), 'application/json; charset=utf-8', {}
            if 'title' not in payload or 'owner' not in payload:
                return 400, json.dumps({'message': 'title and owner are needed'}), 'application/json', {}
            # A full replace: what is not sent is cleared
            found['title'] = payload['title']
            found['type'] = payload.get('type') or 'plain'
            found['owner'] = {'primaryKey': payload['owner'], 'uid': payload['owner'], 'displayname': payload['owner'], 'type': 0}
            found['description'] = payload.get('description') or ''
            found['order'] = payload.get('order') or 0
            found['duedate'] = payload.get('duedate')
            found['startdate'] = payload.get('startdate')
            found['archived'] = bool(payload.get('archived'))
            done = payload.get('done')
            found['done'] = (_now().isoformat() if done is True else (done if isinstance(done, str) else None))
            if 'color' in payload:
                found['color'] = payload['color']
            found['lastModified'] = int(found.get('lastModified') or 0) + 1
            self.deck_dirty.add(str(board))
            return 200, json.dumps(found), 'application/json; charset=utf-8', {}
        return None

    # ----------------------------------------------------------------------------------------- entry
    def dispatch(self, method, path, headers, body, ocs_header):
        """(status, text, content type, headers) for a request that this state answers; None for the rest."""
        if path.startswith('/remote.php/dav/calendars/'):
            if method == 'REPORT':
                uri = path.rstrip('/').split('/')[-1]
                kind = 'todos' if b'name="VTODO"' in body else 'events'
                text = self.report(uri, kind)
                return None if text is None else (207, text, 'application/xml; charset=utf-8', {})
            if path.endswith('.ics') and method in ('GET', 'PUT', 'DELETE'):
                return self.calendar_object(method, path, headers, body)
            return None
        if path.startswith(GANTT):
            if not ocs_header:
                return 412, json.dumps({'message': 'CSRF check failed'}), 'application/json', {}
            rest = path[len(GANTT):]
            if method == 'GET':
                return self.gantt_get(rest)
            return self.gantt_write(method, path, body)
        if path.startswith(DECK):
            if not ocs_header:
                return 412, json.dumps({'message': 'CSRF check failed'}), 'application/json', {}
            rest = path[len(DECK):]
            if method == 'GET':
                return self.deck_get(rest)
            return self.deck_write(method, rest, body)
        return None
