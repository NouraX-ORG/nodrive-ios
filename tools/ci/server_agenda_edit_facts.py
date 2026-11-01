#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Nourax
# SPDX-License-Identifier: GPL-3.0-or-later
"""The server facts that the NoAgenda editing step relies on, measured on the real server code (CI only; localhost only).

Run after the snapshot was recorded (it changes things): CalDAV and the conditional headers, NoGantt's refusals, Deck's full
replace. Report: <out>/agenda-edit-facts.md. The rows marked FACT are measurements without a verdict (they decide how the
stand-in answers); every other row is a rule the app relies on.
"""
import argparse
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import agenda_common as c  # noqa: E402

GANTT = '/ocs/v2.php/apps/nc_gantt/api/v1/'
DECK = '/index.php/apps/deck/api/v1.0/'
ROWS = []


def row(name, ok, detail='', fact=False):
    ROWS.append((name, ok, detail, fact))
    print(('FACT ' if fact else ('ok   ' if ok else 'FAIL ')) + name + (' - ' + detail if detail else ''))


def gantt_put(user, task, body):
    """PUT of a task; the status and the raw answer (the refusals name their reason there)."""
    status, _, data = c.request_retry(user, 'PUT', GANTT + 'tasks/%d?format=json' % task, json.dumps(body),
                                      {'Content-Type': 'application/json', 'Accept': 'application/json'})
    return status, data.decode('utf-8', 'replace')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--seed', required=True)
    ap.add_argument('--out', default='build/agenda-server')
    args = ap.parse_args()
    seed = json.load(open(args.seed, encoding='utf-8'))
    ids = seed['gantt']['tasks']
    res = seed['gantt']['resources']
    projects = seed['gantt']['projects']
    ics = c.event('ci-facts', 'Facts', c.utc(c.seed_day(), 20), c.utc(c.seed_day(), 21))
    path = '/remote.php/dav/calendars/ali/personal/ci-facts.ics'
    hdr = {'Content-Type': 'text/calendar; charset=utf-8'}

    # CalDAV: the conditional headers ------------------------------------------------------------------------------------
    status, _, _ = c.request_retry('ali', 'PUT', path, ics, dict(hdr, **{'If-None-Match': '*'}))
    row('a new object with If-None-Match: * is created (201)', status == 201, 'status %s' % status)
    status, _, _ = c.request_retry('ali', 'PUT', path, ics, dict(hdr, **{'If-None-Match': '*'}))
    row('the same name with If-None-Match: * is refused (412)', status == 412, 'status %s' % status)
    _, headers, _ = c.request_retry('ali', 'GET', path)
    etag = headers.get('etag')
    row('GET of an object answers its ETag', bool(etag), str(etag))
    status, _, _ = c.request_retry('ali', 'PUT', path, ics.replace('Facts', 'Changed'), dict(hdr, **{'If-Match': '"nope"'}))
    row('a PUT with another If-Match is refused (412)', status == 412, 'status %s' % status)
    status, _, _ = c.request_retry('ali', 'PUT', path, ics.replace('Facts', 'Changed'), dict(hdr, **{'If-Match': etag or ''}))
    row('a PUT with the right If-Match is accepted (204)', status == 204, 'status %s' % status)
    status, _, _ = c.request_retry('ali', 'DELETE', path, None, {'If-Match': '"nope"'})
    row('a DELETE with another If-Match is refused (412)', status == 412, 'status %s' % status)
    _, headers, _ = c.request_retry('ali', 'GET', path)
    status, _, _ = c.request_retry('ali', 'DELETE', path, None, {'If-Match': headers.get('etag', '')})
    row('a DELETE with the right If-Match is accepted (204)', status == 204, 'status %s' % status)
    status, _, _ = c.request_retry('ali', 'GET', path)
    row('the deleted object is gone (404)', status == 404, 'status %s' % status)

    # NoGantt: the refusals --------------------------------------------------------------------------------------------------
    five = [{'resource_id': res[k], 'work': None} for k in ('ali', 'sara', 'mara', 'temp', 'designer')]
    status, text = gantt_put('ali', ids['write'], {'resources': five})
    row('a task with 5 resource rows is refused (too_many_resources)', status == 400 and 'too_many_resources' in text, 'status %s %s' % (status, text[:120]))
    status, text = gantt_put('ali', ids['internal'], {'manual_progress': 10})
    row('a viewer cannot change a task (403)', status == 403, 'status %s' % status)
    if 'role' in ids and 'roles' in projects:
        status, text = gantt_put('mara', ids['role'], {'resources': [{'resource_id': res['designer'], 'work': 2}, {'resource_id': res['ali'], 'work': None}]})
        row('a new person in a roles-only project is refused (roles_only_assignment)', status == 400 and 'roles_only_assignment' in text, 'status %s %s' % (status, text[:120]))
    status, _, _ = c.request('ali', 'PUT', GANTT + 'tasks/%d?format=json' % ids['write'], json.dumps({'manual_progress': 41}), {'Content-Type': 'application/json'}, ocs=False)
    row('a write without the OCS-APIRequest header is refused (412)', status == 412, 'status %s' % status)

    # Deck: the full replace -----------------------------------------------------------------------------------------------------
    deck = seed['deck']
    base = DECK + 'boards/%d/stacks/%d/cards/%d' % (deck['board'], deck['stack'], deck['cards']['No date card'])
    status, card = c.ocs_json('mara', base)
    if not isinstance(card, dict):
        row('Deck: the card can be read', False, 'status %s' % status)
    else:
        owner = (card.get('owner') or {}).get('uid', 'mara')
        body = {'title': card['title'], 'type': 'plain', 'owner': owner, 'description': 'Facts description', 'order': card.get('order', 0),
                'startdate': '2026-01-05T09:00:00+00:00', 'duedate': '2026-01-06T09:00:00+00:00', 'archived': False}
        status, _ = c.ocs_json('mara', base, 'PUT', dict(body, done=True))
        _, now = c.ocs_json('mara', base)
        row('Deck accepts done as a boolean (true gives a date)', bool(now and now.get('done')), 'status %s, done=%s' % (status, (now or {}).get('done')), fact=True)
        if not (now and now.get('done')):
            status, _ = c.ocs_json('mara', base, 'PUT', dict(body, done='2026-01-07T09:00:00+00:00'))
            _, now = c.ocs_json('mara', base)
            row('Deck accepts done as a date string', bool(now and now.get('done')), 'status %s, done=%s' % (status, (now or {}).get('done')), fact=True)
        status, _ = c.ocs_json('mara', base, 'PUT', body)
        _, now = c.ocs_json('mara', base)
        row('Deck: a PUT without done clears done (the reason for the full replace)', status in (200, 201, 204) and not (now or {}).get('done'),
            'status %s, done=%s' % (status, (now or {}).get('done')), fact=True)
        status, _ = c.ocs_json('mara', base, 'PUT', {k: v for k, v in body.items() if k not in ('startdate', 'description')})
        _, now = c.ocs_json('mara', base)
        row('Deck: a PUT without startdate and description clears them', not (now or {}).get('startdate') and not (now or {}).get('description'),
            'startdate=%s description=%r' % ((now or {}).get('startdate'), (now or {}).get('description')), fact=True)

    os.makedirs(args.out, exist_ok=True)
    with open(os.path.join(args.out, 'agenda-edit-facts.md'), 'w', encoding='utf-8') as fh:
        fh.write('# NoAgenda editing: server facts (real server code)\n\n')
        for name, ok, detail, fact in ROWS:
            fh.write('- %s %s %s\n' % ('FACT' if fact else ('PASS' if ok else 'FAIL'), name, detail))
    failed = [r for r in ROWS if not r[1] and not r[3]]
    print('edit facts: %d rows, %d failed' % (len(ROWS), len(failed)))
    sys.exit(1 if failed else 0)


if __name__ == '__main__':
    main()
