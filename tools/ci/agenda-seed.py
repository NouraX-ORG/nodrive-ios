#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Nourax
# SPDX-License-Identifier: GPL-3.0-or-later
"""Seeds the throwaway CI server for the NoAgenda checks (design section 12). CI only; localhost only.

People: manager Mara; staff Ali and Sara; Olaf (another organisation). Calendars, to-dos, an invitation, a shared
team calendar, a Deck board with agent labels, the agent registry files, and (agenda_gantt_seed.py) NoGantt.
Every step is logged by name; a step that fails is listed and the script ends with a non-zero status, so the
check job shows what is missing.
"""
import argparse
import datetime
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import agenda_common as c  # noqa: E402

RESULTS = []


def step(name, ok, detail=''):
    RESULTS.append((name, ok, detail))
    print(('ok   ' if ok else 'FAIL ') + name + (' ' + detail if detail else ''))


def mkcalendar(user, uri, name, components):
    comps = ''.join('<c:comp name="%s"/>' % x for x in components)
    body = ('<?xml version="1.0"?><c:mkcalendar xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav"><d:set><d:prop>'
            '<d:displayname>%s</d:displayname><c:supported-calendar-component-set>%s</c:supported-calendar-component-set>'
            '</d:prop></d:set></c:mkcalendar>' % (name, comps))
    status, _, _ = c.request_retry(user, 'MKCALENDAR', '/remote.php/dav/calendars/%s/%s/' % (user, uri), body,
                                   {'Content-Type': 'application/xml'})
    return status in (201, 405)


def seed_calendars(day):
    d = lambda n: day + datetime.timedelta(days=n)  # noqa: E731
    agent = ['X-NOURAX-AGENT-ID:AG-0001', 'CATEGORIES:agent:AG-0001']
    step('calendar work (ali)', mkcalendar('ali', 'work', 'Work', ['VEVENT']))
    items = [
        ('ali', 'personal', 'dentist', c.event('ci-dentist', 'Dentist', c.utc(day, 10), c.utc(day, 11))),
        ('ali', 'work', 'client-call', c.event('ci-client-call', 'Client call', c.utc(day, 10), c.utc(day, 11))),
        ('ali', 'work', 'standup', c.event('ci-standup', 'Stand-up', c.utc(d(-30), 8), c.utc(d(-30), 8, 15),
                                           ['RRULE:FREQ=DAILY'])),
        ('ali', 'work', 'day-off', c.event('ci-day-off', 'Day off', d(3), d(4), all_day=True)),
        ('ali', 'work', 'free', c.event('ci-free', 'Lunch hold', c.utc(day, 12), c.utc(day, 13), ['TRANSP:TRANSPARENT'])),
        ('ali', 'work', 'writer-review', c.event('ci-writer-review', 'Writer-Bot review', c.utc(day, 14), c.utc(day, 15), agent)),
        ('ali', 'work', 'tag-only', c.event('ci-tag-only', 'Tag only review', c.utc(d(1), 14), c.utc(d(1), 15),
                                            ['CATEGORIES:agent:AG-0001'])),
        ('ali', 'personal', 'draft-report', c.todo('ci-draft', 'Draft report', c.utc(day, 15), agent)),
        ('ali', 'personal', 'late-todo', c.todo('ci-late', 'Late to-do', c.utc(d(-3), 9))),
        ('ali', 'personal', 'someday', c.todo('ci-someday', 'Someday to-do')),
        ('ali', 'personal', 'done-todo', c.todo('ci-done', 'Done to-do', c.utc(d(-1), 9),
                                                ['STATUS:COMPLETED', 'COMPLETED:' + c.ics_time(c.utc(d(-1), 10))])),
    ]
    for user, cal, name, ics in items:
        ok, status = c.put_calendar_object(user, cal, name, ics)
        step('put %s/%s/%s' % (user, cal, name), ok, '' if ok else 'status %s' % status)


def share_calendar(owner, uri, with_user):
    body = ('<?xml version="1.0"?><cs:share xmlns:d="DAV:" xmlns:cs="http://calendarserver.org/ns/"><cs:set>'
            '<d:href>principal:principals/users/%s</d:href><cs:read-write/></cs:set></cs:share>' % with_user)
    status, _, _ = c.request_retry(owner, 'POST', '/remote.php/dav/calendars/%s/%s/' % (owner, uri), body,
                                   {'Content-Type': 'application/xml; charset=utf-8'})
    return status in (200, 201, 204)


def seed_team_calendar(day):
    d = lambda n: day + datetime.timedelta(days=n)  # noqa: E731
    step('calendar team (mara)', mkcalendar('mara', 'team', 'Team', ['VEVENT']))
    org = 'ORGANIZER;CN=Mara:mailto:mara@example.org'

    def attendee(user, status):
        return 'ATTENDEE;CN=%s;PARTSTAT=%s:mailto:%s@example.org' % (user.capitalize(), status, user)
    items = [
        ('planning', c.event('ci-planning', 'Planning meeting', c.utc(day, 9), c.utc(day, 10),
                             [org, attendee('mara', 'ACCEPTED'), attendee('ali', 'NEEDS-ACTION')])),
        ('tentative', c.event('ci-tentative', 'Tentative sync', c.utc(day, 16), c.utc(day, 17),
                              [org, 'STATUS:TENTATIVE', attendee('mara', 'ACCEPTED'), attendee('ali', 'TENTATIVE')])),
        ('declined', c.event('ci-declined', 'Budget talk', c.utc(d(1), 9), c.utc(d(1), 10),
                             [org, attendee('mara', 'ACCEPTED'), attendee('ali', 'DECLINED')])),
        ('without-ali', c.event('ci-without-ali', 'Mara only', c.utc(day, 11), c.utc(day, 12),
                                [org, attendee('mara', 'ACCEPTED')])),
    ]
    for name, ics in items:
        ok, status = c.put_calendar_object('mara', 'team', name, ics)
        step('put mara/team/' + name, ok, '' if ok else 'status %s' % status)
    step('share team calendar to ali', share_calendar('mara', 'team', 'ali'))
    # An event Ali organises in the shared calendar
    ali_org = 'ORGANIZER;CN=Ali:mailto:ali@example.org'
    ok, status = c.put_calendar_object('mara', 'team', 'ali-organises',
                                       c.event('ci-ali-organises', 'Ali organises', c.utc(day, 13), c.utc(day, 14), [ali_org]))
    step('put mara/team/ali-organises', ok, '' if ok else 'status %s' % status)


def seed_email_addresses(container):
    """The invitations use <user>@example.org; the same address is set on each user, so the principal says so."""
    import subprocess
    for user in c.USERS:
        done = subprocess.run(['docker', 'exec', '-u', 'www-data', container, 'php', 'occ', 'user:setting', user,
                               'settings', 'email', user + '@example.org'], capture_output=True, text=True)
        step('email of ' + user, done.returncode == 0)


def registry(person_agents):
    agents = []
    for agent_id, name, person, status, org, resource_ids in person_agents:
        agents.append({'id': agent_id, 'name': name, 'person': person, 'status': status, 'organisation': org,
                       'skills': [], 'availability': {'timezone': 'UTC', 'weekly': [], 'capacity_hours_per_week': 40, 'days_off': []},
                       'links': {'nogantt_resource_ids': resource_ids, 'noboard_label': '\U0001F916 ' + name,
                                 'calendar_tag': 'agent:' + agent_id}})
    return {'schema': 'nourax-agent-registry', 'version': 1, 'updated_utc': '2026-10-28T18:00:00Z',
            'source': 'CI seed with made-up data', 'agents': agents}


def put_registry(user, text, name):
    c.request_retry(user, 'MKCOL', '/remote.php/dav/files/%s/NoAgenda' % user, ocs=False)
    status, _, _ = c.request_retry(user, 'PUT', '/remote.php/dav/files/%s/NoAgenda/agent-registry.json' % user, text,
                                   {'Content-Type': 'application/json'})
    step('registry file ' + name, status in (201, 204), 'status %s' % status)


def seed_registries(resource_ids):
    full = [('AG-0001', 'Writer-Bot', 'ali', 'active', 'demo-org', resource_ids.get('writer', [])),
            ('AG-0002', 'Design-Bot', 'sara', 'active', 'demo-org', []),
            ('AG-0003', 'Research-Bot', 'ali', 'paused', 'demo-org', []),
            ('AG-0004', 'Ghost-Bot-Retired', 'ali', 'retired', 'demo-org', []),
            ('AG-0007', 'Mara-Bot', 'mara', 'active', 'demo-org', []),
            ('AG-0008', 'Out-Bot', 'olaf', 'active', 'other-org', [])]
    put_registry('ali', json.dumps(registry(full), ensure_ascii=False), 'ali (valid)')
    put_registry('mara', json.dumps(registry(full), ensure_ascii=False), 'mara (valid)')
    put_registry('sara', '{ this is not a registry', 'sara (invalid)')
    # olaf has no file: missing


def seed_deck(day):
    """Board "Team board": Mara owns it; Ali and Sara are members; labels for the agents; cards of every kind."""
    base = '/index.php/apps/deck/api/v1.0'
    status, board = c.ocs_json('mara', base + '/boards', 'POST', {'title': 'Team board', 'color': '0082c9'})
    if status not in (200, 201) or not isinstance(board, dict):
        step('deck board', False, 'status %s' % status)
        return {}
    bid = board['id']
    step('deck board', True)
    for user in ('ali', 'sara'):
        s, _ = c.ocs_json('mara', base + '/boards/%d/acl' % bid, 'POST',
                          {'type': 0, 'participant': user, 'permissionEdit': True, 'permissionShare': False, 'permissionManage': False})
        step('deck member ' + user, s in (200, 201), 'status %s' % s)
    labels = {}
    for title in ('\U0001F916 Writer-Bot', '\U0001F916 Design-Bot'):
        s, label = c.ocs_json('mara', base + '/boards/%d/labels' % bid, 'POST', {'title': title, 'color': '2563EB'})
        if isinstance(label, dict) and 'id' in label:
            labels[title] = label['id']
        step('deck label ' + title, s in (200, 201), 'status %s' % s)
    s, stack = c.ocs_json('mara', base + '/boards/%d/stacks' % bid, 'POST', {'title': 'To do', 'order': 1})
    if not isinstance(stack, dict):
        step('deck stack', False, 'status %s' % s)
        return {'board': bid}
    sid = stack['id']
    due = lambda n: (c.utc(day + datetime.timedelta(days=n), 12)).strftime('%Y-%m-%dT%H:%M:%S+00:00')  # noqa: E731
    cards = [('Review sitemap', due(0), ['ali'], ['\U0001F916 Writer-Bot']), ('Plain card', due(2), ['ali'], []),
             ('No date card', None, ['ali'], []), ('Unknown agent card', due(1), ['ali'], ['ghost']),
             ('Sara card', due(-2), ['sara'], ['\U0001F916 Design-Bot']), ('Unassigned card', due(3), [], [])]
    made = {}
    for title, duedate, users, label_titles in cards:
        body = {'title': title, 'type': 'plain', 'order': 1}
        if duedate:
            body['duedate'] = duedate
        s, card = c.ocs_json('mara', base + '/boards/%d/stacks/%d/cards' % (bid, sid), 'POST', body)
        if not isinstance(card, dict):
            step('deck card ' + title, False, 'status %s' % s)
            continue
        made[title] = card['id']
        for user in users:
            c.ocs_json('mara', base + '/boards/%d/stacks/%d/cards/%d/assignUser' % (bid, sid, card['id']), 'PUT', {'userId': user})
        for lt in label_titles:
            if lt in labels:
                c.ocs_json('mara', base + '/boards/%d/stacks/%d/cards/%d/assignLabel' % (bid, sid, card['id']), 'PUT', {'labelId': labels[lt]})
        step('deck card ' + title, True)
    return {'board': bid, 'stack': sid, 'cards': made}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--container')
    ap.add_argument('--out', default='build/agenda-server')
    args = ap.parse_args()
    day = c.seed_day()
    os.makedirs(args.out, exist_ok=True)
    seed_email_addresses(args.container)
    seed_calendars(day)
    seed_team_calendar(day)
    deck = seed_deck(day)
    gantt = {}
    try:
        import agenda_gantt_seed as g
        gantt = g.seed(day, deck, step) or {}
    except ImportError:
        step('nogantt seed', False, 'agenda_gantt_seed.py is missing')
    seed_registries(gantt.get('resource_ids', {}))
    info = {'seed_day': day.isoformat(), 'deck': deck, 'gantt': gantt}
    with open(os.path.join(args.out, 'seed.json'), 'w') as fh:
        json.dump(info, fh, indent=1)
    failed = [r for r in RESULTS if not r[1]]
    print('seed: %d steps, %d failed' % (len(RESULTS), len(failed)))
    for name, _, detail in failed:
        print('  FAILED: %s %s' % (name, detail))
    sys.exit(1 if failed else 0)


if __name__ == '__main__':
    main()
