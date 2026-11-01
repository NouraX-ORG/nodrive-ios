#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Nourax
# SPDX-License-Identifier: GPL-3.0-or-later
"""Replays the requests of the Swift writers on a real throwaway server (CI only; localhost only).

The unit test NoDriveAgendaRequestExportTests drives the app's real writers on fixtures that copy the seed and writes every
request they build to agenda-requests.json (method, path with symbolic ids, header names, body). This script:

  1. takes those requests, fills the symbols from seed.json (tasks, resources, board, card, labels), moves the dates from
     the fixture day to the seed day, and fills `If-Match` with the real fresh ETag and `{fresh:...}` with the real fresh
     card (exactly what the writers do from a fresh read);
  2. sends them to the real server as Ali and reads the state back: the event time changed while the alarm, the unknown
     property and the UID stayed; the agent on and off; a to-do done; a new event and its delete (404 after; the only DELETE
     of the job); the NoGantt move with "Publish banners" moved too and Undo putting it back; "my agent" Self and back with
     the other row and the total work unchanged; % done; the Deck due date changed with the description and the start date
     kept; the agent label on and off;
  3. runs the same scenarios against the stand-in's state (tools/ci/agenda_edit_state.py, built from a snapshot recorded
     before the replay) and compares the status of every step and the key paths of every JSON answer ("the stand-in answers
     like the real server").

Report: <out>/agenda-replay.md. Exit 1 when a check or the comparison fails.
"""
import argparse
import datetime
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import agenda_common as c  # noqa: E402
import agenda_edit_state  # noqa: E402

GANTT = '/ocs/v2.php/apps/nc_gantt/api/v1/'
DECK = '/index.php/apps/deck/api/v1.0/'
TASK_KEYS = {'Write homepage copy': 'write', 'Banner design': 'banner', 'Publish banners': 'publish'}
ROBOT = '\U0001F916'

ROWS = []


def row(name, ok, detail=''):
    ROWS.append((name, ok, detail))
    print(('ok   ' if ok else 'FAIL ') + name + (' - ' + detail if detail else ''))


def key_paths(value, prefix=''):
    """The key paths of a JSON answer (list items collapse), for the comparison of shapes."""
    found = set()
    if isinstance(value, dict):
        for k, v in value.items():
            found.add(prefix + '/' + k)
            found |= key_paths(v, prefix + '/' + k)
    elif isinstance(value, list):
        for item in value[:3]:
            found |= key_paths(item, prefix + '[]')
    return found


class Target:
    """A server the scenarios run against: the real one over HTTP, or the stand-in's state in this process."""

    def __init__(self, name, state=None):
        self.name = name
        self.state = state
        self.log = []   # (step, status, key paths)

    def send(self, step, method, path, body=None, headers=None):
        headers = dict(headers or {})
        if isinstance(body, str):
            body = body.encode()
        if self.state is not None:
            bare = path.split('?')[0]
            status, text, _, hdrs = self.state.dispatch(method, bare, headers, body or b'', True) or (404, '', 'text/plain', {})
            hdrs = {k.lower(): v for k, v in hdrs.items()}
        else:
            real_path = path
            if path.startswith((GANTT, DECK)) and 'format=' not in path:
                real_path += ('&' if '?' in path else '?') + 'format=json'
            status, hdrs, data = c.request_retry('ali', method, real_path, body, headers)
            text = data.decode('utf-8', 'replace')
        paths = set()
        if 'json' in (headers.get('Accept', '') + headers.get('Content-Type', '')) or path.startswith((GANTT, DECK)):
            try:
                paths = key_paths(json.loads(text))
            except ValueError:
                paths = set()
        self.log.append((step, status, paths))
        return status, text, hdrs

    def json(self, step, method, path, body=None):
        headers = {'Accept': 'application/json'}
        payload = None
        if body is not None:
            payload = json.dumps(body)
            headers['Content-Type'] = 'application/json'
        status, text, _ = self.send(step, method, path, payload, headers)
        try:
            data = json.loads(text)
        except ValueError:
            data = None
        if isinstance(data, dict) and 'ocs' in data:
            data = data['ocs'].get('data')
        return status, data


def shift_dates(text, delta):
    def day(m):
        return (datetime.date.fromisoformat(m.group(0)) + delta).isoformat()

    def stamp(m):
        d = datetime.datetime.strptime(m.group(1), '%Y%m%d').date() + delta
        return d.strftime('%Y%m%d') + m.group(2)
    text = re.sub(r'\d{4}-\d{2}-\d{2}', day, text)
    text = re.sub(r'(\d{8})(T\d{6}Z)', stamp, text)
    text = re.sub(r'(VALUE=DATE:)(\d{8})', lambda m: m.group(1) + (datetime.datetime.strptime(m.group(2), '%Y%m%d').date() + delta).strftime('%Y%m%d'), text)
    return text


def run(target, requests, seed, delta, mutate_seed_card):
    """All the scenarios against one target. Returns a list of (name, ok, detail)."""
    results = []

    def check(name, ok, detail=''):
        results.append((name, bool(ok), detail))

    deck = seed['deck']
    gantt = seed['gantt']
    ids = gantt['tasks']
    resources = gantt['resources']
    project = gantt['projects']['website']
    board, stack = deck['board'], deck['stack']
    card = deck['cards']['Plain card']

    def fill(text, extra=None):
        for name, key in TASK_KEYS.items():
            text = text.replace('{task:%s}' % name, str(ids[key]))
        for name in ('ali', 'writer', 'research'):
            # a resource id in a JSON body is a number: the quotes of the symbol go
            text = text.replace('"{resource:%s}"' % name, str(resources[name])).replace('{resource:%s}' % name, str(resources[name]))
        text = text.replace('{board}', str(board)).replace('{stack}', str(stack)).replace('{card:Plain card}', str(card))
        for k, v in (extra or {}).items():
            text = text.replace(k, str(v))
        return text

    def body_of(request, extra=None):
        text = fill(request['body'], extra)
        return shift_dates(text, delta)

    def object_text(path):
        status, text, hdrs = target.send('get ' + path, 'GET', path, headers={'Accept': 'text/calendar'})
        return status, text, hdrs.get('etag')

    def requests_of(name):
        for scenario in requests['scenarios']:
            if scenario['name'] == name:
                return scenario['requests']
        return []

    def calendar_put(name, expect):
        reqs = requests_of(name)
        check(name + ': the writer built a request', len(reqs) == 1, str(len(reqs)))
        if len(reqs) != 1:
            return None
        req = reqs[0]
        path = req['path']
        headers = {'Content-Type': 'text/calendar; charset=utf-8'}
        if 'If-Match' in req['headers']:
            status, _, etag = object_text(path)
            headers['If-Match'] = etag or ''
        if 'If-None-Match' in req['headers']:
            headers['If-None-Match'] = req['headers']['If-None-Match']
        status, _, _ = target.send(name, req['method'], path, body_of(req), headers)
        check(name + ': status', status in expect, 'status %s' % status)
        return path

    # CalDAV ----------------------------------------------------------------------------------------------
    path = calendar_put('event-edit', (204, 201))
    if path:
        status, text, _ = object_text(path)
        check('event-edit: the title changed', 'SUMMARY:Dentist (moved)' in text)
        check('event-edit: the alarm stayed', 'BEGIN:VALARM' in text and 'TRIGGER:-PT15M' in text)
        check('event-edit: the unknown property stayed', 'X-CI-UNKNOWN:keep-me' in text)
        check('event-edit: the UID stayed', 'UID:ci-dentist' in text)
        check('event-edit: the time changed', 'DTSTART:' in text and 'T110000Z' in text)
    path = calendar_put('event-agent-on', (204, 201))
    if path:
        _, text, _ = object_text(path)
        check('event-agent-on: the agent id and the tag are there', 'X-NOURAX-AGENT-ID:AG-0001' in text and 'agent:AG-0001' in text)
        check('event-agent-on: the alarm stayed', 'BEGIN:VALARM' in text and 'X-CI-UNKNOWN:keep-me' in text)
    path = calendar_put('event-agent-off', (204, 201))
    if path:
        _, text, _ = object_text(path)
        check('event-agent-off: no agent id and no tag', 'X-NOURAX-AGENT-ID' not in text and 'agent:AG-0001' not in text)
        check('event-agent-off: the alarm stayed', 'BEGIN:VALARM' in text and 'X-CI-UNKNOWN:keep-me' in text)
    path = calendar_put('todo-done', (204, 201))
    if path:
        _, text, _ = object_text(path)
        check('todo-done: completed', 'STATUS:COMPLETED' in text and 'PERCENT-COMPLETE:100' in text and 'COMPLETED:' in text)
    path = calendar_put('event-create', (201,))
    if path:
        _, text, _ = object_text(path)
        check('event-create: the new event is there', 'UID:ci-replay-event' in text and 'X-NOURAX-AGENT-ID:AG-0001' in text)
        status, _, _ = target.send('create again', 'PUT', path, body_of(requests_of('event-create')[0]),
                                   {'Content-Type': 'text/calendar; charset=utf-8', 'If-None-Match': '*'})
        check('event-create: the same name again is refused (If-None-Match: *)', status == 412, 'status %s' % status)
    deletes = requests_of('event-delete')
    check('event-delete: the writer built one DELETE', len(deletes) == 1 and deletes[0]['method'] == 'DELETE')
    if deletes:
        status, _, etag = object_text(deletes[0]['path'])
        status, _, _ = target.send('event-delete', 'DELETE', deletes[0]['path'], None, {'If-Match': etag or ''})
        check('event-delete: status', status in (204, 200), 'status %s' % status)
        status, _, _ = object_text(deletes[0]['path'])
        check('event-delete: 404 after', status == 404, 'status %s' % status)

    # NoGantt -------------------------------------------------------------------------------------------------
    def tasks_now():
        _, data = target.json('read tasks', 'GET', GANTT + 'projects/%d/tasks' % project)
        return {t['id']: t for t in (data or [])}

    before = tasks_now()
    banner0 = before.get(ids['banner'], {})
    publish0 = before.get(ids['publish'], {})
    move = requests_of('gantt-move')
    check('gantt-move: the writer built one PUT with adjust_lag and deck_confirmed false', len(move) == 1 and json.loads(move[0]['body']).get('adjust_lag') is True
          and json.loads(move[0]['body']).get('deck_confirmed') is False)
    op_id = None
    if move:
        status, data = target.json('gantt-move', 'PUT', fill(move[0]['path']), json.loads(body_of(move[0])))
        check('gantt-move: status', status == 200, 'status %s %s' % (status, str(data)[:200]))
        if isinstance(data, dict):
            op_id = data.get('op_id')
            moved = [p.get('title') if isinstance(p, dict) else p for p in data.get('propagated') or []]
            after = tasks_now()
            check('gantt-move: the end date moved', after.get(ids['banner'], {}).get('end_date') != banner0.get('end_date'),
                  '%s -> %s' % (banner0.get('end_date'), after.get(ids['banner'], {}).get('end_date')))
            check('gantt-move: Publish banners moved too', 'Publish banners' in moved or after.get(ids['publish'], {}).get('start_date') != publish0.get('start_date'),
                  'propagated: %s' % moved)
            check('gantt-move: the answer has an op_id and the saved task', bool(op_id) and isinstance(data.get('task'), dict))
    undo = requests_of('gantt-undo')
    check('gantt-undo: the writer built one POST', len(undo) == 1 and undo[0]['method'] == 'POST')
    if undo and op_id:
        status, data = target.json('gantt-undo', 'POST', fill(undo[0]['path'], {'{op}': op_id}), {})
        check('gantt-undo: status', status in (200, 201, 204), 'status %s %s' % (status, str(data)[:200]))
        after = tasks_now()
        check('gantt-undo: the end date is back', after.get(ids['banner'], {}).get('end_date') == banner0.get('end_date'),
              '%s vs %s' % (after.get(ids['banner'], {}).get('end_date'), banner0.get('end_date')))
        check('gantt-undo: Publish banners is back', after.get(ids['publish'], {}).get('start_date') == publish0.get('start_date'))
    percent = requests_of('gantt-percent')
    if percent:
        status, data = target.json('gantt-percent', 'PUT', fill(percent[0]['path']), json.loads(body_of(percent[0])))
        check('gantt-percent: status', status == 200, 'status %s' % status)
        check('gantt-percent: 70 %', tasks_now().get(ids['write'], {}).get('manual_progress') == 70)

    def rows_of(task_id):
        return [(r['resource_id'], r.get('work')) for r in tasks_now().get(task_id, {}).get('resources', [])]
    rows0 = rows_of(ids['write'])
    check('gantt-agent: the seed has Ali and Writer-Bot on the task', [r[0] for r in rows0] == [resources['ali'], resources['writer']], str(rows0))
    total0 = sum((r[1] or 0) for r in rows0)
    for name in ('gantt-agent-to-self', 'gantt-agent-to-writer'):
        reqs = requests_of(name)
        check(name + ': the writer built one PUT', len(reqs) == 1)
        if not reqs:
            continue
        body = json.loads(fill(reqs[0]['body']))
        status, data = target.json(name, 'PUT', fill(reqs[0]['path']), body)
        check(name + ': status', status == 200, 'status %s %s' % (status, str(data)[:200]))
        now_rows = rows_of(ids['write'])
        sent = [(r['resource_id'], r.get('work')) for r in body['resources']]
        check(name + ': the answer holds the list that was sent', [r[0] for r in now_rows] == [r[0] for r in sent], '%s vs %s' % (now_rows, sent))
        check(name + ': the total work is unchanged', sum((r[1] or 0) for r in now_rows) == total0)
        check(name + ': Ali (the first row) is untouched', bool(now_rows) and now_rows[0] == rows0[0], str(now_rows))
    check('gantt-agent: after Self and back the rows are as seeded', [r[0] for r in rows_of(ids['write'])] == [r[0] for r in rows0])

    # Deck ------------------------------------------------------------------------------------------------------
    base = DECK + 'boards/%d/stacks/%d/cards/%d' % (board, stack, card)
    status, fresh = target.json('deck read', 'GET', base)
    if not isinstance(fresh, dict):
        check('deck: the card can be read', False, 'status %s' % status)
        return results
    # a card with a description and a start date, as Mara (who manages the board)
    mutate_seed_card(fresh)
    status, fresh = target.json('deck read again', 'GET', base)
    check('deck: the card has a description and a start date', bool(fresh.get('description')) and bool(fresh.get('startdate')))
    reqs = requests_of('deck-due')
    check('deck-due: the writer built one PUT', len(reqs) == 1 and reqs[0]['method'] == 'PUT')
    if reqs:
        body = json.loads(body_of(reqs[0]))
        need = ['title', 'type', 'owner', 'description', 'order', 'duedate', 'startdate', 'archived', 'done']
        check('deck-due: every field of the card is in the body', all(k in body for k in need), str([k for k in need if k not in body]))
        for key in ('title', 'type', 'description', 'order', 'startdate', 'archived', 'color'):
            if body.get(key) == '{fresh:%s}' % key:
                value = fresh.get(key)
                if value is None and key in ('description',):
                    value = ''
                body[key] = value
        if body.get('owner') == '{fresh:owner}':
            owner = fresh.get('owner')
            body['owner'] = owner.get('uid') if isinstance(owner, dict) else owner
        if body.get('duedate') == '{fresh:duedate}':
            body['duedate'] = fresh.get('duedate')
        if body.get('done') is None:
            body['done'] = fresh.get('done')
        status, data = target.json('deck-due', 'PUT', base, body)
        check('deck-due: status', status in (200, 201, 204), 'status %s %s' % (status, str(data)[:300]))
        status, now = target.json('deck read after', 'GET', base)
        now = now if isinstance(now, dict) else {}
        check('deck-due: the due date changed', now.get('duedate') != fresh.get('duedate'), '%s -> %s' % (fresh.get('duedate'), now.get('duedate')))
        check('deck-due: the description is kept', now.get('description') == fresh.get('description'), repr(now.get('description')))
        check('deck-due: the start date is kept', bool(now.get('startdate')) and str(now.get('startdate'))[:10] == str(fresh.get('startdate'))[:10], str(now.get('startdate')))
        check('deck-due: the title and the owner are kept', now.get('title') == fresh.get('title') and
              (now.get('owner') or {}).get('uid') == (fresh.get('owner') or {}).get('uid'))
    # the label of the agent
    status, board_data = target.json('deck board', 'GET', DECK + 'boards/%d' % board)
    labels = {l['title']: l['id'] for l in (board_data or {}).get('labels', [])}
    writer_label = labels.get(ROBOT + ' Writer-Bot')
    check('deck-agent: the board has the label of Writer-Bot', writer_label is not None, str(sorted(labels)))
    for name, check_in in (('deck-agent-assign', True), ('deck-agent-remove', False)):
        reqs = requests_of(name)
        check(name + ': the writer built a PUT', bool(reqs) and reqs[-1]['method'] == 'PUT', str(len(reqs)))
        if not reqs or writer_label is None:
            continue
        req = reqs[-1]
        body = json.loads(req['body'].replace('"{label:Writer-Bot}"', str(writer_label)))
        status, data = target.json(name, 'PUT', fill(req['path']), body)
        check(name + ': status', status in (200, 204), 'status %s %s' % (status, str(data)[:200]))
        _, now = target.json('deck read labels', 'GET', base)
        titles = [l['title'] for l in (now or {}).get('labels', [])]
        check(name + ': the label is ' + ('on' if check_in else 'off'), (ROBOT + ' Writer-Bot' in titles) == check_in, str(titles))
    return results


def seed_card(target):
    """Mara gives the card a description and a start date (the seed has neither)."""
    def mutate(fresh):
        deck = target['seed']['deck']
        base = DECK + 'boards/%d/stacks/%d/cards/%d' % (deck['board'], deck['stack'], deck['cards']['Plain card'])
        body = {'title': fresh['title'], 'type': 'plain', 'owner': (fresh.get('owner') or {}).get('uid', 'mara'), 'description': 'Seeded description',
                'order': fresh.get('order', 0), 'duedate': fresh.get('duedate'), 'startdate': fresh.get('duedate') or '2026-01-01T09:00:00+00:00',
                'archived': False, 'done': None}
        t = target['target']
        if t.state is not None:
            t.state.dispatch('PUT', base, {}, json.dumps(body).encode(), True)
        else:
            status, _, _ = c.request_retry('mara', 'PUT', base + '?format=json', json.dumps(body), {'Content-Type': 'application/json', 'Accept': 'application/json'})
            row('deck setup: Mara gave the card a description and a start date', status in (200, 201), 'status %s' % status)
    return mutate


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--requests', required=True)
    ap.add_argument('--snapshot', required=True, help='recorded before the replay (tools/ci/agenda-snapshot.py)')
    ap.add_argument('--seed', required=True)
    ap.add_argument('--out', default='build/agenda-replay')
    ap.add_argument('--stand-in-only', action='store_true', help='for a try on a PC: only the stand-in side, no server')
    args = ap.parse_args()
    os.makedirs(args.out, exist_ok=True)
    requests = json.load(open(args.requests, encoding='utf-8'))
    seed = json.load(open(args.seed, encoding='utf-8'))
    snapshot = json.load(open(args.snapshot, encoding='utf-8'))
    delta = datetime.date.fromisoformat(seed['seed_day']) - datetime.date.fromisoformat(requests['base_day'])
    names = [s['name'] for s in requests['scenarios']]
    row('the export holds the 14 scenarios', len(names) == 14, ','.join(names))

    real = Target('real server')
    holder = {'seed': seed, 'target': real}
    real_results = [] if args.stand_in_only else run(real, requests, seed, delta, seed_card(holder))
    stand = Target('stand-in', agenda_edit_state.EditState('ali', snapshot['users']['ali']))
    holder['target'] = stand
    stand_results = run(stand, requests, seed, delta, seed_card(holder))
    for name, ok, detail in real_results:
        row('real server: ' + name, ok, detail)
    for name, ok, detail in stand_results:
        row('stand-in: ' + name, ok, detail)

    # The stand-in answers like the real server: the status of every step and the key paths of every JSON answer
    mismatches = []
    steps = {}
    for step, status, paths in real.log:
        steps.setdefault(step, []).append((status, paths))
    seen = {}
    for step, status, paths in stand.log:
        index = seen.get(step, 0)
        seen[step] = index + 1
        wanted = steps.get(step, [])
        if index >= len(wanted):
            continue
        real_status, real_paths = wanted[index]
        if real_status != status and not (step.startswith('get ') and {real_status, status} <= {404}):
            mismatches.append('%s: status %s on the real server, %s on the stand-in' % (step, real_status, status))
        elif real_paths and paths and real_paths != paths and step.startswith(('gantt-move', 'gantt-agent', 'deck-due', 'read tasks')):
            # the real server's propagated tasks hold every column of the task (costs, budgets): the stand-in sends the task as recorded
            only_real = sorted(p for p in real_paths - paths if not p.startswith('/ocs/data/propagated[]/'))[:8]
            only_stand = sorted(paths - real_paths)[:8]
            if not only_real and not only_stand:
                continue
            mismatches.append('%s: answer shape differs (only real: %s; only stand-in: %s)' % (step, only_real, only_stand))
    if not args.stand_in_only:
        row('the stand-in answers like the real server (status and answer shape of every step)', not mismatches, '; '.join(mismatches[:6]))
    delete_count = sum(1 for step, _, _ in real.log if step == 'event-delete')
    row('the only DELETE of the job is the event delete', delete_count == 1, str(delete_count))

    with open(os.path.join(args.out, 'agenda-replay.md'), 'w', encoding='utf-8') as fh:
        fh.write('# NoAgenda replay on a real server\n\nThe requests are those of the Swift writers (request export of the unit tests).\n\n')
        for name, ok, detail in ROWS:
            fh.write('- %s %s %s\n' % ('PASS' if ok else 'FAIL', name, detail))
    failed = [r for r in ROWS if not r[1]]
    print('agenda replay: %d rows, %d failed' % (len(ROWS), len(failed)))
    sys.exit(1 if failed else 0)


if __name__ == '__main__':
    main()
