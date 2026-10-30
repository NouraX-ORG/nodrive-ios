# SPDX-FileCopyrightText: 2026 Nourax
# SPDX-License-Identifier: GPL-3.0-or-later
"""Shared helpers of the NoAgenda CI scripts (Python standard library only).

CI only. They talk to the throwaway Nextcloud 35 of tools/ci/agenda-server.sh on localhost, with one app password
per seeded user (from the environment, never printed). Nothing here ever contacts drive.nourax.org.
"""
import base64
import datetime
import http.client
import json
import os
import re

USERS = ['mara', 'ali', 'sara', 'olaf']


def port():
    return int(os.environ.get('NODRIVE_AGENDA_PORT', '8081'))


def token(user):
    value = os.environ.get('NODRIVE_AGENDA_PW_' + user.upper())
    if not value:
        raise SystemExit('no app password for ' + user + ' in the environment')
    return value


def seed_day():
    """The day the server is seeded for (UTC); the UI tests pin "today" to it."""
    forced = os.environ.get('NODRIVE_AGENDA_TODAY')
    if forced:
        return datetime.datetime.strptime(forced, '%Y-%m-%d').date()
    return datetime.datetime.now(datetime.timezone.utc).date()


def request(user, method, path, body=None, headers=None, ocs=True, timeout=60):
    """One request as `user` (Basic with the app password). Returns (status, headers, bytes)."""
    conn = http.client.HTTPConnection('localhost', port(), timeout=timeout)
    auth = base64.b64encode((user + ':' + token(user)).encode()).decode()
    hdrs = {'Authorization': 'Basic ' + auth, 'User-Agent': 'NoDrive-CI'}
    if ocs:
        hdrs['OCS-APIRequest'] = 'true'
    hdrs.update(headers or {})
    if isinstance(body, str):
        body = body.encode()
    conn.request(method, path, body=body, headers=hdrs)
    resp = conn.getresponse()
    data = resp.read()
    out = (resp.status, {k.lower(): v for k, v in resp.getheaders()}, data)
    conn.close()
    return out


def request_retry(user, method, path, body=None, headers=None, ocs=True, tries=4):
    """The busy SQLite server answers 500 now and then (found by the desktop build): try again."""
    last = None
    for _ in range(tries):
        last = request(user, method, path, body, headers, ocs)
        if last[0] < 500:
            return last
    return last


def ocs_json(user, path, method='GET', body=None):
    """An OCS call with JSON in and out. Returns (status, data)."""
    sep = '&' if '?' in path else '?'
    headers = {'Accept': 'application/json'}
    payload = None
    if body is not None:
        payload = json.dumps(body)
        headers['Content-Type'] = 'application/json'
    status, _, data = request_retry(user, method, path + sep + 'format=json', payload, headers)
    try:
        parsed = json.loads(data.decode() or 'null')
    except ValueError:
        return status, None
    if isinstance(parsed, dict) and 'ocs' in parsed:
        return status, parsed['ocs'].get('data')
    return status, parsed


def ics_time(dt):
    return dt.strftime('%Y%m%dT%H%M%SZ')


def utc(day, hour, minute=0):
    return datetime.datetime(day.year, day.month, day.day, hour, minute, tzinfo=datetime.timezone.utc)


def event(uid, summary, start, end, extra=None, all_day=False):
    lines = ['BEGIN:VCALENDAR', 'VERSION:2.0', 'PRODID:-//Nourax//NoAgenda CI//EN', 'BEGIN:VEVENT', 'UID:' + uid,
             'DTSTAMP:' + ics_time(datetime.datetime.now(datetime.timezone.utc)), 'SUMMARY:' + summary]
    if all_day:
        lines += ['DTSTART;VALUE=DATE:' + start.strftime('%Y%m%d'), 'DTEND;VALUE=DATE:' + end.strftime('%Y%m%d')]
    else:
        lines += ['DTSTART:' + ics_time(start), 'DTEND:' + ics_time(end)]
    lines += list(extra or []) + ['END:VEVENT', 'END:VCALENDAR']
    return '\r\n'.join(lines) + '\r\n'


def todo(uid, summary, due=None, extra=None):
    lines = ['BEGIN:VCALENDAR', 'VERSION:2.0', 'PRODID:-//Nourax//NoAgenda CI//EN', 'BEGIN:VTODO', 'UID:' + uid,
             'DTSTAMP:' + ics_time(datetime.datetime.now(datetime.timezone.utc)), 'SUMMARY:' + summary]
    if due:
        lines.append('DUE:' + ics_time(due))
    lines += list(extra or []) + ['END:VTODO', 'END:VCALENDAR']
    return '\r\n'.join(lines) + '\r\n'


def put_calendar_object(user, calendar, name, ics):
    path = '/remote.php/dav/calendars/%s/%s/%s.ics' % (user, calendar, name)
    status, _, data = request_retry(user, 'PUT', path, ics, {'Content-Type': 'text/calendar; charset=utf-8'})
    return status in (201, 204), status


def secrets_in(text):
    """True when text holds an app password of a seeded user (the scan before an artifact is uploaded)."""
    for user in USERS:
        value = os.environ.get('NODRIVE_AGENDA_PW_' + user.upper())
        if value and value in text:
            return True
    return False


def safe_name(text):
    return re.sub(r'[^a-zA-Z0-9_.-]+', '-', text).strip('-')
