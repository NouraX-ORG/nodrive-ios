#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Nourax
# SPDX-License-Identifier: GPL-3.0-or-later
"""Network gate for the CI screenshot job (spec section 3, "No calls to Nextcloud services").

Inputs:
  --dns-text      output of `tcpdump -n -r dns.pcap` (all DNS packets on the runner
                  while the simulator ran NoDrive; the simulator resolves through the Mac)
  --stand-in-log  JSON lines written by tools/ci/drive-stand-in.py

Fails (exit 1) when
  - a DNS query names a Nextcloud, ownCloud, Firebase, Crashlytics or app-measurement host;
  - the capture saw no DNS at all, or not the --control name (capture not working);
  - fewer than --expect-sign-ins browser page loads of https://drive.nourax.org/login/v2/flow/...
    reached the stand-in (sign-in did not open the browser at drive.nourax.org);
  - a Login Flow v2 start was sent with a user agent the server 35 rule would not accept
    (USER_AGENT_CLIENT_IOS) or without "NoDrive".
  - with --dns-processes (`tcpdump -n -k -r`, pktap metadata): a DNS query was made on behalf
    of a NoDrive process (the app or an extension) for any name except drive.nourax.org.
    Before sign-in the app has nothing else to look up.
A/AAAA queries for drive.nourax.org are reported: the job maps that name to the local
stand-in in /etc/hosts, so none are expected.
"""

import argparse
import json
import re
import sys
from collections import Counter

FORBIDDEN = re.compile(r'next\s?cloud|own\s?cloud|firebase|crashlytics|app-measurement', re.I)
# tcpdump DNS query line: "... 12345+ [1au] A? www.apple.com. (42)"
QUERY_RE = re.compile(r':\s+\d+\+?%?\s+(?:\[[^\]]*\]\s+)?([A-Za-z0-9]+)\?\s+(\S+?)\.?\s+\(')
SERVER_UA_IOS = re.compile(r'^Mozilla/5\.0 \(iOS\) (?:ownCloud|Nextcloud)\-iOS/([^ ]*).*$')   # server 35 IRequest.php
DRIVE = 'drive.nourax.org'
FOREIGN = 'foreign.nodrive-ci.test'   # the other host of the Workspace link test (a name the CI makes up)
# Executable names of NoDrive's app and extensions (the product names; the app's is still "Nextcloud").
APP_PROCESSES = ['Nextcloud', 'Share', 'File Provider Extension', 'File Provider Extension UI',
                 'Notification Service Extension', 'Widget', 'WidgetDashboardIntentHandler', 'Action Assistant',
                 'BackgroundUploadExtension']
# pktap metadata: "(en0, proc mDNSResponder:203, eproc com.apple.Safar:34415, svc BE, out, so)"
EPROC_RE = re.compile(r'\beproc ([^,:()]+):\d+')
PROC_RE = re.compile(r'\bproc ([^,:()]+):\d+')


def is_app_process(name):
    """tcpdump shortens process names (about 15 characters)."""
    return any(name == p or (len(name) >= 15 and p.startswith(name)) for p in APP_PROCESSES)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--dns-text', required=True)
    ap.add_argument('--dns-processes', help='tcpdump -k output of the same capture (process of each query)')
    ap.add_argument('--stand-in-log', required=True)
    ap.add_argument('--expect-sign-ins', type=int, default=1)
    ap.add_argument('--control', default='www.apple.com', help='a name the job looked up itself')
    ap.add_argument('--json', help='write the result here')
    args = ap.parse_args()

    problems, notes = [], []

    queries = Counter()
    with open(args.dns_text, encoding='utf-8', errors='replace') as f:
        for line in f:
            m = QUERY_RE.search(line)
            if m:
                queries[(m.group(2).lower().rstrip('.'), m.group(1))] += 1
    names = sorted({n for n, _ in queries})
    forbidden = sorted({n for n in names if FORBIDDEN.search(n)})
    if not queries:
        problems.append('the capture contains no DNS queries at all (capture not working?)')
    if args.control and args.control.lower() not in names:
        problems.append(f'control name {args.control} is missing from the capture (capture not working?)')
    for n in forbidden:
        problems.append(f'DNS query for a forbidden host: {n}')
    drive_addr = sorted(f'{t}? {n}' for (n, t) in queries if n == DRIVE and t in ('A', 'AAAA'))
    drive_other = sorted(f'{t}? {n}' for (n, t) in queries if n == DRIVE and t not in ('A', 'AAAA'))
    if drive_addr:
        notes.append('address queries for drive.nourax.org reached the network although /etc/hosts maps it: '
                     + ', '.join(drive_addr))
    if drive_other:
        notes.append('other record types asked for drive.nourax.org (DNS only, no connection): ' + ', '.join(drive_other))

    by_process, app_queries = Counter(), Counter()
    if args.dns_processes:
        with open(args.dns_processes, encoding='utf-8', errors='replace') as f:
            for line in f:
                q = QUERY_RE.search(line)
                if not q:
                    continue
                m = EPROC_RE.search(line) or PROC_RE.search(line)
                proc = m.group(1).strip() if m else '?'
                by_process[proc] += 1
                name = q.group(2).lower().rstrip('.')
                if is_app_process(proc):
                    app_queries[(proc, name)] += 1
        if not by_process:
            problems.append('no process metadata in --dns-processes (capture not on pktap?)')
        for (proc, name), n in sorted(app_queries.items()):
            if name not in (DRIVE, FOREIGN):
                problems.append(f'NoDrive process {proc} looked up {name} ({n}x)')

    entries = []
    with open(args.stand_in_log, encoding='utf-8') as f:
        for line in f:
            line = line.strip()
            if line:
                entries.append(json.loads(line))
    events = Counter(e.get('event', f"{e.get('method')} {e.get('path', '').split('?')[0]}") for e in entries)
    starts = [e for e in entries if e.get('event') == 'login-flow-v2-start']
    pages = [e for e in entries if e.get('event') == 'browser-opened-login-page']
    tls_fail = [e for e in entries if e.get('event') == 'tls-handshake-failed']
    status = [e for e in entries if e.get('path', '').split('?')[0] == '/status.php']
    login_uas = sorted({e.get('user_agent', '') for e in starts})
    status_uas = sorted({e.get('user_agent', '') for e in status})
    browser_uas = sorted({e.get('user_agent', '') for e in pages})
    if len(pages) < args.expect_sign_ins:
        problems.append(f'the browser opened https://{DRIVE}/login/v2/flow/... {len(pages)}x, '
                        f'expected at least {args.expect_sign_ins}x (one per UI walk)')
    for ua in login_uas:
        m = SERVER_UA_IOS.match(ua)
        if not m or 'NoDrive' not in ua:
            problems.append(f'Login Flow v2 start sent an unexpected user agent: {ua!r}')
    for e in pages + starts:
        if e.get('host') != DRIVE or e.get('sni') != DRIVE:
            problems.append(f"request without Host/SNI {DRIVE}: {e}")

    result = {
        'ok': not problems,
        'problems': problems,
        'notes': notes,
        'dns_names': names,
        'dns_query_count': sum(queries.values()),
        'forbidden_names': forbidden,
        'dns_queries_by_process': dict(by_process.most_common()),
        'dns_queries_by_nodrive_processes': {f'{p} {n}': c for (p, n), c in sorted(app_queries.items())},
        'stand_in_events': dict(sorted(events.items())),
        'login_flow_starts': len(starts),
        'browser_page_loads': len(pages),
        'tls_handshake_failures': len(tls_fail),
        'login_user_agents': login_uas,
        'login_user_agent_version_group': sorted({SERVER_UA_IOS.match(u).group(1) for u in login_uas if SERVER_UA_IOS.match(u)}),
        'status_user_agents': status_uas,
        'browser_user_agents': browser_uas,
    }
    if args.json:
        with open(args.json, 'w', encoding='utf-8') as f:
            json.dump(result, f, indent=2, ensure_ascii=False)

    print(f'network-gate: {result["dns_query_count"]} DNS queries for {len(names)} names; '
          f'forbidden {len(forbidden)}; stand-in: status.php {len(status)}, login starts {len(starts)}, '
          f'browser page loads {len(pages)}, TLS failures {len(tls_fail)}')
    print('DNS names seen:')
    for n in names:
        print('   ', n)
    if args.dns_processes:
        print('DNS queries by process (top 12):', by_process.most_common(12))
        print('DNS queries made for NoDrive processes:', dict(app_queries) or 'none')
    print('Login Flow v2 user agents:', login_uas)
    print('status.php user agents:   ', status_uas)
    print('browser user agents:      ', browser_uas)
    for n in notes:
        print('note:', n)
    for p in problems:
        print('PROBLEM:', p)
    print('network-gate:', 'ok' if not problems else f'{len(problems)} problem(s)')
    return 0 if not problems else 1


if __name__ == '__main__':
    sys.exit(main())
