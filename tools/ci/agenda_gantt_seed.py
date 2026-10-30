# SPDX-FileCopyrightText: 2026 Nourax
# SPDX-License-Identifier: GPL-3.0-or-later
"""The NoGantt part of the NoAgenda seed (CI only; the throwaway server on localhost).

Mara (the manager) owns the projects and the planning people. The routes and fields are those of nc_gantt 2.4.1
(`appinfo/routes.php`, the controllers; printed by `tools/ci/agenda-server.sh discover`).
Planning people: Ali, Sara and Mara linked to their accounts; "Temp worker" not linked; "Designer" a role; the agents
"Writer-Bot (Ali)" (recognised by the registry id), "Design-Bot (Sara)" and "Research-Bot (Ali)" (by exact name only),
and "Ghost-Bot (Ali)" (unknown to the registry).
"""
import datetime

import agenda_common as c

G = '/ocs/v2.php/apps/nc_gantt/api/v1/'
ROBOT = '\U0001F916'


def stamp(day, offset, hour=9):
    d = day + datetime.timedelta(days=offset)
    return '%s %02d:00:00' % (d.isoformat(), hour)


def post(path, body, user='mara', method='POST'):
    status, data = c.ocs_json(user, G + path, method, body)
    return status, data


def seed(day, deck, step):
    ids = {}
    # Planning people ---------------------------------------------------------------
    people = [('ali', 'Ali', 'person', 'ali'), ('sara', 'Sara', 'person', 'sara'), ('mara', 'Mara', 'person', 'mara'),
              ('temp', 'Temp worker', 'person', None), ('designer', 'Designer', 'role', None),
              ('writer', ROBOT + ' Writer-Bot (Ali)', 'person', None), ('design', ROBOT + ' Design-Bot (Sara)', 'person', None),
              ('research', ROBOT + ' Research-Bot (Ali)', 'person', None), ('ghost', ROBOT + ' Ghost-Bot (Ali)', 'person', None)]
    for key, name, kind, uid in people:
        body = {'name': name, 'type': kind, 'unit': 'h'}
        if uid:
            body['uid'] = uid
        status, data = post('resources', body)
        ok = isinstance(data, dict) and 'id' in data
        step('nogantt resource ' + key, ok, '' if ok else 'status %s' % status)
        if ok:
            ids[key] = data['id']
    if len(ids) < len(people):
        return {'resource_ids': {}}

    def row(key, work=None):
        return {'resource_id': ids[key], 'work': work}

    # Projects ------------------------------------------------------------------------
    projects = {}
    for key, title, color in (('website', 'Website', '#0082c9'), ('internal', 'Internal', '#e9322d'), ('roles', 'Roles only', '#00a000')):
        status, data = post('projects', {'title': title, 'color': color})
        ok = isinstance(data, dict) and 'id' in data
        step('nogantt project ' + title, ok, '' if ok else 'status %s' % status)
        if ok:
            projects[key] = data['id']
    if 'website' not in projects:
        return {'resource_ids': {'writer': [ids['writer']]}}
    for key, user, permission in (('website', 'ali', 'editor'), ('website', 'sara', 'viewer'), ('internal', 'ali', 'viewer')):
        if key in projects:
            status, _ = post('projects/%d/shares' % projects[key], {'principal_id': user, 'permission': permission, 'principal_type': 'user'})
            step('nogantt share %s %s %s' % (key, user, permission), status in (200, 201), 'status %s' % status)
    if 'roles' in projects:
        status, _ = post('projects/%d' % projects['roles'], {'roles_only_assignment': True}, method='PUT')
        step('nogantt roles-only flag', status in (200, 201), 'status %s' % status)
    status, data = post('projects/%d/subprojects' % projects['website'], {'title': 'Copy'})
    phase = data.get('id') if isinstance(data, dict) else None
    step('nogantt phase Copy', phase is not None, 'status %s' % status)

    # Tasks ---------------------------------------------------------------------------
    made = {}

    def task(project, key, title, start, end, rows, **extra):
        body = {'title': title, 'start_date': stamp(day, start), 'end_date': stamp(day, end, 17),
                'resources': rows, 'progress_mode': 'manual'}
        body.update(extra)
        status, data = post('projects/%d/tasks' % projects[project], body)
        result = data.get('task', data) if isinstance(data, dict) else None
        ok = isinstance(result, dict) and 'id' in result
        step('nogantt task ' + title, ok, '' if ok else 'status %s %s' % (status, str(data)[:120]))
        if ok:
            made[key] = result['id']
        return ok

    task('website', 'write', 'Write homepage copy', -2, 1, [row('ali', 4), row('writer')], work=8, manual_progress=40,
         **({'subproject_id': phase} if phase else {}))
    task('website', 'big', 'Big push', 0, 1, [row('ali', 60)], work=60)
    task('website', 'banner', 'Banner design', -4, -2, [row('sara', 8), row('design')], work=8)
    task('website', 'publish', 'Publish banners', -1, 2, [row('sara', 4)], work=4,
         **({'dependencies': [{'predecessor_id': 't-%d' % made['banner'], 'dependency_type': 'FS', 'lag_days': 0}]} if 'banner' in made else {}))
    task('website', 'orphan', 'Orphan writing', 0, 2, [row('writer')])
    task('website', 'cross', 'Cross pairing', 0, 2, [row('ali', 2), row('design')], work=2)
    task('website', 'two', 'Two agents', 1, 3, [row('ali', 2), row('writer'), row('research')], work=2)
    task('website', 'temp', 'Temp work', 0, 2, [row('temp', 4)], work=4)
    task('website', 'sitemap', 'Review sitemap', 1, 3, [row('designer', 4)], work=4)
    task('website', 'done', 'Finished task', -6, -5, [row('ali', 2)], work=2, status='done', manual_progress=100)
    task('website', 'landing', 'Landing page build', 0, 2, [row('ali', 3)], work=3)
    task('internal', 'internal', 'Internal sync', 0, 1, [row('ali', 1)], work=1)
    task('internal', 'saras', "Sara's internal task", 0, 1, [row('sara', 2)], work=2)
    if 'roles' in projects:
        task('roles', 'role', 'Role task', 0, 1, [row('designer', 2)], work=2)
    status, _ = post('projects/%d/milestones' % projects['website'], {'title': 'Launch', 'milestone_date': (day + datetime.timedelta(days=5)).isoformat()})
    step('nogantt milestone Launch', status in (200, 201), 'status %s' % status)

    # A task linked to the Deck card (one row for both) -------------------------------
    cards = (deck or {}).get('cards', {})
    if 'landing' in made and cards:
        card = next(iter(cards.values()))
        status, data = 0, None
        for action in (None, 'keep', 'task', 'card', 'adopt', 'enforce', 'ignore'):
            body = {'card_id': card}
            if action:
                body['date_action'] = action
            status, data = post('tasks/%d/deck-links' % made['landing'], body)
            if status in (200, 201):
                break
        # Optional: the unit tests cover the one-row rule; the link is only for the screenshots
        step('nogantt task linked to a Deck card (optional)', True, 'status %s %s' % (status, str(data)[:160]))

    # NoGantt copies Sara's tasks into a calendar (the hidden-calendar rule) ------------
    status, data = post('task-sync', {'enabled': True, 'create_calendar': True}, user='sara', method='PUT')
    step('nogantt copy calendar for sara', status in (200, 201), 'status %s' % status)
    return {'resource_ids': {'writer': [ids['writer']]}, 'projects': projects, 'tasks': made, 'resources': ids}
