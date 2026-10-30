# SPDX-FileCopyrightText: 2026 Nourax
# SPDX-License-Identifier: GPL-3.0-or-later
"""NoAgenda part of the CI stand-in (tools/ci/drive-stand-in.py --agenda SNAPSHOT). CI only.

It answers the app's NoAgenda reads from the real server's recorded answers (tools/ci/agenda-snapshot.py):

  PROPFIND /remote.php/dav/principals/users/<u>/, /remote.php/dav/calendars/<u>/
  REPORT   /remote.php/dav/calendars/<u>/<calendar>/      the events or to-dos answer, by the body (VTODO or not)
  GET      /remote.php/dav/files/<u>/NoAgenda/agent-registry.json   200 with an ETag, 304, or 404
  GET      /ocs/v2.php/apps/nc_gantt/api/v1/...           without the OCS-APIRequest header 412, like the real server
  GET      /index.php/apps/deck/api/v1.0/boards, .../boards/<id>/stacks
  GET      /ocs/v2.php/cloud/capabilities                 the minimal account plus the `deck` capability

A control path switches modes for the state screenshots: POST /__ci/agenda?mode=NAME with offline-gantt (503),
refuse-gantt (403), refuse-deck (403), deck-version=1.20.0, or normal. Every request is logged by name and fact only
(path, whether OCS-APIRequest came); never a header value.
"""
import hashlib
import json
from urllib.parse import parse_qs, urlsplit

GANTT_PREFIX = '/ocs/v2.php/apps/nc_gantt/api/v1/'
DECK_PREFIX = '/index.php/apps/deck/api/v1.0/'
EMPTY_MULTISTATUS = '<?xml version="1.0"?><d:multistatus xmlns:d="DAV:"></d:multistatus>'


class AgendaState:
    def __init__(self, snapshot):
        self.snapshot = snapshot
        self.mode = 'normal'
        self.deck_version = None

    def set_mode(self, mode):
        self.mode = 'normal'
        self.deck_version = None
        if mode.startswith('deck-version='):
            self.deck_version = mode.split('=', 1)[1]
        elif mode in ('offline-gantt', 'refuse-gantt', 'refuse-deck'):
            self.mode = mode


def _ocs(data):
    return {'ocs': {'meta': {'status': 'ok', 'statuscode': 200, 'message': 'OK'}, 'data': data}}


def handle(h, method, path, body):
    """Answer one request; False when it is not a NoAgenda read (the caller then goes on)."""
    state = h.server.agenda
    ws = h.server.workspace
    if state is None or ws is None:
        return False
    if path == '/__ci/agenda' and method == 'POST':
        mode = (parse_qs(urlsplit(h.path).query).get('mode') or ['normal'])[0]
        state.set_mode(mode)
        h._record(200, {'event': 'agenda-mode', 'mode': mode})
        h._json(200, {'ok': True, 'mode': mode})
        return True
    ours = (path.startswith('/remote.php/dav/principals/') or path.startswith('/remote.php/dav/calendars/')
            or (path.startswith('/remote.php/dav/files/') and '/NoAgenda/' in path)
            or path.startswith(GANTT_PREFIX) or path.startswith(DECK_PREFIX)
            or (path == '/ocs/v2.php/cloud/capabilities' and method == 'GET'))
    if not ours:
        return False
    ocs_header = h.headers.get('OCS-APIRequest') == 'true'
    if not h._basic_ok():
        h._record(401, {'ocs_header': ocs_header, 'agenda': True})
        h._json(401, _ocs([]))
        return True
    user = ws['user']
    data = state.snapshot['users'].get(user)
    if data is None:
        h._record(404, {'ocs_header': ocs_header, 'agenda': True})
        h._json(404, {'message': 'no snapshot for this user'})
        return True

    def done(status, text, ctype='application/xml; charset=utf-8', headers=None):
        h._record(status, {'ocs_header': ocs_header, 'agenda': True})
        h._send(status, text, ctype, headers)
        return True

    if path == '/ocs/v2.php/cloud/capabilities':
        caps = json.loads(data['capabilities']['text'])['ocs']['data']
        deck = (caps.get('capabilities') or {}).get('deck')
        if deck is None:
            return False
        if state.deck_version:
            deck = dict(deck, version=state.deck_version)
        # The minimal account the stand-in always sent, plus the deck capability
        h._record(200, {'ocs_header': ocs_header, 'agenda': True, 'event': 'capabilities'})
        h._json(200, _ocs({
            'version': {'major': 35, 'minor': 0, 'micro': 2, 'string': '35.0.2', 'edition': '', 'extendedSupport': False},
            'capabilities': {'core': {'pollinterval': 60, 'webdav-root': 'remote.php/webdav'},
                             'files': {'bigfilechunking': True, 'undelete': True, 'versioning': True},
                             'dav': {'chunking': '1.0'}, 'deck': deck,
                             'notifications': {'ocs-endpoints': ['list', 'get', 'delete', 'delete-all', 'icons',
                                                                 'rich-strings', 'action-web', 'user-status']},
                             'theming': {'name': 'Nourax Workspace', 'url': 'https://drive.nourax.org', 'slogan': '',
                                         'color': '#2563EB', 'color-text': '#ffffff', 'color-element': '#2563EB',
                                         'color-element-bright': '#2563EB', 'color-element-dark': '#2563EB',
                                         'logo': '', 'background': '#2563EB', 'background-plain': True,
                                         'background-default': False, 'logoheader': '', 'favicon': ''}}}))
        return True

    if path.startswith(GANTT_PREFIX):
        if not ocs_header:
            return done(412, json.dumps({'message': 'CSRF check failed'}), 'application/json')
        if state.mode == 'offline-gantt':
            return done(503, json.dumps({'message': 'unavailable'}), 'application/json')
        if state.mode == 'refuse-gantt':
            return done(403, json.dumps({'message': 'forbidden'}), 'application/json')
        key = path[len(GANTT_PREFIX):]
        entry = data['gantt'].get(key)
        if entry is None:
            return done(404, json.dumps(_ocs([])), 'application/json')
        return done(entry['status'], entry['text'], 'application/json; charset=utf-8')

    if path.startswith(DECK_PREFIX):
        if not ocs_header:
            return done(412, json.dumps({'message': 'CSRF check failed'}), 'application/json')
        if state.mode == 'refuse-deck':
            return done(403, json.dumps({'message': 'forbidden'}), 'application/json')
        rest = path[len(DECK_PREFIX):]
        if rest == 'boards':
            entry = data['deck']['boards']
        elif rest.startswith('boards/') and rest.endswith('/stacks'):
            entry = data['deck']['stacks'].get(rest.split('/')[1])
        else:
            entry = None
        if entry is None:
            return done(404, json.dumps({'message': 'not found'}), 'application/json')
        return done(entry['status'], entry['text'], 'application/json; charset=utf-8')

    if path.startswith('/remote.php/dav/files/'):
        entry = data['registry']
        if entry['status'] != 200:
            return done(404, '', 'text/plain')
        etag = '"' + hashlib.sha256(entry['text'].encode()).hexdigest()[:16] + '"'
        if h.headers.get('If-None-Match') == etag:
            return done(304, '', 'application/json', {'ETag': etag})
        return done(200, entry['text'], 'application/json; charset=utf-8', {'ETag': etag})

    if method == 'PROPFIND' and path.startswith('/remote.php/dav/principals/'):
        return done(207, data['principal']['text'])
    if method == 'PROPFIND' and path.rstrip('/') == '/remote.php/dav/calendars/' + user:
        return done(207, data['home']['text'])
    if method == 'REPORT' and path.startswith('/remote.php/dav/calendars/'):
        uri = path.rstrip('/').split('/')[-1]
        reports = data['reports'].get(uri)
        if reports is None:
            return done(207, EMPTY_MULTISTATUS)
        kind = 'todos' if b'name="VTODO"' in body else 'events'
        return done(207, reports[kind]['text'])
    return False
