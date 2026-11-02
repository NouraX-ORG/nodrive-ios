#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Nourax
# SPDX-License-Identifier: GPL-3.0-or-later
"""Does the agent survive an edit in the web pages? (design 4.2; CI only; the throwaway server on localhost)

A browser (Playwright with the runner's Chrome) signs in as Ali, edits the title of a tagged event in the Calendar page and of a
tagged to-do in the Tasks page, and the objects are read back through CalDAV. For each page the agent id
(`X-NOURAX-AGENT-ID`) and the tag (`CATEGORIES` value `agent:AG-0001`) are reported as survived or dropped.

The pages are driven the way the desktop job drives them (nodrive-desktop tools/ci/agenda-webedit.py, which edits both pages): the
Calendar page through its edit route (the object path in base64) and the Edit button, the Tasks page by clicking the task and its
title, a text field found by its current value, Save (Calendar) or Enter (Tasks), then a wait.

The step FAILS when
  - neither page could be edited (then the design test was not run on this branch: "not driven" is not a pass), or
  - both properties are dropped for a page that was edited (then the agent would be lost there).
When only one page could be driven the step passes with a visible WARNING line in the report and in the job log.
Report: <out>/agenda-webedit.md
"""
import argparse
import base64
import os
import re
import sys
import urllib.parse

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import agenda_common as c  # noqa: E402

ROWS = []
DRIVEN = []


def row(name, ok, detail=''):
    ROWS.append((name, ok, detail))
    print(('ok   ' if ok else 'FAIL ') + name + (' - ' + detail if detail else ''))


def info(name, detail):
    ROWS.append((name, None, detail))
    print('info ' + name + ' - ' + detail)


def warn(name, detail):
    ROWS.append((name, None, 'WARNING ' + detail))
    print('WARNING ' + name + ' - ' + detail)


def read(path):
    status, _, data = c.request_retry('ali', 'GET', path)
    return status, data.decode('utf-8', 'replace')


def survival(name, path, expected_title):
    """Reads the object back. True when the page edited it (the title changed), False when it did not."""
    status, text = read(path)
    if status != 200:
        warn(name, 'the object could not be read (status %s)' % status)
        return False
    if expected_title not in text:
        warn(name, 'not driven: the title did not change in the page (the object was not edited)')
        return False
    kept_id = 'X-NOURAX-AGENT-ID:AG-0001' in text
    kept_tag = bool(re.search(r'^CATEGORIES:.*agent:AG-0001', text, re.M))
    info(name + ': the agent id', 'survived' if kept_id else 'dropped')
    info(name + ': the tag in CATEGORIES', 'survived' if kept_tag else 'dropped')
    row(name + ': the agent is not lost (the id or the tag survived)', kept_id or kept_tag)
    return True


def diag(page, label, out):
    """What the page looks like when it can not be driven (for the next try): a screenshot and the first words on it."""
    try:
        text = page.evaluate(r"() => (document.body.innerText || '').replace(/\s+/g, ' ').slice(0, 400)")
        counts = page.evaluate("() => ({events: document.querySelectorAll('.fc-event').length, inputs: document.querySelectorAll('input, textarea').length, "
                               "editable: document.querySelectorAll('[contenteditable=true]').length})")
        info(label + ' page', 'text: %s | %s' % (text, counts))
        page.screenshot(path=os.path.join(out, 'webedit-%s.png' % label.split()[0].lower()))
    except Exception as e:  # noqa: BLE001
        info(label + ' page', 'no diagnosis (%s)' % type(e).__name__)


def login(page, base, user, password):
    page.goto(base + '/login', wait_until='domcontentloaded')
    page.wait_for_selector('input[name="user"]', timeout=60000)
    page.fill('input[name="user"]', user)
    page.fill('input[name="password"]', password)
    page.locator('button[type="submit"]').first.click()
    page.wait_for_url(re.compile(r'/(apps|index\.php/apps)/'), timeout=90000)


def dismiss_first_run(page):
    """The first-run wizard and the app tour, if they are shown."""
    for label in ('Skip', 'Close', 'Got it', 'Finish', 'Next'):
        try:
            button = page.get_by_role('button', name=label).first
            if button.is_visible(timeout=1500):
                button.click()
        except Exception:  # noqa: BLE001 - there may be no dialog
            pass
    try:
        page.keyboard.press('Escape')
    except Exception:  # noqa: BLE001
        pass


def type_title(page, old, new):
    """Finds the text field that holds the old title and writes the new one."""
    for locator in (page.get_by_role('textbox'), page.locator('input[type=text]'), page.locator('textarea')):
        for i in range(locator.count()):
            field = locator.nth(i)
            try:
                if field.is_visible() and field.input_value() == old:
                    field.fill(new)
                    return True
            except Exception:  # noqa: BLE001
                continue
    locator = page.locator('[contenteditable=true]')
    for i in range(locator.count()):
        field = locator.nth(i)
        try:
            if field.is_visible() and (field.inner_text() or '').strip() == old:
                field.fill(new)
                return True
        except Exception:  # noqa: BLE001
            continue
    return False


def click_save(page):
    for name in ('Save', 'Update', 'Done'):
        try:
            button = page.get_by_role('button', name=re.compile(r'^\s*%s\s*$' % name, re.I)).first
            if button.is_visible(timeout=2000):
                button.click()
                return True
        except Exception:  # noqa: BLE001
            continue
    return False


def open_calendar_editor(page, url, old):
    """The route opens the event in a read-only popover: its Edit button opens the editor."""
    page.goto(url, wait_until='domcontentloaded')
    page.wait_for_timeout(6000)
    for _ in range(3):
        try:
            edit = page.get_by_role('button', name=re.compile(r'^\s*Edit\s*$')).first
            if edit.is_visible():
                edit.click()
                page.wait_for_timeout(3000)
                return
        except Exception:  # noqa: BLE001
            pass
        page.wait_for_timeout(2000)


def open_task_details(page, url, old):
    """The list of the Tasks app: a click on the task opens its details with the title field."""
    page.goto(url, wait_until='domcontentloaded')
    page.wait_for_timeout(6000)
    try:
        page.get_by_text(old, exact=True).first.click()
    except Exception:  # noqa: BLE001
        page.get_by_text(old).first.click()
    page.wait_for_timeout(3000)
    # The title in the header of the details (the right part of the page) is the field: a click makes it editable.
    matches = page.get_by_text(old, exact=True)
    for i in range(matches.count()):
        try:
            box = matches.nth(i).bounding_box()
            if box and box['x'] > 900 and matches.nth(i).is_visible():
                matches.nth(i).click()
                page.wait_for_timeout(1500)
                break
        except Exception:  # noqa: BLE001
            continue


def drive(label, page, url, old, new, opener, saves_with_enter, out):
    """Opens the item, changes the title, saves. Raises nothing: a page that can not be driven is reported."""
    try:
        opener(page, url, old)
        if not type_title(page, old, new):
            raise RuntimeError('no title field with the task title' if saves_with_enter else 'no title field with the event title')
        if saves_with_enter:
            page.keyboard.press('Enter')   # the Tasks app saves the title with Enter
        elif not click_save(page):
            raise RuntimeError('no Save button')
        page.wait_for_timeout(5000)
    except Exception as e:  # noqa: BLE001
        warn(label, 'not driven: %s %s' % (type(e).__name__, str(e).splitlines()[0][:100] if str(e) else ''))
        diag(page, label, out)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--out', default='build/agenda-server')
    args = ap.parse_args()
    os.makedirs(args.out, exist_ok=True)
    password = os.environ.get('NODRIVE_AGENDA_LOGIN_PW_ALI')
    if not password:
        row('web edit: the sign-in password of ali is in the environment', False, 'the step needs it to drive the web pages')
    else:
        try:
            from playwright.sync_api import sync_playwright
        except ImportError:
            row('playwright is installed', False)
            sync_playwright = None
        if sync_playwright:
            base = 'http://localhost:%d' % c.port()
            with sync_playwright() as p:
                try:
                    browser = p.chromium.launch(channel='chrome')
                except Exception:  # noqa: BLE001
                    browser = p.chromium.launch()
                context = browser.new_context(viewport={'width': 1400, 'height': 900}, locale='en-GB', timezone_id='Europe/Berlin')
                page = context.new_page()
                page.set_default_timeout(30000)
                try:
                    login(page, base, 'ali', password)
                    info('web edit sign-in', 'signed in as ali')
                except Exception as e:  # noqa: BLE001
                    info('web edit sign-in', 'not driven: ' + type(e).__name__)
                    page = None
                if page is not None:
                    dismiss_first_run(page)
                    event_path = '/remote.php/dav/calendars/ali/work/writer-review.ics'
                    encoded = urllib.parse.quote(base64.b64encode(event_path.encode()).decode(), safe='')
                    drive('Calendar page', page, '%s/index.php/apps/calendar/edit/%s' % (base, encoded), 'Writer-Bot review',
                          'Writer-Bot review (web edit)', open_calendar_editor, False, args.out)
                    if survival('Calendar page', event_path, 'Writer-Bot review (web edit)'):
                        DRIVEN.append('Calendar page')
                    drive('Tasks page', page, base + '/index.php/apps/tasks/', 'Draft report', 'Draft report (web edit)', open_task_details, True, args.out)
                    if survival('Tasks page', '/remote.php/dav/calendars/ali/personal/draft-report.ics', 'Draft report (web edit)'):
                        DRIVEN.append('Tasks page')
                browser.close()
        # Design 4.2 needs the proof: at least one page edited. "Not driven" on both is a failure, never a pass.
        row('web edit: at least one of the two pages was edited and read back', len(DRIVEN) >= 1, 'edited: %s' % (', '.join(DRIVEN) or 'none'))
        if len(DRIVEN) == 1:
            warn('web edit', 'only %s could be driven; the other page was not edited on this run (the desktop and Android jobs edit both)' % DRIVEN[0])
    with open(os.path.join(args.out, 'agenda-webedit.md'), 'w', encoding='utf-8') as fh:
        fh.write('# The agent after an edit in the web pages (design 4.2)\n\n')
        for name, ok, detail in ROWS:
            fh.write('- %s %s %s\n' % ('INFO' if ok is None else ('PASS' if ok else 'FAIL'), name, detail))
    failed = [r for r in ROWS if r[1] is False]
    print('web edit: %d rows, %d failed' % (len(ROWS), len(failed)))
    sys.exit(1 if failed else 0)


if __name__ == '__main__':
    main()
