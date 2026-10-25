#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Nourax
# SPDX-License-Identifier: GPL-3.0-or-later
"""NoDrive branding sweep (spec section 6, "the no-Nextcloud rule").

Searches everything that ships in the app and its extensions for Nextcloud's
name, links, store ids and colours, in every language, and fails on any hit
that tools/branding/allowlist.txt does not classify as `internal` (an
identifier the server, the OS or a library depends on) or `legal` (a
copyright or licence notice).

What is searched (source mode, the default):
  * translations: .strings (values and comments, UTF-16 decoded), .stringsdict, .xcstrings
  * storyboards and XIBs (text, and colours close to Nextcloud blue)
  * Info.plist files, entitlements, intent definitions, privacy manifest, RTF, JSON, SVG, TXT
  * image and resource file names (+ SVG content); images must also be looked at (--list-images)
  * colours close to a Nextcloud blue (#0082C9, #00679E, #49ABEA): hex and rgb() colours in
    SVG/HTML/CSS, asset-catalog colour sets, colour operators (rg/RG/sc/scn/k) in the
    decompressed content streams of PDFs, and the pixels of PNG/JPEG/GIF images
    (RASTER_SHARE of the opaque pixels; needs Pillow)
  * Swift / Objective-C string literals (comments skipped), hex-colour literals and UIColor values
  * project.pbxproj: bundle ids, INFOPLIST_KEY_* values, team, NOURAX_* settings, the
    resources copied into each target; xcschemes: BundleIdentifier
  in the folders of the app and its extensions (Brand, iOSClient, Share, File Provider
  Extension[ UI], Notification Service Extension, Widget, WidgetDashboardIntentHandler,
  Action Assistant, BackgroundUploadExtension), for files the Xcode project references.

App mode (--app path/to/NoDrive.app, used in CI after the build) searches the built
bundle: every plist / compiled .strings / .stringsdict (read with plistlib), file names,
asset names (xcrun assetutil when available) and http(s) links inside binaries.

Usage:
  python3 tools/check-branding.py                       sweep the source, exit 1 on unclassified hits
  python3 tools/check-branding.py --show-allowed        also list the classified hits
  python3 tools/check-branding.py --no-allowlist        raw hit count (e.g. on the upstream tag)
  python3 tools/check-branding.py --root ../wt/x        sweep another checkout
  python3 tools/check-branding.py --list-images         list shipped images for the visual check
  python3 tools/check-branding.py --app NoDrive.app     sweep a built app
"""
import argparse
import fnmatch
import json
import os
import plistlib
import re
import shutil
import subprocess
import sys
import zlib
from collections import Counter, defaultdict

TOOLS = os.path.dirname(os.path.abspath(__file__))
DEFAULT_ROOT = os.path.abspath(os.path.join(TOOLS, '..'))
DEFAULT_ALLOWLIST = os.path.join(TOOLS, 'branding', 'allowlist.txt')

SHIPPED_DIRS = ['Brand', 'iOSClient', 'Share', 'File Provider Extension', 'File Provider Extension UI',
                'Notification Service Extension', 'Widget', 'WidgetDashboardIntentHandler', 'Action Assistant',
                'BackgroundUploadExtension']
SKIP_PARTS = {'.tx'}
SHIPPED_TARGETS = ['Nextcloud', 'Share', 'File Provider Extension', 'File Provider Extension UI',
                   'Notification Service Extension', 'Widget', 'WidgetDashboardIntentHandler', 'Action Assistant',
                   'BackgroundUploadExtension']
# Resources that must never be copied into a shipped target again
FORBIDDEN_RESOURCES = ['AppIcon.icon', 'GoogleService-Info.plist', 'Nextcloud Hub.png', 'Reasons to use Nextcloud.pdf']
BUNDLE_BASE = 'org.nourax.nodrive'

# Spec section 6 keyword list (case-insensitive) + legacy ids + the name in other scripts.
KEYWORDS = [
    ('nextcloud', r'next\s?cloud'),                       # name, nextcloud.com, help./docs./apps./push-notifications./updates.nextcloud, github.com/nextcloud, com.nextcloud
    ('owncloud', r'own\s?cloud'),
    ('mirall', r'\bmirall\b'),
    ('it.niedermann', r'it\.niedermann'),
    ('twsweb', r'twsweb'),                                # upstream bundle-id prefix
    ('crypto-cloud', r'crypto[-\s]?cloud'),               # upstream app-group / keychain name
    ('app-store-id', r'(?<!\d)(?:1125420102|1296825574|813973264)(?!\d)'),   # Nextcloud, Talk, Notes
    ('#0082c9', r'0082c9'),
    ('#00679e', r'00679e'),
    ('name-ar', r'ن[كک]ست\s?[كک]لا?و?د'),
    ('name-ko', r'넥스트\s?클라우드'),
    ('name-ja', r'ネクスト\s?クラウド'),
    ('name-ru', r'некст\s?кл[ао]уд'),
    ('name-he', r'נקסט\s?קלאוד'),
]
KEYWORD_RE = [(name, re.compile(p, re.I)) for name, p in KEYWORDS]
# Nextcloud's brand blue, its dark blue (folder glyphs) and its document-icon blue
# (upstream document.pdf #49ABEA, NCBrand.documentIconColor #49abe9)
NEXTCLOUD_BLUES = [(0x00, 0x82, 0xC9), (0x00, 0x67, 0x9E), (0x49, 0xAB, 0xEA)]
COLOUR_DISTANCE = 32
# Raster images: a hit when at least this share of the opaque pixels is a Nextcloud blue
RASTER_SHARE = 0.01
RASTER_MAX_SIDE = 512

TEXT_EXT = {'.plist', '.entitlements', '.intentdefinition', '.xcprivacy', '.storyboard', '.xib', '.json', '.svg',
            '.rtf', '.txt', '.md', '.html', '.css', '.js', '.stringsdict', '.xcstrings', '.strings', '.xcscheme'}
CODE_EXT = {'.swift', '.m', '.h'}
IMAGE_EXT = {'.png', '.jpg', '.jpeg', '.gif', '.pdf', '.svg', '.heic', '.icon', '.car'}
RASTER_EXT = {'.png', '.jpg', '.jpeg', '.gif'}


# ------------------------------------------------------------------ helpers
def decode(data):
    if data.startswith(b'\xff\xfe'):
        return data[2:].decode('utf-16-le', 'replace')
    if data.startswith(b'\xfe\xff'):
        return data[2:].decode('utf-16-be', 'replace')
    if data.startswith(b'\xef\xbb\xbf'):
        return data[3:].decode('utf-8', 'replace')
    return data.decode('utf-8', 'replace')


class Hit:
    __slots__ = ('path', 'line', 'kind', 'keyword', 'text', 'cls', 'reason')

    def __init__(self, path, line, kind, keyword, text):
        self.path, self.line, self.kind, self.keyword, self.text = path, line, kind, keyword, text
        self.cls = self.reason = None

    def __str__(self):
        loc = f'{self.path}:{self.line}' if self.line else self.path
        return f'{loc} [{self.kind}] {self.keyword}: {self.text[:160]}'


def keyword_hits(path, line, kind, text):
    out = []
    for name, rx in KEYWORD_RE:
        if rx.search(text):
            out.append(Hit(path, line, kind, name, text.strip()))
    return out


def colour_hit(rgb):
    for blue in NEXTCLOUD_BLUES:
        if sum((a - b) ** 2 for a, b in zip(rgb, blue)) ** 0.5 <= COLOUR_DISTANCE:
            return '#%02X%02X%02X' % blue
    return None


def colour_hits(rel, line, text, rgb):
    c = colour_hit(rgb)
    return [Hit(rel, line, 'colour', f'~{c}', text)] if c else []


# colours written as text: #rgb / #rrggbb (SVG, HTML, CSS), rgb(r, g, b), and a Swift/ObjC
# string literal that is only a hex colour (UIColor(hex: "#49abe9"))
HEX_COLOUR = re.compile(r'(?<![\w&#])#([0-9A-Fa-f]{6}|[0-9A-Fa-f]{3})(?!\w)')
CSS_RGB = re.compile(r'rgba?\(\s*(\d{1,3})\s*,\s*(\d{1,3})\s*,\s*(\d{1,3})\s*[,)]')
HEX_LITERAL = re.compile(r'(?:#|0x)?([0-9A-Fa-f]{6})(?:[0-9A-Fa-f]{2})?')


def hex_rgb(h):
    if len(h) == 3:
        h = ''.join(c * 2 for c in h)
    return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))


def text_colour_hits(rel, n, line):
    hits = []
    for m in HEX_COLOUR.finditer(line):
        hits += colour_hits(rel, n, m.group(0), hex_rgb(m.group(1)))
    for m in CSS_RGB.finditer(line):
        hits += colour_hits(rel, n, m.group(0), tuple(int(v) for v in m.groups()))
    return hits


def colorset_hits(rel, text):
    """Asset-catalog colour sets: components are 0-1 floats ("0.510"), 8-bit hex ("0x82") or integers."""
    def value(v):
        v = str(v).strip()
        if v.lower().startswith('0x'):
            return int(v, 16)
        return round(float(v) * 255) if '.' in v else int(v)
    hits = []
    try:
        colours = json.loads(text).get('colors', [])
    except ValueError:
        return [Hit(rel, 0, 'colour', 'unreadable-colorset', 'not JSON')]
    for i, c in enumerate(colours):
        comp = (c.get('color') or {}).get('components') or {}
        if all(k in comp for k in ('red', 'green', 'blue')):
            try:
                rgb = tuple(value(comp[k]) for k in ('red', 'green', 'blue'))
            except ValueError:
                continue    # a system colour name, not a value
            hits += colour_hits(rel, 0, f'colors[{i}] = #%02X%02X%02X' % rgb, rgb)
    return hits


# ---- PDF: colour operators in content streams (compressed, so a text search cannot see them)
PDF_NUM = rb'[-+]?(?:\d+(?:\.\d*)?|\.\d+)'
PDF_COLOUR_OP = re.compile(rb'(?<![\w.+-])((?:' + PDF_NUM + rb'[ \t\r\n\f\x00]+){3,})(rg|RG|scn|SCN|sc|SC|k|K)(?!\w)')
PDF_STREAM_START = re.compile(rb'(?<!end)stream\r?\n')


def pdf_streams(data):
    """Yield (dictionary, content) for every stream; content is None when it cannot be decoded here."""
    for m in PDF_STREAM_START.finditer(data):
        obj = data.rfind(b' obj', 0, m.start())
        head = data[obj:m.start()] if obj >= 0 else b''
        end = data.find(b'endstream', m.end())
        if end < 0:
            continue
        if re.search(rb'/Subtype\s*/Image|/Length[123]\b', head):
            continue    # images and embedded fonts carry no colour operators
        fm = re.search(rb'/Filter\s*(\[[^\]]*\]|/\w+)', head)
        filters = re.findall(rb'/(\w+)', fm.group(1)) if fm else []
        body = data[m.end():end]
        if not filters:
            yield head, body
        elif filters == [b'FlateDecode']:
            try:
                yield head, zlib.decompressobj().decompress(body)
            except zlib.error:
                yield head, None
        else:
            yield head, None


def pdf_colours(content):
    """Yield (operator text, (r, g, b)) for every RGB or CMYK colour operator."""
    for m in PDF_COLOUR_OP.finditer(content):
        nums = [float(v) for v in re.findall(PDF_NUM, m.group(1))]
        op = m.group(2).decode()
        if op in ('rg', 'RG') or (op.lower() in ('sc', 'scn') and len(nums) == 3):
            rgb = nums[-3:]
        elif (op in ('k', 'K') and len(nums) >= 4) or (op.lower() in ('sc', 'scn') and len(nums) == 4):
            c, mg, y, k = nums[-4:]
            rgb = ((1 - c) * (1 - k), (1 - mg) * (1 - k), (1 - y) * (1 - k))
        else:
            continue
        rgb = tuple(max(0, min(255, round(v * 255))) for v in rgb)
        yield ' '.join(m.group(1).decode().split()[-len(nums):]) + ' ' + op, rgb


def scan_pdf(rel, data):
    hits, seen = [], set()
    for head, content in pdf_streams(data):
        if content is None:
            hits.append(Hit(rel, 0, 'colour', 'unreadable-pdf-stream', head.decode('latin-1')[:120]))
            continue
        for op, rgb in pdf_colours(content):
            if rgb not in seen:
                seen.add(rgb)
                hits += colour_hits(rel, 0, f'{op} = #%02X%02X%02X' % rgb, rgb)
    return hits


def scan_raster(rel, path, image_module):
    """A hit when RASTER_SHARE or more of the opaque pixels (every frame) is close to a Nextcloud blue."""
    near, total = Counter(), 0
    try:
        with image_module.open(path) as im:
            for i in range(min(getattr(im, 'n_frames', 1), 64)):
                im.seek(i)
                frame = im.convert('RGBA')
                frame.thumbnail((RASTER_MAX_SIDE, RASTER_MAX_SIDE), image_module.Resampling.BOX)
                for count, (r, g, b, a) in frame.getcolors(frame.width * frame.height):
                    if a < 128:
                        continue
                    total += count
                    c = colour_hit((r, g, b))
                    if c:
                        near[c] += count
    except Exception as e:  # noqa: BLE001
        return [Hit(rel, 0, 'pixels', 'unreadable-image', f'{type(e).__name__}: {e}')]
    hits = []
    for c, count in near.most_common():
        if total and count / total >= RASTER_SHARE:
            hits.append(Hit(rel, 0, 'pixels', f'~{c}', f'{count / total:.1%} of the opaque pixels are close to {c}'))
    return hits


STRINGS_LINE = re.compile(r'^\s*"(?:[^"\\]|\\.)*"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;')
IB_COLOUR = re.compile(r'<color [^>]*?red="([\d.]+)" green="([\d.]+)" blue="([\d.]+)"[^>]*?(?:sRGB|calibratedRGB|displayP3)')
SWIFT_COLOUR = [
    re.compile(r'red:\s*([\d.]+)\s*/\s*255(?:\.0)?\s*,\s*green:\s*([\d.]+)\s*/\s*255(?:\.0)?\s*,\s*blue:\s*([\d.]+)\s*/\s*255'),
    re.compile(r'red:\s*(0?\.\d+|[01](?:\.0+)?)\s*,\s*green:\s*(0?\.\d+|[01](?:\.0+)?)\s*,\s*blue:\s*(0?\.\d+|[01](?:\.0+)?)\s*,'),
]


def code_literals(text):
    """Yield (line number, literal) for string literals outside comments."""
    in_block = False
    for n, line in enumerate(text.split('\n'), 1):
        i, buf, lits = 0, '', []
        while i < len(line):
            if in_block:
                j = line.find('*/', i)
                if j < 0:
                    i = len(line)
                    break
                in_block, i = False, j + 2
                continue
            c = line[i]
            if line.startswith('//', i):
                break
            if line.startswith('/*', i):
                in_block, i = True, i + 2
                continue
            if c == '"':
                j, s = i + 1, ''
                while j < len(line) and line[j] != '"':
                    if line[j] == '\\' and j + 1 < len(line):
                        s += line[j:j + 2]
                        j += 2
                    else:
                        s += line[j]
                        j += 1
                lits.append(s)
                buf += '""'
                i = j + 1
                continue
            buf += c
            i += 1
        for s in lits:
            yield n, s, buf
        if not lits:
            yield n, None, buf


# ------------------------------------------------------------------ source mode
class Project:
    """Just enough of project.pbxproj to know what ships."""

    def __init__(self, root):
        self.path = os.path.join(root, 'Nextcloud.xcodeproj', 'project.pbxproj')
        with open(self.path, encoding='utf-8') as f:
            self.text = f.read()
        # names copied or compiled into a shipped target (Resources and Sources build phases)
        self.names = set()
        for target in SHIPPED_TARGETS:
            self.names.update(self.target_phase_entries(target, 'Resources'))
            self.names.update(self.target_phase_entries(target, 'Sources'))
        # Info.plist and entitlements files are processed into every target's bundle/signature
        self.settings_files = {os.path.normpath(p.replace('$(SRCROOT)/', '')).replace(os.sep, '/')
                               for p in re.findall(r'(?:INFOPLIST_FILE|CODE_SIGN_ENTITLEMENTS) = "?([^";]+)"?;', self.text)}

    def references(self, rel):
        parts = rel.split('/')
        for p in parts:
            if p.endswith('.xcassets'):
                return p in self.names
        if rel in self.settings_files:
            return True
        if rel.endswith('.h'):      # headers are compiled through the sources that import them
            return True
        return parts[-1] in self.names

    def block(self, obj_id):
        m = re.search(r'^\t\t' + obj_id + r' (?:/\*.*?\*/ )?= \{\n', self.text, re.M)
        if not m:
            return ''
        return self.text[m.start(): self.text.find('\n\t\t};\n', m.end())]

    def target_phase_entries(self, target, phase):
        ms = re.findall(r'^\t\t([0-9A-F]{24}) /\* ' + re.escape(target) + r' \*/ = \{\n\t\t\tisa = PBXNativeTarget;',
                        self.text, re.M)
        if not ms:
            return []
        phases = re.findall(r'^\t\t\t\t([0-9A-F]{24}) /\* ' + phase + r' \*/,', self.block(ms[0]), re.M)
        out = []
        for ph in phases:
            out += re.findall(r'^\t\t\t\t[0-9A-F]{24} /\* (.+?) in ' + phase + r' \*/,', self.block(ph), re.M)
        return out

    def target_resources(self, target):
        return self.target_phase_entries(target, 'Resources')


IB_ATTR = re.compile(r'([A-Za-z][\w:.-]*)="([^"]*)"')


def scan_text_file(rel, text, ext):
    hits = []
    lines = text.split('\n')
    for n, line in enumerate(lines, 1):
        if ext == '.strings':
            m = STRINGS_LINE.match(line)
            # key names are identifiers and never shown; scan the value (or the whole comment line)
            hits += keyword_hits(rel, n, 'value' if m else 'line', m.group(1) if m else line)
        elif ext in ('.storyboard', '.xib'):
            # one attribute at a time, so an internal attribute (customModule="Nextcloud")
            # can never hide visible text on the same line
            for am in IB_ATTR.finditer(line):
                hits += keyword_hits(rel, n, 'attr', f'{am.group(1)}="{am.group(2)}"')
            rest = IB_ATTR.sub('', line)
            hits += keyword_hits(rel, n, 'line', rest)
        else:
            hits += keyword_hits(rel, n, 'line', line)
        if ext in ('.storyboard', '.xib'):
            for cm in IB_COLOUR.finditer(line):
                rgb = tuple(round(float(v) * 255) for v in cm.groups())
                c = colour_hit(rgb)
                if c:
                    hits.append(Hit(rel, n, 'colour', f'~{c}', cm.group(0)))
        elif ext in ('.svg', '.html', '.css'):
            hits += text_colour_hits(rel, n, line)
    if rel.endswith('.colorset/Contents.json'):
        hits += colorset_hits(rel, text)
    return hits


def scan_code_file(rel, text):
    hits = []
    for n, lit, code in code_literals(text):
        if lit is not None:
            hits += keyword_hits(rel, n, 'literal', lit)
            hm = HEX_LITERAL.fullmatch(lit.strip())
            if hm:
                hits += colour_hits(rel, n, f'"{lit}"', hex_rgb(hm.group(1)))
        for rx in SWIFT_COLOUR:
            for cm in rx.finditer(code if lit is None else code):
                vals = [float(v) for v in cm.groups()]
                rgb = tuple(round(v) if rx is SWIFT_COLOUR[0] else round(v * 255) for v in vals)
                c = colour_hit(rgb)
                if c:
                    hits.append(Hit(rel, n, 'colour', f'~{c}', cm.group(0)))
    # de-duplicate colour hits reported once per literal on the same line
    seen, out = set(), []
    for h in hits:
        key = (h.line, h.kind, h.keyword, h.text)
        if key not in seen:
            seen.add(key)
            out.append(h)
    return out


def scan_project(root, project):
    hits = []
    rel = 'Nextcloud.xcodeproj/project.pbxproj'
    for n, line in enumerate(project.text.split('\n'), 1):
        m = re.match(r'^\t+(PRODUCT_BUNDLE_IDENTIFIER|INFOPLIST_KEY_\w+|DEVELOPMENT_TEAM|NOURAX_\w+|MARKETING_VERSION) = (.*);$', line)
        if m:
            hits += keyword_hits(rel, n, 'setting', line.strip())
            if m.group(1) == 'DEVELOPMENT_TEAM' and m.group(2) not in ('""', ''):
                hits.append(Hit(rel, n, 'setting', 'team-id', line.strip()))
    for target in SHIPPED_TARGETS:
        kind = 'resource of ' + ('app' if target == 'Nextcloud' else target)   # target names are internal
        for res in project.target_resources(target):
            hits += keyword_hits(rel, 0, kind, res)
            if res in FORBIDDEN_RESOURCES:
                hits.append(Hit(rel, 0, kind, 'forbidden-resource', res))
    schemes = os.path.join(root, 'Nextcloud.xcodeproj', 'xcshareddata', 'xcschemes')
    for name in sorted(os.listdir(schemes)):
        srel = f'Nextcloud.xcodeproj/xcshareddata/xcschemes/{name}'
        with open(os.path.join(schemes, name), encoding='utf-8') as f:
            for n, line in enumerate(f, 1):
                if 'BundleIdentifier' in line:
                    hits += keyword_hits(srel, n, 'setting', line.strip())
    return hits


def shipped_files(root, project):
    for top in SHIPPED_DIRS:
        base = os.path.join(root, top)
        for dirpath, dirnames, filenames in os.walk(base):
            dirnames[:] = sorted(d for d in dirnames if d not in SKIP_PARTS)
            for fn in sorted(filenames):
                rel = os.path.relpath(os.path.join(dirpath, fn), root).replace(os.sep, '/')
                if project.references(rel):
                    yield rel


def scan_source(root):
    try:
        from PIL import Image   # the pixel check needs Pillow (python -m pip install pillow)
    except ImportError:
        sys.exit('check-branding: Pillow is required for the pixel check of raster images '
                 '(python -m pip install pillow)')
    project = Project(root)
    hits, scanned = [], Counter()
    for rel in shipped_files(root, project):
        ext = os.path.splitext(rel)[1].lower()
        # resource names (images, storyboards, strings ...) are visible in the bundle
        if ext not in CODE_EXT:
            name_part = rel.split('/', 1)[1] if '/' in rel else rel
            hits += keyword_hits(rel, 0, 'name', name_part)
        if ext == '.pdf':
            with open(os.path.join(root, rel), 'rb') as f:
                hits += scan_pdf(rel, f.read())
            scanned['.pdf (colour operators)'] += 1
        elif ext in RASTER_EXT:
            hits += scan_raster(rel, os.path.join(root, rel), Image)
            scanned[ext + ' (pixels)'] += 1
        elif ext in TEXT_EXT:
            with open(os.path.join(root, rel), 'rb') as f:
                hits += scan_text_file(rel, decode(f.read()), ext)
            scanned[ext] += 1
        elif ext in CODE_EXT:
            with open(os.path.join(root, rel), 'rb') as f:
                hits += scan_code_file(rel, decode(f.read()))
            scanned[ext] += 1
        else:
            scanned[ext or '(none)'] += 1
    hits += scan_project(root, project)
    scanned['project.pbxproj + xcschemes'] = 1
    return hits, scanned


def list_images(root):
    project = Project(root)
    for rel in shipped_files(root, project):
        if os.path.splitext(rel)[1].lower() in IMAGE_EXT:
            print(rel)


# ------------------------------------------------------------------ app mode
def plist_strings(obj, prefix=''):
    if isinstance(obj, dict):
        for k, v in obj.items():
            yield from plist_strings(v, f'{prefix}{k}.')
    elif isinstance(obj, list):
        for i, v in enumerate(obj):
            yield from plist_strings(v, f'{prefix}{i}.')
    elif isinstance(obj, str):
        yield prefix.rstrip('.'), obj


def scan_app(app):
    hits, scanned = [], Counter()
    app = os.path.abspath(app)
    url_re = re.compile(rb'https?://[\x21-\x7e]{0,80}next\s?cloud[\x21-\x7e]{0,80}', re.I)
    for dirpath, dirnames, filenames in os.walk(app):
        dirnames.sort()
        for fn in sorted(filenames):
            full = os.path.join(dirpath, fn)
            rel = 'app/' + os.path.relpath(full, app).replace(os.sep, '/')
            hits += keyword_hits(rel, 0, 'name', os.path.relpath(full, app).replace(os.sep, '/'))
            if fn in FORBIDDEN_RESOURCES:
                hits.append(Hit(rel, 0, 'name', 'forbidden-resource', fn))
            with open(full, 'rb') as f:
                data = f.read()
            ext = os.path.splitext(fn)[1].lower()
            if ext in ('.plist', '.strings', '.stringsdict', '.loctable', '.xcprivacy') or fn == 'Info.plist':
                try:
                    obj = plistlib.loads(data)
                except Exception:  # noqa: BLE001 (text .strings that is not a plist)
                    hits += scan_text_file(rel, decode(data), '.strings' if ext == '.strings' else '.txt')
                    scanned['text'] += 1
                    continue
                for key, val in plist_strings(obj):
                    hits += keyword_hits(rel, 0, 'value', f'{key} = {val}')
                if fn == 'Info.plist' and isinstance(obj, dict):
                    bid = obj.get('CFBundleIdentifier', '')
                    if bid and not bid.startswith(BUNDLE_BASE):
                        hits.append(Hit(rel, 0, 'value', 'bundle-id', f'CFBundleIdentifier = {bid}'))
                scanned['plist'] += 1
            elif ext in ('.json', '.txt', '.html', '.rtf', '.svg'):
                hits += scan_text_file(rel, decode(data), ext)
                scanned['text'] += 1
            elif ext == '.car' and shutil.which('xcrun'):
                try:
                    info = json.loads(subprocess.check_output(['xcrun', '--sdk', 'iphoneos', 'assetutil', '--info', full],
                                                              stderr=subprocess.DEVNULL))
                    for item in info:
                        name = item.get('Name') or item.get('RenditionName') or ''
                        hits += keyword_hits(rel, 0, 'asset', name)
                    scanned['assets.car'] += 1
                except Exception as e:  # noqa: BLE001
                    print(f'warning: assetutil failed for {rel}: {e}', file=sys.stderr)
            else:
                for m in set(url_re.findall(data)):
                    hits += keyword_hits(rel, 0, 'binary-url', m.decode('ascii', 'replace'))
                scanned['binary'] += 1
    return hits, scanned


# ------------------------------------------------------------------ allowlist
# internal = an identifier the server, the OS or a library depends on (never shown)
# legal    = a copyright or licence notice that must stay
# artwork  = a generic image whose colour is close to a Nextcloud blue by chance; looked at, it
#            shows no Nextcloud logo or art (classifies colour and pixel hits only)
CLASSES = ('internal', 'legal', 'artwork')


def load_allowlist(path):
    entries = []
    with open(path, encoding='utf-8') as f:
        for n, raw in enumerate(f, 1):
            line = raw.rstrip('\n')
            if not line.strip() or line.lstrip().startswith('#'):
                continue
            parts = [p.strip() for p in line.split(' | ')]
            if len(parts) != 4:
                sys.exit(f'{path}:{n}: expected "path glob | regex | class | reason", got {line!r}')
            glob, regex, cls, reason = parts
            if cls not in CLASSES:
                sys.exit(f'{path}:{n}: class must be one of {", ".join(CLASSES)}, got {cls!r}')
            if not reason:
                sys.exit(f'{path}:{n}: a reason is required')
            try:
                rx = re.compile(regex, re.I)
            except re.error as e:
                sys.exit(f'{path}:{n}: bad regex: {e}')
            entries.append({'line': n, 'glob': glob, 'rx': rx, 'cls': cls, 'reason': reason, 'used': 0})
    return entries


def classify(hits, entries):
    for h in hits:
        for e in entries:
            if e['cls'] == 'artwork' and not h.keyword.startswith('~'):
                continue    # artwork entries cover colour and pixel hits only, never text
            if fnmatch.fnmatchcase(h.path, e['glob']) and e['rx'].search(h.text):
                h.cls, h.reason = e['cls'], e['reason']
                e['used'] += 1
                break


# ------------------------------------------------------------------ main
def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--root', default=DEFAULT_ROOT, help='checkout to sweep (default: this one)')
    ap.add_argument('--app', help='sweep a built .app instead of the source')
    ap.add_argument('--allowlist', default=DEFAULT_ALLOWLIST)
    ap.add_argument('--no-allowlist', action='store_true', help='classify nothing (raw hit count)')
    ap.add_argument('--show-allowed', action='store_true', help='also list classified hits')
    ap.add_argument('--list-images', action='store_true', help='list shipped images for the visual check')
    ap.add_argument('--json', help='write all hits to this JSON file')
    args = ap.parse_args()

    if args.list_images:
        list_images(os.path.abspath(args.root))
        return
    if args.app:
        hits, scanned = scan_app(args.app)
        where = args.app
    else:
        hits, scanned = scan_source(os.path.abspath(args.root))
        where = os.path.abspath(args.root)
    entries = [] if args.no_allowlist else load_allowlist(args.allowlist)
    classify(hits, entries)

    open_hits = [h for h in hits if h.cls is None]
    by_cls = Counter(h.cls for h in hits if h.cls)
    if args.show_allowed:
        groups = defaultdict(list)
        for h in hits:
            if h.cls:
                groups[(h.cls, h.reason)].append(h)
        for (cls, reason), hs in sorted(groups.items()):
            print(f'ALLOWED {cls}: {reason} ({len(hs)} hits)')
            for h in hs[:3]:
                print(f'    {h}')
            if len(hs) > 3:
                print(f'    ... {len(hs) - 3} more')
    for h in open_hits:
        print(f'UNCLASSIFIED {h}')
    for e in entries:
        if not e['used']:
            print(f'warning: allowlist line {e["line"]} matched nothing: {e["glob"]} | {e["rx"].pattern}', file=sys.stderr)
    if args.json:
        with open(args.json, 'w', encoding='utf-8') as f:
            json.dump([{'path': h.path, 'line': h.line, 'kind': h.kind, 'keyword': h.keyword, 'text': h.text,
                        'class': h.cls, 'reason': h.reason} for h in hits], f, indent=1, ensure_ascii=False)
    files = sum(scanned.values())
    kinds = ', '.join(f'{k} {v}' for k, v in sorted(scanned.items()))
    print(f'check-branding: swept {files} files in {where} ({kinds})')
    print(f'check-branding: {len(hits)} hits: {by_cls.get("internal", 0)} internal, {by_cls.get("legal", 0)} legal, '
          f'{by_cls.get("artwork", 0)} artwork, {len(open_hits)} unclassified')
    print(f'check-branding: hits by keyword: ' + ', '.join(f'{k} {v}' for k, v in Counter(h.keyword for h in hits).most_common()))
    sys.exit(1 if open_hits else 0)


if __name__ == '__main__':
    main()
