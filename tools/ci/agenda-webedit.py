#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Nourax
# SPDX-License-Identifier: GPL-3.0-or-later
"""Does the agent survive an edit in the web pages? (design 4.2; CI only; the throwaway server on localhost)

A browser (Playwright with the runner's Chrome) signs in as Ali, edits the title of a tagged event in the Calendar page and of a
tagged to-do in the Tasks page, and the objects are read back through CalDAV. For each page the agent id
(`X-NOURAX-AGENT-ID`) and the tag (`CATEGORIES` value `agent:AG-0001`) are reported as survived or dropped. The step fails only
when both are dropped for one page (then the agent would be lost). When the page could not be driven (the page changed, a dialog
got in the way) that is said in the report as "not driven"; it is not a pass of the design test, and the owner row stays open.
Report: <out>/agenda-webedit.md
"""
import argparse
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import agenda_common as c  # noqa: E402

ROWS = []


def row(name, ok, detail=''):
    ROWS.append((name, ok, detail))
    print(('ok   ' if ok else 'FAIL ') + name + (' - ' + detail if detail else ''))


def info(name, detail):
    ROWS.append((name, None, detail))
    print('info ' + name + ' - ' + detail)


def read(path):
    status, _, data = c.request_retry('ali', 'GET', path)
    return status, data.decode('utf-8', 'replace')


def survival(name, path, expected_title):
    status, text = read(path)
    if status != 200:
        info(name, 'the object could not be read (status %s)' % status)
        return None
    if expected_title not in text:
        info(name, 'not driven: the title did not change in the page (the object was not edited)')
        return None
    kept_id = 'X-NOURAX-AGENT-ID:AG-0001' in text
    kept_tag = bool(re.search(r'^CATEGORIES:.*agent:AG-0001', text, re.M))
    info(name + ': the agent id', 'survived' if kept_id else 'dropped')
    info(name + ': the tag in CATEGORIES', 'survived' if kept_tag else 'dropped')
    row(name + ': the agent is not lost (the id or the tag survived)', kept_id or kept_tag)
    return kept_id, kept_tag


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
    page.goto(base + '/login', wait_until='networkidle', timeout=90000)
    page.fill('input[name="user"]', user)
    page.fill('input[name="password"]', password)
    page.click('button[type="submit"]')
    page.wait_for_url(re.compile(r'.*/apps/.*'), timeout=90000)
    for label in ('Skip', 'Close', 'Dismiss'):
        try:
            page.get_by_role('button', name=label).first.click(timeout=2000)
        except Exception:  # noqa: BLE001 - there may be no dialog
            pass


def edit_task(page, base):
    page.goto(base + '/index.php/apps/tasks/', wait_until='networkidle', timeout=90000)
    page.wait_for_timeout(3000)
    page.get_by_text('Draft report').first.click(timeout=30000)
    page.wait_for_timeout(1500)
    handle = page.evaluate_handle("""() => {
        const all = [...document.querySelectorAll('input, textarea, [contenteditable="true"]')];
        return all.find(e => (e.value || e.textContent || '').trim() === 'Draft report') || null;
    }""").as_element()
    if handle is None:
        raise RuntimeError('no title field with the task title')
    handle.click()
    handle.fill('Draft report (web edit)')
    page.keyboard.press('Tab')
    page.wait_for_timeout(4000)


def edit_event(page, base):
    page.goto(base + '/index.php/apps/calendar/', wait_until='networkidle', timeout=90000)
    page.wait_for_timeout(4000)
    page.locator('.fc-event', has_text='Writer-Bot review').first.click(timeout=30000)
    page.wait_for_timeout(1500)
    try:
        page.get_by_role('button', name=re.compile('Edit', re.I)).first.click(timeout=10000)
    except Exception:  # noqa: BLE001 - the editor may open directly
        pass
    page.wait_for_timeout(1500)
    field = page.locator('input[placeholder*="title" i], input[aria-label*="title" i]').first
    field.click(timeout=15000)
    field.fill('Writer-Bot review (web edit)')
    page.get_by_role('button', name=re.compile('^Save', re.I)).first.click(timeout=15000)
    page.wait_for_timeout(5000)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--out', default='build/agenda-server')
    args = ap.parse_args()
    password = os.environ.get('NODRIVE_AGENDA_LOGIN_PW_ALI')
    if not password:
        info('web edit', 'not driven: no login password of ali in the environment')
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
                context = browser.new_context(viewport={'width': 1400, 'height': 1000})
                page = context.new_page()
                try:
                    login(page, base, 'ali', password)
                    info('web edit sign-in', 'signed in as ali')
                except Exception as e:  # noqa: BLE001
                    info('web edit sign-in', 'not driven: ' + type(e).__name__)
                    page = None
                if page is not None:
                    for label, action in (('Tasks page', edit_task), ('Calendar page', edit_event)):
                        try:
                            action(page, base)
                        except Exception as e:  # noqa: BLE001
                            info(label, 'not driven: %s %s' % (type(e).__name__, str(e).splitlines()[0][:100] if str(e) else ''))
                            diag(page, label, args.out)
                    survival('Tasks page', '/remote.php/dav/calendars/ali/personal/draft-report.ics', 'Draft report (web edit)')
                    survival('Calendar page', '/remote.php/dav/calendars/ali/work/writer-review.ics', 'Writer-Bot review (web edit)')
                browser.close()
    os.makedirs(args.out, exist_ok=True)
    with open(os.path.join(args.out, 'agenda-webedit.md'), 'w', encoding='utf-8') as fh:
        fh.write('# The agent after an edit in the web pages (design 4.2)\n\n')
        for name, ok, detail in ROWS:
            fh.write('- %s %s %s\n' % ('INFO' if ok is None else ('PASS' if ok else 'FAIL'), name, detail))
    failed = [r for r in ROWS if r[1] is False]
    print('web edit: %d rows, %d failed' % (len(ROWS), len(failed)))
    sys.exit(1 if failed else 0)


if __name__ == '__main__':
    main()
