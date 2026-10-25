#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Nourax
# SPDX-License-Identifier: GPL-3.0-or-later
"""Checks the screenshots of the CI screenshot job and makes the copies for docs/.

  python3 tools/ci/screens-report.py --shots screenshots --results results \
      --variants en-light de-light ar-light en-dark --docs-out screenshots-docs --json results/screens-report.json

For every variant folder (screenshots/<variant>/, written by NoDriveScreenshotUITests):
  - if it has no PNG files, export the attachments of results/ui-<variant>.xcresult instead;
  - every intro screenshot must show the Nourax cobalt background (#2563EB, as sRGB or
    Display P3 pixel values) and no Nextcloud blue (#0082C9 / #00679E);
  - the accessibility texts saved next to each screenshot (<name>.txt, from
    XCUIElement.debugDescription) must not contain "Nextcloud"/"ownCloud" in any label or value;
  - the walk log (walk.jsonl) is summarised.
All PNGs (also screenshots/simctl/) are copied to --docs-out at a height of --docs-height px.
Exit 1 on a problem. Needs Pillow.
"""

import argparse
import glob
import json
import os
import re
import shutil
import subprocess
import sys

from PIL import Image

COBALT = {'sRGB': (37, 99, 235), 'P3': (54, 98, 227)}                 # #2563EB
NEXTCLOUD_BLUES = {'#0082C9 sRGB': (0, 130, 201), '#0082C9 P3': (56, 128, 195),
                   '#00679E sRGB': (0, 103, 158), '#00679E P3': (43, 101, 154)}
TOL = 10
NAME_RE = re.compile(r'next\s?cloud|own\s?cloud', re.I)
# label: 'text'  value: text  placeholderValue: 'text'  (XCUIElement.debugDescription lines)
FIELD_RE = re.compile(r"\b(label|value|placeholderValue|title): ('(?:[^'\\]|\\.)*'|[^,}\n]*)")


def close(px, ref, tol=TOL):
    return all(abs(a - b) <= tol for a, b in zip(px[:3], ref))


def profile_name(im):
    icc = im.info.get('icc_profile')
    if not icc:
        return 'none'
    try:
        from PIL import ImageCms
        return ImageCms.ImageCmsProfile(__import__('io').BytesIO(icc)).profile.profile_description.strip()
    except Exception as e:   # noqa: BLE001 - only a report field
        return f'unreadable ({e.__class__.__name__})'


def export_attachments(xcresult, out_dir, variant):
    """xcresulttool export attachments (Xcode 16+) -> files + manifest.json; rename to the attachment names."""
    tmp = out_dir + '.export'
    shutil.rmtree(tmp, ignore_errors=True)
    os.makedirs(tmp)
    subprocess.run(['xcrun', 'xcresulttool', 'export', 'attachments', '--path', xcresult, '--output-path', tmp],
                   check=True)
    with open(os.path.join(tmp, 'manifest.json'), encoding='utf-8') as f:
        manifest = json.load(f)
    os.makedirs(out_dir, exist_ok=True)
    n = 0
    for test in manifest:
        for att in test.get('attachments', []):
            src = os.path.join(tmp, att['exportedFileName'])
            name = att.get('suggestedHumanReadableName') or att['exportedFileName']
            name = re.sub(r'_\d+_[0-9A-Fa-f-]{36}(?=\.\w+$)', '', name)
            if name.startswith(variant + '-'):
                name = name[len(variant) + 1:]
            shutil.copy2(src, os.path.join(out_dir, name))
            n += 1
    shutil.rmtree(tmp, ignore_errors=True)
    return n


def check_colours(path):
    im = Image.open(path)
    info = {'size': list(im.size), 'mode': im.mode, 'profile': profile_name(im)}
    rgb = im.convert('RGB')
    w, h = rgb.size
    # intro background: both edges, 20 % to 70 % of the height (clear of the logo tile, title and button)
    points = [(int(w * x), int(h * y)) for x in (0.04, 0.96) for y in (0.2, 0.3, 0.45, 0.6, 0.7)]
    samples = [rgb.getpixel(p) for p in points]
    info['background_samples'] = [list(s) for s in samples]
    info['cobalt_matches'] = sum(1 for s in samples if any(close(s, c) for c in COBALT.values()))
    small = rgb.resize((max(1, w // 4), max(1, h // 4)), Image.NEAREST)
    data = list(small.getdata())
    nc = sum(1 for px in data if any(close(px, c) for c in NEXTCLOUD_BLUES.values()))
    info['nextcloud_blue_fraction'] = round(nc / len(data), 5)
    return info


def text_hits(txt_path):
    hits = []
    with open(txt_path, encoding='utf-8', errors='replace') as f:
        for n, line in enumerate(f, 1):
            for field, value in FIELD_RE.findall(line):
                if NAME_RE.search(value):
                    hits.append(f'{os.path.basename(txt_path)}:{n}: {field}: {value.strip()}')
    return hits


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--shots', required=True)
    ap.add_argument('--results', required=True)
    ap.add_argument('--variants', nargs='+', required=True)
    ap.add_argument('--docs-out', required=True)
    ap.add_argument('--docs-height', type=int, default=1200)
    ap.add_argument('--json')
    args = ap.parse_args()

    problems, report = [], {'variants': {}, 'simctl': {}}
    for variant in args.variants:
        vdir = os.path.join(args.shots, variant)
        pngs = sorted(glob.glob(os.path.join(vdir, '*.png')))
        source = 'files written by the UI test'
        xcresult = os.path.join(args.results, f'ui-{variant}.xcresult')
        if not pngs and os.path.isdir(xcresult):
            n = export_attachments(xcresult, vdir, variant)
            source = f'{n} attachments exported from {os.path.basename(xcresult)}'
            pngs = sorted(glob.glob(os.path.join(vdir, '*.png')))
        v = {'source': source, 'screenshots': {}, 'text_hits': [], 'walk': []}
        if not pngs:
            problems.append(f'{variant}: no screenshots')
        for p in pngs:
            name = os.path.splitext(os.path.basename(p))[0]
            info = check_colours(p)
            if 'intro-slide' in name:
                if info['cobalt_matches'] < 8:
                    problems.append(f'{variant}/{name}: background is not Nourax cobalt '
                                    f'({info["cobalt_matches"]}/10 samples match; samples {info["background_samples"]})')
                if info['nextcloud_blue_fraction'] > 0.001:
                    problems.append(f'{variant}/{name}: Nextcloud blue on {info["nextcloud_blue_fraction"]:.2%} of the screen')
            v['screenshots'][name] = info
        for t in sorted(glob.glob(os.path.join(vdir, '*.txt'))):
            v['text_hits'] += text_hits(t)
        for hit in v['text_hits']:
            problems.append(f'{variant}: visible text names Nextcloud: {hit}')
        walk = os.path.join(vdir, 'walk.jsonl')
        if os.path.exists(walk):
            with open(walk, encoding='utf-8') as f:
                v['walk'] = [json.loads(line) for line in f if line.strip()]
        report['variants'][variant] = v

    for p in sorted(glob.glob(os.path.join(args.shots, 'simctl', '*.png'))):
        report['simctl'][os.path.splitext(os.path.basename(p))[0]] = check_colours(p)

    # copies for docs/screenshots/ios (smaller, same folder layout)
    shutil.rmtree(args.docs_out, ignore_errors=True)
    copied = 0
    for p in sorted(glob.glob(os.path.join(args.shots, '*', '*.png'))):
        rel = os.path.relpath(p, args.shots)
        out = os.path.join(args.docs_out, rel)
        os.makedirs(os.path.dirname(out), exist_ok=True)
        im = Image.open(p)
        icc = im.info.get('icc_profile')
        im = im.convert('RGB')
        if im.height > args.docs_height:
            im = im.resize((round(im.width * args.docs_height / im.height), args.docs_height), Image.LANCZOS)
        im.save(out, optimize=True, **({'icc_profile': icc} if icc else {}))
        copied += 1
    report['docs_copies'] = copied
    report['problems'] = problems
    if args.json:
        with open(args.json, 'w', encoding='utf-8') as f:
            json.dump(report, f, indent=2, ensure_ascii=False)

    for variant, v in report['variants'].items():
        print(f'== {variant}: {len(v["screenshots"])} screenshots ({v["source"]})')
        for name, info in v['screenshots'].items():
            extra = f', cobalt {info["cobalt_matches"]}/10' if 'intro-slide' in name else ''
            print(f'   {name}: {info["size"][0]}x{info["size"][1]} {info["profile"]}'
                  f', Nextcloud blue {info["nextcloud_blue_fraction"]:.3%}{extra}')
        for step in v['walk']:
            print(f'   walk: {json.dumps(step, ensure_ascii=False)[:400]}')
    for name, info in report['simctl'].items():
        print(f'== simctl/{name}: {info["size"][0]}x{info["size"][1]} {info["profile"]}, cobalt {info["cobalt_matches"]}/10')
    print(f'docs copies: {copied}')
    for p in problems:
        print('PROBLEM:', p)
    print('screens-report:', 'ok' if not problems else f'{len(problems)} problem(s)')
    return 0 if not problems else 1


if __name__ == '__main__':
    sys.exit(main())
