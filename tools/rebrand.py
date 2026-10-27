#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Nourax
# SPDX-License-Identifier: GPL-3.0-or-later
"""Apply the NoDrive (by Nourax) branding to the Nextcloud iOS source tree.

Idempotent: every operation is "set to the NoDrive value" or "replace the
upstream text, or confirm that the NoDrive text is already there". A second run
changes nothing. After merging a new upstream release, run it again; when an
anchor is gone or appears twice the tool stops with a clear message instead of
guessing.

What it changes (see docs/branding.md and plans/ios-plan.md):
  * Brand/NCBrand.swift      brand name, fixed server, ids, links off, colours, user agent
  * Brand/Intro/*            fixed-server Login Flow v2 from the intro, 2 slides
  * Brand/*.plist            display names, URL scheme, file-provider group, NouraxVersion,
                             NouraxPrivacyURL, export-compliance code removed
  * Brand/*.entitlements     app group, keychain group, no push, no second group
  * project.pbxproj          bundle ids of all 12 targets, display names, team, version,
                             NOURAX_* build settings, Nextcloud resources and the
                             Crashlytics upload phase removed, NoDrive tests added
  * xcschemes                BundleIdentifier of the remote runnable
  * *.lproj/*.strings        the few values that name Nextcloud, in every language
  * storyboards / XIBs       launch colour, placeholder texts
  * folder SVGs, glyph PDFs  Nextcloud blues in the folder, directory and document glyphs
  * a few Swift files        URL scheme, links to Nextcloud services, privacy link guard
  * Acknowledgements.rtf     text-only licence page from tools/legal/third-party.json
  * Brand/NoDriveBlank.pdf   replaces "Reasons to use Nextcloud.pdf" (scan preview fallback)
Images come from tools/make-icons.py, not from this tool.

Usage:
  python3 tools/rebrand.py                    apply
  python3 tools/rebrand.py --check            exit 1 if a run would change anything
  python3 tools/rebrand.py --bundle-base org.nourax.nodrive.devXY
                                              derive every id from another base (for a
                                              local free-Apple-ID device test; do not commit)
"""
import argparse
import hashlib
import json
import os
import plistlib
import re
import sys
import zlib
from collections import Counter

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..'))

# --------------------------------------------------------------------------
# Configuration (one place for every NoDrive value)
# --------------------------------------------------------------------------
APP_NAME = 'NoDrive'
MAKER = 'Nourax'
SERVER_URL = 'https://drive.nourax.org'
SERVER_NAME = 'Nourax Workspace'          # what the server calls itself (themed Nextcloud)
URL_SCHEME = 'nodrive'
VERSION_SUFFIX = '-nourax.1'             # shown as <MARKETING_VERSION><suffix>, e.g. 35.2.1-nourax.1
BUILD_NUMBER = '1'                       # CURRENT_PROJECT_VERSION (CFBundleVersion); bump with the suffix
PRIVACY_URL = ''                         # NOURAX_PRIVACY_URL; empty = privacy link hidden (owner to-do)
COPYRIGHT = 'NoDrive by Nourax'
DEFAULT_BUNDLE_BASE = 'org.nourax.nodrive'

PRIMARY = (0x25, 0x63, 0xEB)             # #2563EB cobalt
PRIMARY_LIGHT = (0x3B, 0x82, 0xF6)       # #3B82F6
ACCENT = (0xF9, 0x73, 0x16)              # #F97316

# Native target -> bundle id suffix ('' = the base itself)
TARGET_IDS = {
    'Nextcloud': '',
    'Share': '.share',
    'File Provider Extension': '.file-provider',
    'File Provider Extension UI': '.file-provider-ui',
    'Notification Service Extension': '.notification-service',
    'Widget': '.widget',
    'WidgetDashboardIntentHandler': '.widget-intent-handler',
    'Action Assistant': '.action-assistant',
    'BackgroundUploadExtension': '.background-upload',
    'NextcloudUnitTests': '.unit-tests',
    'NextcloudUITests': '.ui-tests',
    'NextcloudIntegrationTests': '.integration-tests',
}
# Targets whose display name comes from INFOPLIST_KEY_CFBundleDisplayName
PBX_DISPLAY_NAME_TARGETS = ['Widget', 'WidgetDashboardIntentHandler', 'File Provider Extension UI',
                            'BackgroundUploadExtension']
# Brand/*.plist -> CFBundleDisplayName
PLIST_DISPLAY_NAMES = {
    'Brand/iOSClient.plist': APP_NAME,
    'Brand/Share.plist': APP_NAME,                              # share-sheet name
    'Brand/File_Provider_Extension.plist': APP_NAME,            # Files-app location name
    'Brand/File_Provider_Extension_UI.plist': APP_NAME,
    'Brand/Notification_Service_Extension.plist': APP_NAME,
    'Brand/Action_Assistant.plist': f'{APP_NAME} Assistant',    # action-sheet name
}
BRAND_PLISTS = ['Brand/iOSClient.plist', 'Brand/Share.plist', 'Brand/File_Provider_Extension.plist',
                'Brand/File_Provider_Extension_UI.plist', 'Brand/Notification_Service_Extension.plist',
                'Brand/Widget.plist', 'Brand/WidgetDashboardIntentHandler.plist', 'Brand/Action_Assistant.plist',
                'Brand/BackgroundUploadExtension.plist']
ENTITLEMENTS = ['Brand/iOSClient.entitlements', 'Brand/Share.entitlements',
                'Brand/File_Provider_Extension.entitlements', 'Brand/File_Provider_Extension_UI.entitlements',
                'Brand/Notification_Service_Extension.entitlements', 'Brand/Widget.entitlements',
                'Brand/WidgetDashboardIntentHandler.entitlements', 'Brand/Action_Assistant.entitlements',
                'Brand/BackgroundUploadExtension.entitlements']
# App-target resources that are Nextcloud artwork, Firebase config or a developer document
# (iOSClient/Viewer/NCViewerMedia/README.md) - not shipped by NoDrive
REMOVE_APP_RESOURCES = ['AppIcon.icon', 'GoogleService-Info.plist', 'Nextcloud Hub.png', 'README.md']
REMOVE_APP_PHASES = ['Crashlytics dSYM Upload']
# Our test files, added to the test targets: (target, group path, file)
TEST_FILES = [
    ('NextcloudUnitTests', 'NextcloudUnitTests', 'NoDriveBrandingTests.swift'),
    ('NextcloudUnitTests', 'NextcloudUnitTests', 'NoDriveWorkspaceOriginTests.swift'),
    ('NextcloudUnitTests', 'NextcloudUnitTests', 'NoDriveWorkspaceAppsTests.swift'),
    ('NextcloudUnitTests', 'NextcloudUnitTests', 'NoDriveWorkspaceSessionTests.swift'),
    ('NextcloudUnitTests', 'NextcloudUnitTests', 'NoDriveWorkspaceWebTests.swift'),
    ('NextcloudUnitTests', 'NextcloudUnitTests', 'NoDriveWorkspaceMenuTests.swift'),
    ('NextcloudUITests', 'NextcloudUITests', 'NoDriveScreenshotUITests.swift'),
    ('NextcloudUITests', 'NextcloudUITests', 'NoDriveWorkspaceUITests.swift'),
]
# Our own source folders of the app target, each a new group inside its parent group:
# (target, folder, parent group name). Every .swift file of the folder is added.
APP_SOURCE_FOLDERS = [
    ('Nextcloud', 'iOSClient/Workspace', 'iOSClient'),
]
# Product of the UI-test target. Its runner app ("<product>-Runner") sits on the simulator's home
# screen during the screenshot walk, so it must not carry the Nextcloud name. The target name
# (NextcloudUITests, used by -only-testing) stays.
UI_TEST_PRODUCT = 'NoDriveUITests'

# Translations: keys whose values name the product, and what replaces the name.
STRINGS_APP_KEYS = ['_access_photo_not_enabled_msg_', '_privacy_footer_', '_no_client_cert_found_desc_']
STRINGS_SERVER_KEYS = ['_warning_unsupported_', '_background_upload_extension_apache_warning_']
STRINGS_COPY_KEYS = {'_warning_owncloud_': '_warning_unsupported_'}   # ownCloud -> same text as "unsupported"
# Every spelling of the product name found in the shipped languages (Latin, Arabic, Korean, Japanese).
NAME_RE = re.compile(r'(?<![/.@A-Za-z])(?:[Nn]ext\s?[Cc]loud(?:\s?iOS)?[a-z]{0,2}(?![A-Za-z])'
                     r'|نكست\s?كلاود|넥스트\s?클라우드|ネクスト\s?クラウド)')
FORMAT_RE = re.compile(r'%(?:\d+\$)?[-+ #0]*\d*(?:\.\d+)?(?:hh|h|ll|l|q|z|t|j|L)?[@dDuUxXoOfeEgGcCsSpaAiF%]')


class RebrandError(Exception):
    pass


def fail(msg):
    raise RebrandError(msg)


def hex_colour(rgb):
    return '#%02X%02X%02X' % rgb


# --------------------------------------------------------------------------
# File store: read once, edit in memory, write at the end (or only report)
# --------------------------------------------------------------------------
def decode(data):
    if data.startswith(b'\xff\xfe'):
        return 'utf-16-le-bom', data[2:].decode('utf-16-le')
    if data.startswith(b'\xef\xbb\xbf'):
        return 'utf-8-bom', data[3:].decode('utf-8')
    return 'utf-8', data.decode('utf-8')


def encode(codec, text):
    if codec == 'utf-16-le-bom':
        return b'\xff\xfe' + text.encode('utf-16-le')
    if codec == 'utf-8-bom':
        return b'\xef\xbb\xbf' + text.encode('utf-8')
    if codec == 'bytes':
        return text
    return text.encode('utf-8')


class Store:
    def __init__(self, root):
        self.root = root
        self.files = {}   # rel -> {'orig': bytes|None, 'codec': str, 'text': str|bytes|None}

    def path(self, rel):
        return os.path.join(self.root, rel)

    def _load(self, rel, binary=False):
        if rel not in self.files:
            p = self.path(rel)
            if os.path.exists(p):
                with open(p, 'rb') as f:
                    data = f.read()
                codec, text = ('bytes', data) if binary else decode(data)
                self.files[rel] = {'orig': data, 'codec': codec, 'text': text}
            else:
                self.files[rel] = {'orig': None, 'codec': 'bytes' if binary else 'utf-8', 'text': None}
        return self.files[rel]

    def exists(self, rel):
        return self._load(rel)['text'] is not None

    def get(self, rel):
        f = self._load(rel)
        if f['text'] is None:
            fail(f'{rel}: file not found')
        if f['codec'] == 'bytes':
            fail(f'internal: {rel} is a binary file (use get_bytes)')
        return f['text']

    def get_bytes(self, rel):
        """Raw bytes of a binary file (a PDF), never decoded."""
        f = self._load(rel, binary=True)
        if f['text'] is None:
            fail(f'{rel}: file not found')
        if f['codec'] != 'bytes':
            fail(f'internal: {rel} was loaded as text')
        return f['text']

    def set(self, rel, text, codec=None):
        f = self._load(rel)
        f['text'] = text
        if codec:
            f['codec'] = codec

    def set_bytes(self, rel, data):
        f = self._load(rel, binary=True)
        f['codec'] = 'bytes'
        f['text'] = data

    def changed(self):
        out = []
        for rel, f in sorted(self.files.items()):
            new = None if f['text'] is None else encode(f['codec'], f['text'])
            if new != f['orig']:
                out.append(rel)
        return out

    def encoded(self, rel):
        f = self.files[rel]
        return encode(f['codec'], f['text'])

    def write(self):
        for rel in self.changed():
            p = self.path(rel)
            os.makedirs(os.path.dirname(p), exist_ok=True)
            with open(p, 'wb') as fh:
                fh.write(self.encoded(rel))


# --------------------------------------------------------------------------
# Generic text operations
# --------------------------------------------------------------------------
def sub_exact(st, rel, old, new, count=1):
    """Replace `old` by `new` (exactly `count` times; None = at least once),
    or accept that `new` is already there."""
    if old in new:
        fail(f'internal: replacement for {old!r} contains the original')
    text = st.get(rel)
    n = text.count(old)
    if n:
        if count is not None and n != count:
            fail(f'{rel}: expected {count}x {old[:60]!r}, found {n}x')
        st.set(rel, text.replace(old, new))
    elif new not in text:
        fail(f'{rel}: anchor not found (upstream changed?): {old[:80]!r}')


def insert_before(st, rel, anchor, addition):
    """Insert `addition` right before the one `anchor`, unless already there."""
    text = st.get(rel)
    if addition + anchor in text:
        return
    if text.count(anchor) != 1:
        fail(f'{rel}: anchor found {text.count(anchor)}x: {anchor[:80]!r}')
    st.set(rel, text.replace(anchor, addition + anchor))


def insert_after(st, rel, anchor, addition):
    """Insert `addition` right after the one `anchor`, unless already there."""
    text = st.get(rel)
    if anchor + addition in text:
        return
    if text.count(anchor) != 1:
        fail(f'{rel}: anchor found {text.count(anchor)}x: {anchor[:80]!r}')
    st.set(rel, text.replace(anchor, anchor + addition))


def sub_regex(st, rel, pattern, repl, count=1, flags=re.M):
    """Set-style regex edit: `pattern` must match the upstream AND the NoDrive
    text exactly `count` times (None = at least once)."""
    text = st.get(rel)
    rx = re.compile(pattern, flags)
    n = len(rx.findall(text))
    if (count is None and n == 0) or (count is not None and n != count):
        fail(f'{rel}: pattern {pattern[:80]!r} matched {n}x, expected {count if count is not None else ">=1"}')
    st.set(rel, rx.sub(repl, text))


def swift_string(s):
    return '"' + s.replace('\\', '\\\\').replace('"', '\\"') + '"'


def swift_set_var(st, rel, name, type_, expr):
    """`var <name>: <type> = <anything>` -> `= <expr>` (keeps a trailing // comment)."""
    pattern = (r'^(?P<pre>[ \t]*var ' + re.escape(name) + r': ' + re.escape(type_) + r' = )'
               r'(?P<val>"(?:[^"\\\n]|\\.)*"|[^\n/]+?)(?P<post>[ \t]*(?://[^\n]*)?)$')
    sub_regex(st, rel, pattern, lambda m: m.group('pre') + expr + m.group('post'))


def xml_escape(s):
    return s.replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;')


# --------------------------------------------------------------------------
# Property lists (edited as text to keep upstream formatting; parsed afterwards)
# --------------------------------------------------------------------------
def plist_set_string(st, rel, key, value):
    sub_regex(st, rel, r'(<key>' + re.escape(key) + r'</key>\s*<string>)[^<]*(</string>)',
              lambda m: m.group(1) + xml_escape(value) + m.group(2))


def plist_remove_key(st, rel, key):
    text = st.get(rel)
    rx = re.compile(r'^[ \t]*<key>' + re.escape(key) + r'</key>\n[ \t]*'
                    r'(?:<string>[^<]*</string>|<true/>|<false/>|<array>.*?</array>|<dict>.*?</dict>)\n',
                    re.M | re.S)
    st.set(rel, rx.sub('', text))


def _indent_unit(text):
    m = re.search(r'^([ \t]+)<key>', text, re.M)
    return m.group(1) if m else '\t'


def plist_ensure_string(st, rel, key, value):
    """Set <key> to a string; add it at the end of the root dict when missing."""
    text = st.get(rel)
    if re.search(r'<key>' + re.escape(key) + r'</key>', text):
        plist_set_string(st, rel, key, value)
        return
    ind = _indent_unit(text)
    idx = text.rfind('</dict>')
    if idx < 0:
        fail(f'{rel}: no root dict')
    entry = f'{ind}<key>{key}</key>\n{ind}<string>{xml_escape(value)}</string>\n'
    st.set(rel, text[:idx] + entry + text[idx:])


def plist_set_array(st, rel, key, values):
    """Set the array of strings under <key> to exactly `values`."""
    text = st.get(rel)
    rx = re.compile(r'(?P<head>^(?P<ind>[ \t]*)<key>' + re.escape(key) + r'</key>\n(?P=ind)<array>\n)'
                    r'(?P<body>.*?)(?P<tail>^(?P=ind)</array>)', re.M | re.S)
    ms = list(rx.finditer(text))
    if len(ms) != 1:
        fail(f'{rel}: array {key} found {len(ms)}x')
    m = ms[0]
    ind = m.group('ind')
    item_ind = ind + (('\t' if '\t' in ind else '    ') if ind else _indent_unit(text))
    body = ''.join(f'{item_ind}<string>{xml_escape(v)}</string>\n' for v in values)
    st.set(rel, text[:m.start('body')] + body + text[m.end('body'):])


# --------------------------------------------------------------------------
# project.pbxproj (text edits with anchors; never re-serialised)
# --------------------------------------------------------------------------
HEX24 = re.compile(r'\b[0-9A-F]{24}\b')


def pbx_quote(v):
    return v if re.fullmatch(r'[A-Za-z0-9_$/.]+', v) else '"' + v.replace('\\', '\\\\').replace('"', '\\"') + '"'


class PBX:
    REL = 'Nextcloud.xcodeproj/project.pbxproj'

    def __init__(self, st):
        self.st = st

    @property
    def text(self):
        return self.st.get(self.REL)

    @text.setter
    def text(self, value):
        self.st.set(self.REL, value)

    def block_span(self, obj_id):
        """(start, end) of a multi-line object `\t\t<id> /* .. */ = {` ... `\t\t};`."""
        m = re.search(r'^\t\t' + obj_id + r' (?:/\*.*?\*/ )?= \{\n', self.text, re.M)
        if not m:
            fail(f'pbxproj: object {obj_id} not found')
        end = self.text.find('\n\t\t};\n', m.end())
        if end < 0:
            fail(f'pbxproj: object {obj_id} not terminated')
        return m.start(), end + len('\n\t\t};\n')

    def target_id(self, name):
        ms = re.findall(r'^\t\t([0-9A-F]{24}) /\* ' + re.escape(name) + r' \*/ = \{\n\t\t\tisa = PBXNativeTarget;',
                        self.text, re.M)
        if len(ms) != 1:
            fail(f'pbxproj: native target "{name}" found {len(ms)}x')
        return ms[0]

    def config_ids(self, owner):
        """Build configurations of a target ("Share") or of the project (owner=None)."""
        label = f'PBXProject "Nextcloud"' if owner is None else f'PBXNativeTarget "{owner}"'
        ms = re.findall(r'^\t\t([0-9A-F]{24}) /\* Build configuration list for ' + re.escape(label) + r' \*/ = \{',
                        self.text, re.M)
        if len(ms) != 1:
            fail(f'pbxproj: configuration list for {label} found {len(ms)}x')
        s, e = self.block_span(ms[0])
        ids = re.findall(r'^\t\t\t\t([0-9A-F]{24}) /\* (\w+) \*/,', self.text[s:e], re.M)
        if len(ids) < 2:
            fail(f'pbxproj: {label} has {len(ids)} configurations')
        return [i for i, _ in ids]

    def set_setting(self, cfg_id, key, value):
        s, e = self.block_span(cfg_id)
        block = self.text[s:e]
        bs = block.find('\t\t\tbuildSettings = {\n')
        be = block.find('\n\t\t\t};\n', bs)
        if bs < 0 or be < 0:
            fail(f'pbxproj: {cfg_id} has no buildSettings')
        head, body, tail = block[:bs + len('\t\t\tbuildSettings = {\n')], block[bs + len('\t\t\tbuildSettings = {\n'):be + 1], block[be + 1:]
        line = f'\t\t\t\t{key} = {pbx_quote(value)};\n'
        lines = body.splitlines(keepends=True)
        keyre = re.compile(r'^\t\t\t\t("[^"]*"|[A-Za-z0-9_]+) = (.*)$')
        found = [i for i, ln in enumerate(lines) if (m := keyre.match(ln)) and m.group(1) == key]
        if len(found) > 1:
            fail(f'pbxproj: {key} set {len(found)}x in {cfg_id}')
        if found:
            if keyre.match(lines[found[0]]).group(2).rstrip() in ('(', '{'):
                fail(f'pbxproj: {key} in {cfg_id} is not a scalar')
            lines[found[0]] = line
            out = lines
        else:
            pos = len(lines)
            for i, ln in enumerate(lines):
                m = keyre.match(ln)
                if m and m.group(1).strip('"') > key:
                    pos = i
                    break
            out = lines[:pos] + [line] + lines[pos:]
        block = head + ''.join(out) + tail
        self.text = self.text[:s] + block + self.text[e:]

    def settings_with_key(self, key):
        """Every XCBuildConfiguration that sets `key`."""
        return re.findall(r'^\t\t([0-9A-F]{24}) /\* \w+ \*/ = \{\n\t\t\tisa = XCBuildConfiguration;\n'
                          r'(?:(?!\n\t\t\};\n).)*?\n\t\t\t\t' + re.escape(key) + r' = ',
                          self.text, re.M | re.S)

    def phase_id(self, target, comment):
        s, e = self.block_span(self.target_id(target))
        ms = re.findall(r'^\t\t\t\t([0-9A-F]{24}) /\* ' + re.escape(comment) + r' \*/,', self.text[s:e], re.M)
        if len(ms) != 1:
            fail(f'pbxproj: target {target} has {len(ms)} "{comment}" phases')
        return ms[0]

    def remove_from_list(self, obj_id, entry_comment):
        """Remove `\t\t\t\t<ID> /* <entry_comment> */,` lines from one object block."""
        s, e = self.block_span(obj_id)
        block = self.text[s:e]
        new = re.sub(r'^\t\t\t\t[0-9A-F]{24} /\* ' + re.escape(entry_comment) + r' \*/,\n', '', block, flags=re.M)
        self.text = self.text[:s] + new + self.text[e:]

    def remove_resource(self, target, name):
        self.remove_from_list(self.phase_id(target, 'Resources'), f'{name} in Resources')

    def remove_target_phase(self, target, phase_name):
        self.remove_from_list(self.target_id(target), phase_name)

    def insert_sorted_in_section(self, section, obj_id, line):
        start = self.text.find(f'/* Begin {section} section */\n')
        end = self.text.find(f'/* End {section} section */')
        if start < 0 or end < 0:
            fail(f'pbxproj: section {section} missing')
        start += len(f'/* Begin {section} section */\n')
        body = self.text[start:end]
        pos = len(body)
        for m in re.finditer(r'^\t\t([0-9A-F]{24}) ', body, re.M):
            if m.group(1) > obj_id:
                pos = m.start()
                break
        self.text = self.text[:start] + body[:pos] + line + body[pos:] + self.text[end:]

    def add_to_list(self, obj_id, list_name, entry):
        s, e = self.block_span(obj_id)
        block = self.text[s:e]
        if entry in block:
            return
        m = re.search(r'^\t\t\t' + list_name + r' = \(\n(.*?)^\t\t\t\);', block, re.M | re.S)
        if not m:
            fail(f'pbxproj: {obj_id} has no {list_name} list')
        block = block[:m.end(1)] + entry + block[m.end(1):]
        self.text = self.text[:s] + block + self.text[e:]

    def add_source_file(self, target, group_path, name):
        rel = f'Tests/{group_path}/{name}'
        if not self.st.exists(rel):
            fail(f'{rel}: missing (our test file)')
        fref = hashlib.sha1(f'nodrive:fileref:{rel}'.encode()).hexdigest()[:24].upper()
        bfile = hashlib.sha1(f'nodrive:buildfile:{target}:{rel}'.encode()).hexdigest()[:24].upper()
        if not re.search(r'^\t\t' + fref + ' ', self.text, re.M):
            self.insert_sorted_in_section(
                'PBXFileReference', fref,
                f'\t\t{fref} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; '
                f'path = {pbx_quote(name)}; sourceTree = "<group>"; }};\n')
        if not re.search(r'^\t\t' + bfile + ' ', self.text, re.M):
            self.insert_sorted_in_section(
                'PBXBuildFile', bfile,
                f'\t\t{bfile} /* {name} in Sources */ = {{isa = PBXBuildFile; fileRef = {fref} /* {name} */; }};\n')
        groups = re.findall(r'^\t\t([0-9A-F]{24}) /\* ' + re.escape(group_path) + r' \*/ = \{\n\t\t\tisa = PBXGroup;',
                            self.text, re.M)
        if len(groups) != 1:
            fail(f'pbxproj: group {group_path} found {len(groups)}x')
        self.add_to_list(groups[0], 'children', f'\t\t\t\t{fref} /* {name} */,\n')
        self.add_to_list(self.phase_id(target, 'Sources'), 'files', f'\t\t\t\t{bfile} /* {name} in Sources */,\n')

    def add_source_folder(self, target, folder, parent_group):
        """Add every .swift file of `folder` (our own folder, new files only) to `target` as a new PBXGroup
        inside `parent_group`. Ids are derived from the path, so a second run changes nothing."""
        names = sorted(n for n in os.listdir(self.st.path(folder)) if n.endswith('.swift'))
        if not names:
            fail(f'{folder}: no .swift files')
        group_name = os.path.basename(folder)
        gid = hashlib.sha1(f'nodrive:group:{folder}'.encode()).hexdigest()[:24].upper()
        parents = re.findall(r'^\t\t([0-9A-F]{24}) /\* ' + re.escape(parent_group) + r' \*/ = \{\n\t\t\tisa = PBXGroup;',
                             self.text, re.M)
        if len(parents) != 1:
            fail(f'pbxproj: group {parent_group} found {len(parents)}x')
        refs = []
        for name in names:
            rel = f'{folder}/{name}'
            fref = hashlib.sha1(f'nodrive:fileref:{rel}'.encode()).hexdigest()[:24].upper()
            bfile = hashlib.sha1(f'nodrive:buildfile:{target}:{rel}'.encode()).hexdigest()[:24].upper()
            refs.append((fref, name))
            if not re.search(r'^\t\t' + fref + ' ', self.text, re.M):
                self.insert_sorted_in_section(
                    'PBXFileReference', fref,
                    f'\t\t{fref} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; '
                    f'path = {pbx_quote(name)}; sourceTree = "<group>"; }};\n')
            if not re.search(r'^\t\t' + bfile + ' ', self.text, re.M):
                self.insert_sorted_in_section(
                    'PBXBuildFile', bfile,
                    f'\t\t{bfile} /* {name} in Sources */ = {{isa = PBXBuildFile; fileRef = {fref} /* {name} */; }};\n')
            self.add_to_list(self.phase_id(target, 'Sources'), 'files', f'\t\t\t\t{bfile} /* {name} in Sources */,\n')
        if not re.search(r'^\t\t' + gid + ' ', self.text, re.M):
            children = ''.join(f'\t\t\t\t{fref} /* {name} */,\n' for fref, name in refs)
            self.insert_sorted_in_section(
                'PBXGroup', gid,
                f'\t\t{gid} /* {group_name} */ = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n{children}\t\t\t);\n'
                f'\t\t\tpath = {pbx_quote(group_name)};\n\t\t\tsourceTree = "<group>";\n\t\t}};\n')
        else:
            for fref, name in refs:
                self.add_to_list(gid, 'children', f'\t\t\t\t{fref} /* {name} */,\n')
        self.add_to_list(parents[0], 'children', f'\t\t\t\t{gid} /* {group_name} */,\n')

    def repoint_file(self, old_path, new_path):
        """Point the PBXFileReference with path old_path (or already new_path) at new_path."""
        new_name = os.path.basename(new_path)
        old_name = os.path.basename(old_path)
        pat = (r'^\t\t([0-9A-F]{24}) /\* (?:' + re.escape(old_name) + '|' + re.escape(new_name) + r') \*/ = \{isa = PBXFileReference;'
               r'(.*?) path = (?:' + re.escape(pbx_quote(old_path)) + '|' + re.escape(pbx_quote(new_path)) + r'); sourceTree = SOURCE_ROOT; \};$')
        ms = re.findall(pat, self.text, re.M)
        if len(ms) != 1:
            fail(f'pbxproj: file reference {old_path} found {len(ms)}x')
        ref, mid = ms[0]
        self.text = re.sub(r'^\t\t' + ref + r' /\* .*? \*/ = \{isa = PBXFileReference;.*$',
                           f'\t\t{ref} /* {new_name} */ = {{isa = PBXFileReference;{mid} path = {pbx_quote(new_path)}; sourceTree = SOURCE_ROOT; }};',
                           self.text, flags=re.M)
        self.text = self.text.replace(f'/* {old_name} in Resources */', f'/* {new_name} in Resources */')
        self.text = self.text.replace(f'{ref} /* {old_name} */', f'{ref} /* {new_name} */')


def validate_pbxproj(text, baseline=None):
    """Local structural checks (real validation: plutil -lint / xcodebuild -list in CI)."""
    errs = []
    # 1. balanced braces/parentheses outside quoted strings and comments
    depth = {'{': 0, '(': 0}
    pairs = {'}': '{', ')': '('}
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if c == '"':
            i += 1
            while i < n and text[i] != '"':
                i += 2 if text[i] == '\\' else 1
        elif text.startswith('/*', i):
            i = text.find('*/', i) + 1
        elif text.startswith('//', i):
            i = text.find('\n', i)
        elif c in depth:
            depth[c] += 1
        elif c in pairs:
            depth[pairs[c]] -= 1
            if depth[pairs[c]] < 0:
                errs.append(f'unbalanced {c} at offset {i}')
                break
        i += 1
    if any(depth.values()):
        errs.append(f'unbalanced at end: {depth}')
    # 2. every object id defined once; every referenced id defined
    defs = re.findall(r'^\t\t([0-9A-F]{24}) (?:/\*.*?\*/ )?= \{', text, re.M)
    dup = [k for k, v in Counter(defs).items() if v > 1]
    if dup:
        errs.append(f'duplicate object ids: {dup[:5]}')
    root = re.search(r'rootObject = ([0-9A-F]{24})', text)
    refs = set(HEX24.findall(text))
    dangling = sorted(refs - set(defs))
    if baseline is not None:
        dangling = sorted(set(dangling) - set(baseline))
    if dangling:
        errs.append(f'{len(dangling)} referenced ids without an object: {dangling[:8]}')
    if not root or root.group(1) not in defs:
        errs.append('rootObject missing')
    return errs, sorted(refs - set(defs))


# --------------------------------------------------------------------------
# The NoDrive edits
# --------------------------------------------------------------------------
def rgb_swift(rgb):
    return 'UIColor(red: %.1f / 255.0, green: %.1f / 255.0, blue: %.1f / 255.0, alpha: 1.0)' % rgb


def brand_swift(st, base):
    rel = 'Brand/NCBrand.swift'
    group = f'group.{base}'
    # user agent: "Mozilla/5.0 (iOS) Nextcloud-iOS/35.2.1 NoDrive" (server 35 regex keeps matching)
    sub_exact(st, rel, 'let suffixBrand = NCBrandOptions.shared.brandUserAgent.isEmpty ? "" : "-\\(NCBrandOptions.shared.brandUserAgent)"',
              'let suffixBrand = NCBrandOptions.shared.brandUserAgent.isEmpty ? "" : " \\(NCBrandOptions.shared.brandUserAgent)"')
    insert_before(st, rel, ' /*\n Codename Matheria',
              '// NoDrive: user-visible version, e.g. "35.2.1-nourax.1".\n'
              '// Info.plist NouraxVersion = $(MARKETING_VERSION)$(NOURAX_VERSION_SUFFIX) (set by tools/rebrand.py).\n'
              'let nouraxVersion: String = {\n'
              '    if let version = Bundle.main.object(forInfoDictionaryKey: "NouraxVersion") as? String, !version.isEmpty {\n'
              '        return version\n'
              '    }\n'
              '    return (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? ""\n'
              '}()\n'
              '\n')
    insert_before(st, rel, 'final class NCBrandOptions: @unchecked Sendable {',
                  '// NoDrive: the values in this class are set by tools/rebrand.py; edit the tool, not this file.\n')
    s = lambda name, type_, expr: swift_set_var(st, rel, name, type_, expr)
    s('brand', 'String', swift_string(APP_NAME))
    s('brandUserAgent', 'String', swift_string(APP_NAME))
    s('textCopyrightNextcloudiOS', 'String', swift_string(APP_NAME + ' ') + ' + nouraxVersion')
    s('textCopyrightNextcloudServer', 'String', swift_string(SERVER_NAME + ' %@'))
    s('loginBaseUrl', 'String', swift_string(SERVER_URL))
    s('pushNotificationServerProxy', 'String', '""')
    s('linkLoginHost', 'String', '""')
    s('linkloginPreferredProviders', 'String', '""')
    s('webLoginAutenticationProtocol', 'String', swift_string(URL_SCHEME + '://'))
    s('privacy', 'String', '(Bundle.main.object(forInfoDictionaryKey: "NouraxPrivacyURL") as? String ?? "").trimmingCharacters(in: .whitespaces)')
    s('sourceCode', 'String', '""')
    s('appStoreUrl', 'String', '""')
    s('capabilitiesGroup', 'String', swift_string(group))
    s('capabilitiesGroupApps', 'String', '""')
    s('use_AppConfig', 'Bool', 'false')
    s('use_themingColor', 'Bool', 'false')
    s('disable_intro', 'Bool', 'false')
    s('disable_request_login_url', 'Bool', 'true')
    s('disable_multiaccount', 'Bool', 'true')
    s('disable_crash_service', 'Bool', 'true')
    s('disable_show_more_nextcloud_apps_in_settings', 'Bool', 'true')
    s('disable_source_code_in_settings', 'Bool', 'true')
    # Nextcloud's push proxy is never set (it is only set when brand == "Nextcloud"; blank it anyway).
    sub_regex(st, rel, r'^(\s*pushNotificationServerProxy = )"[^"]*"$', r'\1""')
    # Colours
    sub_regex(st, rel, r'^(\s*let customer: UIColor = )UIColor\([^\n]*\)(?: //[^\n]*)?$',
              lambda m: m.group(1) + rgb_swift(PRIMARY) + f' // NoDrive: Nourax cobalt {hex_colour(PRIMARY)}')
    for var, rgb in (('red', ACCENT), ('yellow', PRIMARY_LIGHT), ('blue', PRIMARY)):
        sub_regex(st, rel, r'^(\s*let ' + var + r' = )UIColor\(red: [^\n]*\)\.cgColor$',
                  lambda m, rgb=rgb: m.group(1) + 'UIColor(red: %d / 255, green: %d / 255, blue: %d / 255, alpha: 1).cgColor' % rgb)
    sub_regex(st, rel, r'(var documentIconColor: UIColor \{\n\s*get \{\n\s*return UIColor\(hex: )"#[0-9A-Fa-f]{6}"',
              lambda m: m.group(1) + swift_string(hex_colour(PRIMARY_LIGHT)))


def intro_swift(st):
    rel = 'Brand/Intro/NCIntroViewController.swift'
    sub_exact(st, rel, 'import UIKit\n\nclass NCIntroViewController',
              'import UIKit\nimport NextcloudKit\n\nclass NCIntroViewController')
    sub_exact(st, rel,
              '    private let titles = [NSLocalizedString("_intro_1_title_", comment: ""), NSLocalizedString("_intro_2_title_", comment: ""), NSLocalizedString("_intro_3_title_", comment: ""), NSLocalizedString("_intro_4_title_", comment: "")]\n'
              '    private let images = [UIImage(named: "intro1"), UIImage(named: "intro2"), UIImage(named: "intro3"), UIImage(named: "intro4")]\n',
              '    // NoDrive: two slides (Nourax logo; files and sharing). No Nextcloud artwork, no mail/meeting slides.\n'
              '    private let titles = [NSLocalizedString("_intro_1_title_", comment: ""), NSLocalizedString("_intro_2_title_", comment: "")]\n'
              '    private let images = [UIImage(named: "intro1"),\n'
              '                          UIImage(systemName: "folder.badge.person.crop", withConfiguration: UIImage.SymbolConfiguration(pointSize: 120, weight: .regular))?.withTintColor(.white, renderingMode: .alwaysOriginal)]\n')
    insert_after(st, rel,
              '        buttonHost.setTitleColor(textColor.withAlphaComponent(0.5), for: .normal)\n',
              '\n'
              '        // NoDrive: one fixed server, so no "Sign up with provider" and no "Host your own server".\n'
              '        buttonLogin.accessibilityIdentifier = "nodriveLoginButton"\n'
              '        buttonSignUp.isHidden = NCBrandOptions.shared.linkloginPreferredProviders.isEmpty\n'
              '        buttonHost.isHidden = NCBrandOptions.shared.linkLoginHost.isEmpty\n')
    # The screenshot UI test finds each slide by this identifier (works the same in RTL languages).
    insert_after(st, rel,
              '        cell.imageView.image = images[indexPath.row]\n',
              '        cell.accessibilityIdentifier = "nodriveIntroSlide\\(indexPath.row + 1)" // NoDrive: for the screenshot UI test\n')
    sub_exact(st, rel,
              '    @IBAction func login(_ sender: Any) {\n'
              '        if let viewController',
              '    @IBAction func login(_ sender: Any) {\n'
              '        // NoDrive: the server is fixed, so start the browser sign-in (Login Flow v2) right away.\n'
              '        if NCBrandOptions.shared.disable_request_login_url, !NCBrandOptions.shared.loginBaseUrl.isEmpty {\n'
              '            startFixedServerLogin(url: NCBrandOptions.shared.loginBaseUrl)\n'
              '            return\n'
              '        }\n'
              '        if let viewController')
    sub_exact(st, rel,
              '    @IBAction func host(_ sender: Any) {\n'
              '        guard let url = URL(string: NCBrandOptions.shared.linkLoginHost) else { return }\n'
              '        UIApplication.shared.open(url)\n'
              '    }\n'
              '}\n',
              '    @IBAction func host(_ sender: Any) {\n'
              '        guard let url = URL(string: NCBrandOptions.shared.linkLoginHost) else { return }\n'
              '        UIApplication.shared.open(url)\n'
              '    }\n'
              '\n'
              '    // MARK: - NoDrive fixed-server sign-in\n'
              '\n'
              '    /// Login Flow v2 against the one NoDrive server, without the server-address screen.\n'
              '    /// Same calls as `NCLogin.startLogin(url:)`.\n'
              '    private func startFixedServerLogin(url: String) {\n'
              '        buttonLogin.isEnabled = false\n'
              '        buttonLogin.hideButtonAndShowSpinner(tint: textColor)\n'
              '\n'
              '        NextcloudKit.shared.getServerStatus(serverUrl: url) { [weak self] _, serverInfoResult in\n'
              '            guard let self else { return }\n'
              '            switch serverInfoResult {\n'
              '            case .success:\n'
              '                if let host = URL(string: url)?.host {\n'
              '                    NCNetworking.shared.writeCertificate(host: host)\n'
              '                }\n'
              '                let loginOptions = NKRequestOptions(customUserAgent: userAgent)\n'
              '                NextcloudKit.shared.getLoginFlowV2(serverUrl: url, options: loginOptions) { [weak self] token, endpoint, login, _, error in\n'
              '                    guard let self else { return }\n'
              '                    if error == .success, let token, let endpoint, let login {\n'
              '                        let loginProvider = NCLoginProvider()\n'
              '                        loginProvider.initialURLString = login\n'
              '                        loginProvider.delegate = self\n'
              '                        loginProvider.controller = self.controller\n'
              '                        loginProvider.presentingViewController = self\n'
              '                        loginProvider.startPolling(loginFlowV2Token: token, loginFlowV2Endpoint: endpoint, loginFlowV2Login: login)\n'
              '                        loginProvider.startAuthentication()\n'
              '                        self.activeLoginProvider = loginProvider\n'
              '                    } else {\n'
              '                        self.showFixedServerLoginError(error)\n'
              '                    }\n'
              '                }\n'
              '            case .failure(let error):\n'
              '                self.showFixedServerLoginError(error)\n'
              '            }\n'
              '        }\n'
              '    }\n'
              '\n'
              '    private func showFixedServerLoginError(_ error: NKError) {\n'
              '        onBack()\n'
              '        Task { @MainActor in\n'
              '            let windowScene = SceneManager.shared.getWindowScene(controller: self.controller)\n'
              '            await showErrorBanner(windowScene: windowScene, error: error)\n'
              '        }\n'
              '    }\n'
              '}\n'
              '\n'
              '// MARK: - NCLoginProviderDelegate (NoDrive)\n'
              '\n'
              'extension NCIntroViewController: NCLoginProviderDelegate {\n'
              '    /// Browser sign-in cancelled or failed: show "Log in" again.\n'
              '    func onBack() {\n'
              '        buttonLogin.isEnabled = true\n'
              '        buttonLogin.hideSpinnerAndShowButton()\n'
              '        activeLoginProvider?.cancel()\n'
              '        activeLoginProvider = nil\n'
              '    }\n'
              '}\n')


def swift_code(st):
    scheme = URL_SCHEME
    # URL scheme of the app (deep links, widgets, Action extension)
    sub_regex(st, 'iOSClient/NCGlobal.swift', r'^(\s*let appScheme\s*= )"[^"]*"$', r'\1' + swift_string(scheme))
    sub_regex(st, 'iOSClient/NCGlobal.swift', r'^(\s*let widgetAction\w+\s*= )"[a-z]+(://open-action\?action=[a-z-]+)"$',
              r'\1"' + scheme + r'\2"', count=5)
    # No App Store "recommend" links to Nextcloud apps (the sidebar section is off as well)
    for name in ('talkAppStoreUrl', 'notesAppStoreUrl', 'moreAppsUrl'):
        sub_regex(st, 'iOSClient/NCGlobal.swift', r'^(\s*let ' + name + r'\s*= )"[^"]*"$', r'\1""')
    sub_regex(st, 'Widget/Files/FilesData.swift', r'let urlString = "[a-z]+(://open-file\?)',
              r'let urlString = "' + scheme + r'\1')
    sub_regex(st, 'Action Assistant/ActionViewController.swift', r'URL\(string: "[a-z]+(://assistant/shared-text)"\)',
              r'URL(string: "' + scheme + r'\1")')
    # Widget placeholder links (shown while a widget loads)
    for rel in ('Widget/Dashboard/DashboardData.swift', 'Widget/Files/FilesData.swift'):
        sub_exact(st, rel, 'URL(string: "https://nextcloud.com/")!', f'URL(string: "{SERVER_URL}/")!', count=10)
    sub_exact(st, 'Widget/Files/FilesWidgetView.swift', 'footerText: "Nextcloud files"', f'footerText: "{APP_NAME} files"')
    # Notification text while a push is being decrypted
    sub_exact(st, 'Notification Service Extension/NotificationService.swift',
              'bestAttemptContent.body = "Nextcloud notification"', f'bestAttemptContent.body = "{APP_NAME} notification"')
    # Scan preview fallback PDF (was "Reasons to use Nextcloud.pdf")
    sub_exact(st, 'iOSClient/Scan document/NCUploadScanDocument.swift',
              'Bundle.main.url(forResource: "Reasons to use Nextcloud", withExtension: "pdf")!',
              'Bundle.main.url(forResource: "NoDriveBlank", withExtension: "pdf")!')
    # Unified search: Talk results used the Nextcloud Talk logo ("talk-template"); use a system symbol
    sub_exact(st, 'iOSClient/Main/Collection Common/Cell/NCCellMain.swift',
              'cell.previewImg?.image = UIImage(named: "talk-template")!.image(color: NCBrandColor.shared.getElement(account: metadata.account))',
              'cell.previewImg?.image = utility.loadImage(named: "bubble.left.and.bubble.right", colors: [NCBrandColor.shared.iconImageColor])',
              count=2)
    # Privacy link: hidden while NOURAX_PRIVACY_URL is empty (upstream force-unwraps the URL)
    wrap_privacy_button(st)


def wrap_privacy_button(st):
    rel = 'iOSClient/Settings/Settings/NCSettingsView.swift'
    text = st.get(rel)
    start_marker = '                // Terms & Privacy Conditions\n'
    end_marker = '                // Source Code Nextcloud App\n'
    guard = '                // NoDrive: shown only when NOURAX_PRIVACY_URL is set\n                if !NCBrandOptions.shared.privacy.isEmpty {\n'
    if text.count(start_marker) != 1 or text.count(end_marker) != 1:
        fail(f'{rel}: privacy button anchors not found')
    a = text.index(start_marker) + len(start_marker)
    b = text.index(end_marker)
    block = text[a:b]
    if block.startswith(guard):
        return
    if 'NCBrandOptions.shared.privacy' not in block or not block.startswith('                Button(action: {'):
        fail(f'{rel}: privacy button block changed upstream')
    indented = ''.join(('    ' + ln if ln.strip() else ln) for ln in block.splitlines(keepends=True))
    st.set(rel, text[:a] + guard + indented + '                }\n' + text[b:])


def plists(st, base):
    group = f'group.{base}'
    for rel in BRAND_PLISTS:
        st.get(rel)
    for rel, name in PLIST_DISPLAY_NAMES.items():
        plist_set_string(st, rel, 'CFBundleDisplayName', name)
    app = 'Brand/iOSClient.plist'
    plist_set_string(st, app, 'CFBundleName', APP_NAME)
    plist_set_string(st, app, 'CFBundleURLName', base)
    plist_set_array(st, app, 'CFBundleURLSchemes', [URL_SCHEME])
    plist_remove_key(st, app, 'ITSEncryptionExportComplianceCode')     # Nextcloud's App Store Connect record
    plist_ensure_string(st, app, 'NouraxPrivacyURL', '$(NOURAX_PRIVACY_URL)')
    for rel in BRAND_PLISTS:
        plist_ensure_string(st, rel, 'NouraxVersion', '$(MARKETING_VERSION)$(NOURAX_VERSION_SUFFIX)')
    plist_set_string(st, 'Brand/File_Provider_Extension.plist', 'NSExtensionFileProviderDocumentGroup', group)
    plist_set_string(st, 'Brand/BackgroundUploadExtension.plist', 'BackgroundUploadURLBase', SERVER_URL)
    for rel in ENTITLEMENTS:
        plist_remove_key(st, rel, 'aps-environment')                    # push is off
        plist_set_array(st, rel, 'com.apple.security.application-groups', [group])
        plist_set_array(st, rel, 'keychain-access-groups', [f'$(AppIdentifierPrefix){base}'])


def project(st, base):
    pbx = PBX(st)
    for target, suffix in TARGET_IDS.items():
        for cfg in pbx.config_ids(target):
            pbx.set_setting(cfg, 'PRODUCT_BUNDLE_IDENTIFIER', base + suffix)
    for target in PBX_DISPLAY_NAME_TARGETS:
        for cfg in pbx.config_ids(target):
            pbx.set_setting(cfg, 'INFOPLIST_KEY_CFBundleDisplayName', APP_NAME)
    for cfg in pbx.settings_with_key('DEVELOPMENT_TEAM'):      # Nextcloud's team id
        pbx.set_setting(cfg, 'DEVELOPMENT_TEAM', '')
    for cfg in pbx.config_ids(None):
        pbx.set_setting(cfg, 'INFOPLIST_KEY_NSHumanReadableCopyright', COPYRIGHT)
        pbx.set_setting(cfg, 'CURRENT_PROJECT_VERSION', BUILD_NUMBER)
        pbx.set_setting(cfg, 'NOURAX_VERSION_SUFFIX', VERSION_SUFFIX)
        pbx.set_setting(cfg, 'NOURAX_PRIVACY_URL', PRIVACY_URL)
    for name in REMOVE_APP_RESOURCES:
        pbx.remove_resource('Nextcloud', name)
    for name in REMOVE_APP_PHASES:
        pbx.remove_target_phase('Nextcloud', name)
    pbx.repoint_file('Reasons to use Nextcloud.pdf', 'Brand/NoDriveBlank.pdf')
    for target, group, name in TEST_FILES:
        pbx.add_source_file(target, group, name)
    for target, folder, parent in APP_SOURCE_FOLDERS:
        pbx.add_source_folder(target, folder, parent)
    # UI-test product (and so its runner app) named after NoDrive; see UI_TEST_PRODUCT
    for cfg in pbx.config_ids('NextcloudUITests'):
        pbx.set_setting(cfg, 'PRODUCT_NAME', UI_TEST_PRODUCT)
    sub_exact(st, PBX.REL, 'path = NextcloudUITests.xctest; sourceTree = BUILT_PRODUCTS_DIR;',
              f'path = {UI_TEST_PRODUCT}.xctest; sourceTree = BUILT_PRODUCTS_DIR;')
    sub_exact(st, PBX.REL, '/* NextcloudUITests.xctest */', f'/* {UI_TEST_PRODUCT}.xctest */', count=3)
    # Every scheme that launches the app (system hosts such as com.apple.springboard stay)
    for name in sorted(os.listdir(st.path('Nextcloud.xcodeproj/xcshareddata/xcschemes'))):
        rel = f'Nextcloud.xcodeproj/xcshareddata/xcschemes/{name}'
        if re.search(r'BundleIdentifier = "(?!com\.apple\.)', st.get(rel)):
            sub_regex(st, rel, r'(BundleIdentifier = )"(?!com\.apple\.)[^"]*"', r'\1"' + base + '"', count=None)
        if 'BuildableName = "NextcloudUITests.xctest"' in st.get(rel):
            sub_exact(st, rel, 'BuildableName = "NextcloudUITests.xctest"',
                      f'BuildableName = "{UI_TEST_PRODUCT}.xctest"', count=None)


def storyboards(st):
    def colour(rel, count=1):
        r, g, b = (v / 255.0 for v in PRIMARY)
        sub_regex(st, rel, r'(<color key="backgroundColor" )red="[^"]*" green="[^"]*" blue="[^"]*"( alpha="1" colorSpace="custom" customColorSpace="sRGB"/>)',
                  lambda m: m.group(1) + f'red="{r!r}" green="{g!r}" blue="{b!r}"' + m.group(2), count=count)
    colour('Brand/LaunchScreen.storyboard')
    colour('File Provider Extension UI/MainInterface.storyboard')
    for rel in ('Brand/LaunchScreen.storyboard', 'File Provider Extension UI/MainInterface.storyboard'):
        sub_regex(st, rel, r'<image name="logo" width="[0-9.]+" height="[0-9.]+"/>', '<image name="logo" width="150" height="150"/>')
    sub_exact(st, 'iOSClient/Login/NCLogin.storyboard', 'The link to your Nextcloud web interface',
              f'The link to your {SERVER_NAME} web interface')
    sub_exact(st, 'iOSClient/Share/NCShareUserCell.xib', 'text="user1@tos.ltd3.nextcloud.com (Remote group)"',
              'text="user1@example.com (Remote group)"')


def folder_svgs(st):
    # Nextcloud blue #00679E in the (template-rendered) folder glyphs -> Nourax cobalt
    for name in ('folder.imageset/folder.svg', 'folderAutomaticUpload.imageset/folder_photo.svg',
                 'folderEncrypted.imageset/folder_encrypted.svg', 'folder_external.imageset/folder_external.svg',
                 'folder_group.imageset/folder_group.svg', 'folder_public.imageset/folder_link.svg',
                 'folder_shared_with_me.imageset/folder_shared_with_me.svg'):
        sub_regex(st, f'iOSClient/Images.xcassets/{name}', r'#(?:00679[Ee]|2563EB)', hex_colour(PRIMARY), count=None, flags=0)


# ---- glyph PDFs ------------------------------------------------------------
# Vector PDFs in the asset catalog filled with a Nextcloud blue. UIImage(named:) loads them by
# NextcloudKit's icon names (NKTypeIconFile.directory = "directory", .document = "document"),
# e.g. in the upload-conflict dialog; "directory" is also the placeholder of NCShareHeader.xib.
# (file, upstream colour, NoDrive colour)
GLYPH_PDFS = [
    ('iOSClient/Images.xcassets/directory.imageset/directory.pdf', (0x00, 0x82, 0xC9), PRIMARY),
    ('iOSClient/Images.xcassets/document.imageset/document.pdf', (0x49, 0xAB, 0xEA), PRIMARY_LIGHT),  # = documentIconColor
]
PDF_WS = rb'[ \t\r\n]'
PDF_NUM = rb'(?:\d+(?:\.\d*)?|\.\d+)'
PDF_RGB_OP = re.compile(rb'(?<![\w.])(' + PDF_NUM + rb')' + PDF_WS + rb'+(' + PDF_NUM + rb')' + PDF_WS + rb'+('
                        + PDF_NUM + rb')' + PDF_WS + rb'+(RG|rg)(?!\w)')
PDF_STREAM = re.compile(rb'(?:^|[\r\n])\d+ 0 obj' + PDF_WS + rb'*<<([^<>]*)>>' + PDF_WS + rb'*stream\r?\n')


def pdf_number(v):
    """0..255 -> a PDF colour operand with 3 decimals, Skia style (.145), that maps back to v."""
    s = ('%.3f' % (v / 255)).rstrip('0').rstrip('.')
    s = s[1:] if s.startswith('0.') else s
    if round(float(s) * 255) != v:
        fail(f'internal: colour operand {s} does not map back to {v}')
    return s.encode('ascii')


def pdf_rgb(m):
    return tuple(round(float(m.group(i)) * 255) for i in (1, 2, 3))


def pdf_recolour(st, rel, old, new):
    """Change the one colour of a single-content-stream PDF (Skia output) from `old` to `new`.
    Only the "r g b RG" / "r g b rg" operands change; the stream is compressed again and the
    xref table rewritten. A PDF that already has `new` is left byte for byte as it is."""
    data = st.get_bytes(rel)
    streams = list(PDF_STREAM.finditer(data))
    if len(streams) != 1:
        fail(f'{rel}: expected 1 content stream, found {len(streams)} (upstream changed?)')
    sm = streams[0]
    lm = re.fullmatch(rb'/Filter /FlateDecode' + PDF_WS + rb'*/Length (\d+)' + PDF_WS + rb'*', sm.group(1))
    if not lm:
        fail(f'{rel}: stream dictionary is not "/Filter /FlateDecode /Length n" (upstream changed?): {sm.group(1)[:80]!r}')
    start, length = sm.end(), int(lm.group(1))
    if not re.match(rb'\r?\nendstream', data[start + length:start + length + 11]):
        fail(f'{rel}: /Length {length} does not end at endstream')
    content = zlib.decompress(data[start:start + length])
    found = {pdf_rgb(m) for m in PDF_RGB_OP.finditer(content)}
    if found == {new}:
        return
    if old not in found or not found <= {old, new}:
        fail(f'{rel}: colours {sorted(hex_colour(c) for c in found)}, expected {hex_colour(old)} (upstream changed?)')
    operands = b' '.join(pdf_number(v) for v in new)
    content = PDF_RGB_OP.sub(lambda m: operands + b' ' + m.group(4) if pdf_rgb(m) == old else m.group(0), content)
    if {pdf_rgb(m) for m in PDF_RGB_OP.finditer(content)} != {new}:
        fail(f'internal: {rel}: recolour left other colours')
    stream = zlib.compress(content, 9)
    out = (data[:sm.start(1)] + b'/Filter /FlateDecode\n/Length %d' % len(stream) + data[sm.end(1):start]
           + stream + data[start + length:])
    st.set_bytes(rel, pdf_rewrite_xref(rel, out))


def pdf_rewrite_xref(rel, data):
    """Recompute a classic xref table (one subsection from object 0) and startxref."""
    xms = list(re.finditer(rb'[\r\n]xref\r?\n0 (\d+)\r?\n', data))
    if len(xms) != 1:
        fail(f'{rel}: expected one classic xref table, found {len(xms)}')
    xm = xms[0]
    count = int(xm.group(1))
    end = xm.end() + 20 * count
    if not re.fullmatch(rb'(?:\d{10} \d{5} [nf](?: \n|\r\n| \r))+', data[xm.end():end]):
        fail(f'{rel}: xref table is not {count} entries of 20 bytes')
    offsets = {int(m.group(2)): m.start(2) for m in re.finditer(rb'(^|[\r\n])(\d+) 0 obj\b', data)}
    if sorted(offsets) != list(range(1, count)):
        fail(f'{rel}: objects {sorted(offsets)} do not match xref size {count}')
    entries = b'0000000000 65535 f \n' + b''.join(b'%010d 00000 n \n' % offsets[i] for i in range(1, count))
    data = data[:xm.end()] + entries + data[end:]
    data, n = re.subn(rb'startxref\r?\n\d+', b'startxref\n%d' % (xm.start() + 1), data)
    if n != 1:
        fail(f'{rel}: expected one startxref, found {n}')
    return data


def glyph_pdfs(st):
    for rel, old, new in GLYPH_PDFS:
        pdf_recolour(st, rel, old, new)


# ---- translations --------------------------------------------------------
STRINGS_LINE = re.compile(r'^(?P<pre>[ \t]*"(?P<key>(?:[^"\\]|\\.)*)"[ \t]*=[ \t]*")(?P<val>(?:[^"\\]|\\.)*)(?P<post>"[ \t]*;.*)$')


def parse_strings(text):
    out = {}
    for i, line in enumerate(text.split('\n')):
        m = STRINGS_LINE.match(line)
        if m:
            out[m.group('key')] = (i, m)
    return out


def specs(value):
    return Counter(FORMAT_RE.findall(value)), value.count('\\n')


def rename_value(value, target):
    new = NAME_RE.sub(target, value)
    new = re.sub(r'(?i)https?://nextcloud\.com/\S*?(?=[\s"。.]|$)', SERVER_URL, new)
    return new


def translations(st):
    files = []
    for top in ('iOSClient/Supporting Files', 'Widget/Intent'):
        base = st.path(top)
        for lproj in sorted(os.listdir(base)):
            if lproj.endswith('.lproj'):
                for fn in sorted(os.listdir(os.path.join(base, lproj))):
                    if fn.endswith('.strings'):
                        files.append(f'{top}/{lproj}/{fn}')
    en = 'iOSClient/Supporting Files/en.lproj/Localizable.strings'
    en_entries = parse_strings(st.get(en))
    for key in STRINGS_SERVER_KEYS + list(STRINGS_COPY_KEYS) + ['_access_photo_not_enabled_msg_']:
        if key not in en_entries:
            fail(f'{en}: key {key} missing (upstream renamed it?)')

    def rewrite(rel, entries_new):
        text = st.get(rel)
        lines = text.split('\n')
        for key, val in entries_new.items():
            i, m = parse_strings(text)[key]
            lines[i] = m.group('pre') + val + m.group('post')
        st.set(rel, '\n'.join(lines))

    # Fallback for a language that has the ownCloud warning but no "unsupported" text.
    en_server = rename_value(en_entries['_warning_unsupported_'][1].group('val'), SERVER_NAME)
    for rel in files:
        text = st.get(rel)
        entries = parse_strings(text)
        new = {}
        for key, target in [(k, APP_NAME) for k in STRINGS_APP_KEYS] + [(k, SERVER_NAME) for k in STRINGS_SERVER_KEYS]:
            if key in entries:
                old = entries[key][1].group('val')
                val = rename_value(old, target)
                if specs(val) != specs(old):
                    fail(f'{rel}: {key}: format specifiers changed')
                new[key] = val
        for key, src in STRINGS_COPY_KEYS.items():
            if key in entries:
                src_val = new.get(src)
                if src_val is None:
                    src_val = en_server   # language without the source key: use English
                if src_val is None:
                    fail(f'{rel}: no value for {key}')
                old = entries[key][1].group('val')
                if specs(src_val) != specs(old):
                    fail(f'{rel}: {key}: format specifiers differ from {src}')
                new[key] = src_val
        for key, val in new.items():
            if NAME_RE.search(val) or re.search(r'(?i)next\s?cloud', val):
                fail(f'{rel}: {key} still names Nextcloud after rewrite: {val[:80]!r}')
        changed = {k: v for k, v in new.items() if v != entries[k][1].group('val')}
        if changed:
            rewrite(rel, changed)


# ---- generated files -----------------------------------------------------
def blank_pdf():
    """One blank A4 page, fixed bytes."""
    objs = [b'<< /Type /Catalog /Pages 2 0 R >>',
            b'<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
            b'<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Resources << >> >>']
    out = bytearray(b'%PDF-1.4\n')
    offsets = []
    for i, body in enumerate(objs, 1):
        offsets.append(len(out))
        out += b'%d 0 obj\n' % i + body + b'\nendobj\n'
    xref = len(out)
    out += b'xref\n0 %d\n0000000000 65535 f \n' % (len(objs) + 1)
    for off in offsets:
        out += b'%010d 00000 n \n' % off
    out += b'trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n' % (len(objs) + 1, xref)
    return bytes(out)


def rtf_escape(s):
    out = []
    for ch in s:
        o = ord(ch)
        if ch in '\\{}':
            out.append('\\' + ch)
        elif ch == '\n':
            out.append('\\\n')
        elif o > 127:
            out.append('\\u%d?' % (o if o < 32768 else o - 65536))
        else:
            out.append(ch)
    return ''.join(out)


def acknowledgements(st):
    with open(os.path.join(ROOT, 'tools/legal/third-party.json'), encoding='utf-8') as f:
        data = json.load(f)
    rule = '__________________________________'
    parts = [('b', data['app']['title'])]
    for line in data['app']['lines']:
        parts.append(('', line))
    parts += [('', rule), ('', data['intro']), ('', rule)]
    used = []
    for c in data['components']:
        parts.append(('b', c['name']))
        parts.append(('', f"{c['license']}. {c['copyright']}"))
        if c['license'] not in used:
            used.append(c['license'])
    parts.append(('', rule))
    for lic in used:
        if lic in data['license_texts']:
            parts.append(('b', lic))
            parts.append(('', data['license_texts'][lic]))
    body = []
    for style, text in parts:
        t = rtf_escape(text)
        body.append(('\\f1\\b ' + t + '\\f0\\b0 ' if style == 'b' else t) + '\\\n\\\n')
    rtf = ('{\\rtf1\\ansi\\ansicpg1252\\cocoartf2868\n'
           '{\\fonttbl\\f0\\fswiss\\fcharset0 Helvetica;\\f1\\fswiss\\fcharset0 Helvetica-Bold;}\n'
           '{\\colortbl;\\red255\\green255\\blue255;}\n'
           '\\pard\\pardirnatural\\partightenfactor0\n\n'
           '\\f0\\fs24 \\cf0 ' + ''.join(body) + '}\n')
    st.set('iOSClient/Settings/Acknowledgements.rtf', rtf)


# --------------------------------------------------------------------------
def run(st, base):
    brand_swift(st, base)
    intro_swift(st)
    swift_code(st)
    plists(st, base)
    project(st, base)
    storyboards(st)
    folder_svgs(st)
    glyph_pdfs(st)
    translations(st)
    acknowledgements(st)
    st.set_bytes('Brand/NoDriveBlank.pdf', blank_pdf())


def validate(st, baseline_dangling):
    errs, plists_ok = [], 0
    for rel, f in st.files.items():
        if f['text'] is None:
            continue
        if rel.endswith(('.plist', '.entitlements')):
            try:
                plistlib.loads(st.encoded(rel))
                plists_ok += 1
            except Exception as e:  # noqa: BLE001
                errs.append(f'{rel}: plist does not parse: {e}')
    text = st.get(PBX.REL)
    pbx_errs, dangling = validate_pbxproj(text, baseline_dangling)
    errs += [f'{PBX.REL}: {e}' for e in pbx_errs]
    objects = len(re.findall(r'^\t\t[0-9A-F]{24} (?:/\*.*?\*/ )?= \{', text, re.M))
    summary = (f'validated: {plists_ok} plists/entitlements parse (plistlib); pbxproj braces/parens balanced, '
               f'{objects} objects with unique ids, no new dangling ids '
               f'({len(dangling)} pre-existing upstream)')
    return errs, summary


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--check', action='store_true', help='change nothing; exit 1 if a run would change files')
    ap.add_argument('--bundle-base', default=DEFAULT_BUNDLE_BASE,
                    help=f'base of every id (default {DEFAULT_BUNDLE_BASE})')
    ap.add_argument('--root', default=ROOT, help='repository root (default: this checkout)')
    args = ap.parse_args()
    if not re.fullmatch(r'[a-z0-9]+(\.[a-z0-9-]+)+', args.bundle_base):
        sys.exit(f'rebrand: bad --bundle-base {args.bundle_base!r}')

    st = Store(os.path.abspath(args.root))
    try:
        _, baseline_dangling = validate_pbxproj(st.get(PBX.REL))
        run(st, args.bundle_base)
        errs, summary = validate(st, baseline_dangling)
    except RebrandError as e:
        print(f'rebrand: ERROR: {e}', file=sys.stderr)
        sys.exit(2)
    if errs:
        for e in errs:
            print(f'rebrand: INVALID: {e}', file=sys.stderr)
        sys.exit(2)

    print(f'rebrand: {summary}')
    changed = st.changed()
    for rel in changed:
        print(f'{"would change" if args.check else "changed"}: {rel}')
    print(f'rebrand: {len(st.files)} files checked, {len(changed)} {"would change" if args.check else "changed"}'
          f' (bundle base {args.bundle_base})')
    if args.check:
        sys.exit(1 if changed else 0)
    st.write()


if __name__ == '__main__':
    main()
