#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Nourax
# SPDX-License-Identifier: GPL-3.0-or-later
"""Check the built NoDrive simulator app (CI, after xcodebuild).

For the app and every embedded extension (PlugIns/*.appex and Extensions/*.appex):
  * reads Info.plist (binary or XML) and checks the bundle id, display name and,
    for the app, the URL scheme;
  * reads the entitlements the build put into the executable: the Mach-O
    section __TEXT,__entitlements (simulator builds) and the entitlements blob
    of an embedded code signature, if any; checks the app group and keychain group.
Then it searches every file of the bundle for links to Nextcloud services
(push proxy, nextcloud.com, App Store links to Nextcloud apps, Firebase hosts)
and prints what it finds.

Exit 1 when an id, display name, URL scheme, app group or extension is wrong or
missing. Link findings are reported (and written to --json); they fail the run
only for the push proxy and App Store links to Nextcloud's apps.

Usage: python3 tools/ci/inspect-products.py path/to/Nextcloud.app [--json out.json]
Standard library only.
"""
import argparse
import json
import os
import plistlib
import re
import struct
import sys
from collections import defaultdict

BASE = 'org.nourax.nodrive'
GROUP = 'group.' + BASE
# bundle folder -> (bundle id, display name)
EXPECTED = {
    '.': (BASE, 'NoDrive'),
    'PlugIns/Share.appex': (BASE + '.share', 'NoDrive'),
    'PlugIns/File Provider Extension.appex': (BASE + '.file-provider', 'NoDrive'),
    'PlugIns/File Provider Extension UI.appex': (BASE + '.file-provider-ui', 'NoDrive'),
    'PlugIns/Notification Service Extension.appex': (BASE + '.notification-service', 'NoDrive'),
    'PlugIns/Widget.appex': (BASE + '.widget', 'NoDrive'),
    'PlugIns/WidgetDashboardIntentHandler.appex': (BASE + '.widget-intent-handler', 'NoDrive'),
    'PlugIns/Action Assistant.appex': (BASE + '.action-assistant', 'NoDrive Assistant'),
    'Extensions/BackgroundUploadExtension.appex': (BASE + '.background-upload', 'NoDrive'),
}

# Links that must not ship (fail) and links that are reported for the record.
FAIL_PATTERNS = [
    ('push-proxy', re.compile(rb'push-notifications\.nextcloud\.com', re.I)),
    ('appstore-nextcloud', re.compile(rb'apps\.apple\.com/[\x21-\x7e]{0,60}(?:nextcloud|id1125420102|id1296825574|id813973264)', re.I)),
]
REPORT_PATTERNS = [
    ('nextcloud-url', re.compile(rb'https?://[\x21-\x7e]{0,80}next\s?cloud[\x21-\x7e]{0,80}', re.I)),
    ('nextcloud.com', re.compile(rb'[a-z0-9.-]{0,40}nextcloud\.com[\x21-\x7e]{0,60}', re.I)),
    ('apps.apple.com', re.compile(rb'https?://(?:apps|itunes)\.apple\.com[\x21-\x7e]{0,80}', re.I)),
    ('app-store-id', re.compile(rb'(?<![0-9])(?:id)?(?:1125420102|1296825574|813973264)(?![0-9])')),
    ('firebase-host', re.compile(rb'[a-z0-9.-]{0,40}(?:crashlytics|firebaseio|app-measurement|firebase-settings)\.[a-z.]{2,20}', re.I)),
]

MH_MAGIC_64 = 0xfeedfacf
FAT_MAGIC = 0xcafebabe
FAT_MAGIC_64 = 0xcafebabf
LC_SEGMENT_64 = 0x19
LC_CODE_SIGNATURE = 0x1d
CSMAGIC_EMBEDDED_SIGNATURE = 0xfade0cc0
CSMAGIC_EMBEDDED_ENTITLEMENTS = 0xfade7171


def macho_slices(data):
    """Yield (offset, size) of every thin 64-bit Mach-O slice."""
    if len(data) < 8:
        return
    magic_be = struct.unpack('>I', data[:4])[0]
    if magic_be in (FAT_MAGIC, FAT_MAGIC_64):
        n = struct.unpack('>I', data[4:8])[0]
        pos = 8
        for _ in range(n):
            if magic_be == FAT_MAGIC:
                _, _, off, size, _ = struct.unpack('>iiIII', data[pos:pos + 20])
                pos += 20
            else:
                _, _, off, size, _, _ = struct.unpack('>iiQQII', data[pos:pos + 32])
                pos += 32
            if struct.unpack('<I', data[off:off + 4])[0] == MH_MAGIC_64:
                yield off, size
    elif struct.unpack('<I', data[:4])[0] == MH_MAGIC_64:
        yield 0, len(data)


def macho_entitlements(data):
    """Return {'section': plist-or-None, 'signature': plist-or-None} from the first 64-bit slice."""
    out = {'section': None, 'signature': None}
    for base, _ in macho_slices(data):
        ncmds, sizeofcmds = struct.unpack('<II', data[base + 16:base + 24])
        pos = base + 32
        for _ in range(ncmds):
            cmd, cmdsize = struct.unpack('<II', data[pos:pos + 8])
            if cmd == LC_SEGMENT_64:
                segname = data[pos + 8:pos + 24].rstrip(b'\0')
                nsects = struct.unpack('<I', data[pos + 64:pos + 68])[0]
                spos = pos + 72
                for _ in range(nsects):
                    sectname = data[spos:spos + 16].rstrip(b'\0')
                    size, offset = struct.unpack('<QI', data[spos + 40:spos + 52])
                    if segname == b'__TEXT' and sectname == b'__entitlements' and size:
                        blob = data[base + offset:base + offset + size]
                        try:
                            out['section'] = plistlib.loads(blob.rstrip(b'\0'))
                        except Exception as e:  # noqa: BLE001
                            out['section'] = f'<unreadable: {e}>'
                    spos += 80
            elif cmd == LC_CODE_SIGNATURE:
                dataoff, datasize = struct.unpack('<II', data[pos + 8:pos + 16])
                sig = data[base + dataoff:base + dataoff + datasize]
                if len(sig) >= 12 and struct.unpack('>I', sig[:4])[0] == CSMAGIC_EMBEDDED_SIGNATURE:
                    count = struct.unpack('>I', sig[8:12])[0]
                    for i in range(count):
                        _, boff = struct.unpack('>II', sig[12 + 8 * i:20 + 8 * i])
                        magic, length = struct.unpack('>II', sig[boff:boff + 8])
                        if magic == CSMAGIC_EMBEDDED_ENTITLEMENTS:
                            try:
                                out['signature'] = plistlib.loads(sig[boff + 8:boff + length])
                            except Exception as e:  # noqa: BLE001
                                out['signature'] = f'<unreadable: {e}>'
            pos += cmdsize
        break
    return out


def url_schemes(info):
    return [s for t in info.get('CFBundleURLTypes', []) for s in t.get('CFBundleURLSchemes', [])]


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('app')
    ap.add_argument('--json')
    args = ap.parse_args()
    app = os.path.abspath(args.app)
    problems, report = [], {'bundles': {}, 'links': {}}

    bundles = ['.'] + sorted(os.path.relpath(os.path.join(app, d, x), app).replace(os.sep, '/')
                             for d in ('PlugIns', 'Extensions') if os.path.isdir(os.path.join(app, d))
                             for x in os.listdir(os.path.join(app, d)) if x.endswith('.appex'))
    for missing in sorted(set(EXPECTED) - set(bundles)):
        problems.append(f'{missing}: extension missing from the build')
    for extra in sorted(set(bundles) - set(EXPECTED)):
        problems.append(f'{extra}: unexpected bundle (add it to EXPECTED with its NoDrive id)')

    print('== bundles')
    for rel in bundles:
        path = os.path.normpath(os.path.join(app, rel))
        with open(os.path.join(path, 'Info.plist'), 'rb') as f:
            info = plistlib.load(f)
        exe = info.get('CFBundleExecutable', '')
        with open(os.path.join(path, exe), 'rb') as f:
            ents = macho_entitlements(f.read())
        bid = info.get('CFBundleIdentifier')
        name = info.get('CFBundleDisplayName')
        entry = {'CFBundleIdentifier': bid, 'CFBundleDisplayName': name, 'CFBundleName': info.get('CFBundleName'),
                 'CFBundleExecutable': exe, 'CFBundleShortVersionString': info.get('CFBundleShortVersionString'),
                 'CFBundleVersion': info.get('CFBundleVersion'), 'URLSchemes': url_schemes(info),
                 'NouraxVersion': info.get('NouraxVersion'),
                 'NSExtensionPointIdentifier': (info.get('NSExtension') or {}).get('NSExtensionPointIdentifier')
                 or (info.get('EXAppExtensionAttributes') or {}).get('EXExtensionPointIdentifier'),
                 'NSExtensionFileProviderDocumentGroup': (info.get('NSExtension') or {}).get('NSExtensionFileProviderDocumentGroup'),
                 'entitlements_section': ents['section'], 'entitlements_signature': ents['signature']}
        report['bundles'][rel] = entry
        print(f'-- {rel}')
        for k, v in entry.items():
            print(f'   {k}: {v}')

        exp = EXPECTED.get(rel)
        if exp:
            if bid != exp[0]:
                problems.append(f'{rel}: CFBundleIdentifier {bid!r}, expected {exp[0]!r}')
            if name != exp[1]:
                problems.append(f'{rel}: CFBundleDisplayName {name!r}, expected {exp[1]!r}')
        if rel == '.':
            if entry['URLSchemes'] != ['nodrive']:
                problems.append(f'app: URL schemes {entry["URLSchemes"]}, expected [\'nodrive\']')
            if info.get('NouraxVersion') != '35.2.1-nourax.1':
                problems.append(f'app: NouraxVersion {info.get("NouraxVersion")!r}')
        if entry['NSExtensionFileProviderDocumentGroup'] not in (None, GROUP):
            problems.append(f'{rel}: file-provider document group {entry["NSExtensionFileProviderDocumentGroup"]!r}')
        for src in ('entitlements_section', 'entitlements_signature'):
            e = entry[src]
            if isinstance(e, dict):
                groups = e.get('com.apple.security.application-groups', [])
                if groups and groups != [GROUP]:
                    problems.append(f'{rel}: {src} app groups {groups}, expected [{GROUP!r}]')
                kc = e.get('keychain-access-groups', [])
                if any(not g.endswith(BASE) for g in kc):
                    problems.append(f'{rel}: {src} keychain groups {kc}')
                if 'aps-environment' in e:
                    problems.append(f'{rel}: {src} still has aps-environment')

    print('== links to Nextcloud services in the bundle')
    found = defaultdict(lambda: defaultdict(set))
    fail_found = defaultdict(set)
    for dirpath, dirnames, filenames in os.walk(app):
        dirnames.sort()
        for fn in sorted(filenames):
            full = os.path.join(dirpath, fn)
            rel = os.path.relpath(full, app).replace(os.sep, '/')
            with open(full, 'rb') as f:
                data = f.read()
            for label, rx in FAIL_PATTERNS:
                for m in rx.findall(data):
                    fail_found[label].add(f'{rel}: {m.decode("ascii", "replace")}')
            for label, rx in REPORT_PATTERNS:
                for m in rx.findall(data):
                    found[label][m.decode('ascii', 'replace')].add(rel)
    for label, _ in REPORT_PATTERNS:
        items = found.get(label, {})
        print(f'-- {label}: {len(items)} distinct')
        for text, files in sorted(items.items()):
            print(f'   {text!r} in {", ".join(sorted(files)[:4])}{" ..." if len(files) > 4 else ""}')
        report['links'][label] = {t: sorted(fs) for t, fs in sorted(items.items())}
    for label, _ in FAIL_PATTERNS:
        items = sorted(fail_found.get(label, []))
        print(f'-- {label} (must be none): {len(items)}')
        for it in items:
            print(f'   {it}')
            problems.append(f'{label}: {it}')
        report['links'][label] = items

    report['problems'] = problems
    if args.json:
        with open(args.json, 'w', encoding='utf-8') as f:
            json.dump(report, f, indent=1, default=str)
    print('== result')
    for p in problems:
        print(f'PROBLEM {p}')
    print(f'inspect-products: {len(bundles)} bundles, {len(problems)} problems')
    sys.exit(1 if problems else 0)


if __name__ == '__main__':
    main()
