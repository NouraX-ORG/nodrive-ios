#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Nourax
# SPDX-License-Identifier: GPL-3.0-or-later
"""Make every NoDrive icon and logo image from the one Nourax logo.

Source: branding/nourax-logo.png (500x500 RGBA, cobalt "N", byte-identical copy
of nourax/assets/brand/nourax-logo.png).

Rules (owner, 2026-10-25):
  * never redraw, recolour, crop or stretch the logo;
  * enlarging it proportionally onto a plain white square is approved above
    500 px (small softness at 1024 px is accepted);
  * no monochrome / dark / tinted variants (owner to-do).

Outputs (all committed):
  Brand/Custom.xcassets/AppIcon.appiconset/Icon-App-1024x1024@1x.png   app icon
  Action Assistant/Images.xcassets/AppIcon.appiconset/Icon-App-1024x1024@1x.png
  Brand/Custom.xcassets/logo.imageset/logo{,@2x,@3x}.png              150/300/450 px tile
  Brand/Custom.xcassets/intro1.imageset/intro1{,@2x,@3x}.png          150/300/450 px tile
  + the matching Contents.json files.
Removed (Nextcloud artwork): logo.svg, intro1.svg, intro2/3/4.imageset,
  the Action Assistant "Senza titolo*.png" icons (incl. dark/tinted variants).

Usage:
  python3 tools/make-icons.py           write the images (idempotent)
  python3 tools/make-icons.py --check   exit 1 if any output is missing, differs
                                        or breaks a logo rule; writes nothing
"""
import argparse
import io
import json
import os
import shutil
import sys

from PIL import Image

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..'))
LOGO = os.path.join(ROOT, 'branding', 'nourax-logo.png')
LOGO_SIZE = (500, 500)

ICON_SIZE = 1024
ICON_SCALE = 1.30          # proportional enlargement (approved above 500 px)
TILE_SIZES = {'': 150, '@2x': 300, '@3x': 450}   # @1x/@2x/@3x of a 150 pt tile
WHITE = (255, 255, 255)

APPICON_SETS = [
    'Brand/Custom.xcassets/AppIcon.appiconset',
    'Action Assistant/Images.xcassets/AppIcon.appiconset',
]
TILE_SETS = {
    'Brand/Custom.xcassets/logo.imageset': 'logo',
    'Brand/Custom.xcassets/intro1.imageset': 'intro1',
}
REMOVE = [
    'Brand/Custom.xcassets/logo.imageset/logo.svg',
    'Brand/Custom.xcassets/intro1.imageset/intro1.svg',
    'Brand/Custom.xcassets/intro2.imageset',
    'Brand/Custom.xcassets/intro3.imageset',
    'Brand/Custom.xcassets/intro4.imageset',
    'Action Assistant/Images.xcassets/AppIcon.appiconset/Senza titolo.png',
    'Action Assistant/Images.xcassets/AppIcon.appiconset/Senza titolo 1.png',
    'Action Assistant/Images.xcassets/AppIcon.appiconset/Senza titolo 2.png',
]

ICON_NAME = 'Icon-App-1024x1024@1x.png'
APPICON_JSON = {
    'images': [{'filename': ICON_NAME, 'idiom': 'universal', 'platform': 'ios', 'size': '1024x1024'}],
    'info': {'author': 'xcode', 'version': 1},
}


def tile_json(name):
    return {
        'images': [{'filename': f'{name}{sfx}.png', 'idiom': 'universal', 'scale': f'{i + 1}x'}
                   for i, sfx in enumerate(TILE_SIZES)],
        'info': {'author': 'xcode', 'version': 1},
    }


def json_bytes(obj):
    # Xcode style: 2-space indent, " : " separator, trailing newline.
    text = json.dumps(obj, indent=2, separators=(',', ' : '))
    return (text + '\n').encode('utf-8')


def load_logo():
    with Image.open(LOGO) as f:
        logo = f.copy()
    if logo.size != LOGO_SIZE or logo.mode != 'RGBA':
        sys.exit(f'make-icons: {LOGO} must be {LOGO_SIZE} RGBA, found {logo.size} {logo.mode}')
    return logo


def on_white(logo, canvas, logo_px):
    """Scale the whole logo (incl. its transparent margin) to logo_px x logo_px,
    proportionally, and centre it on an opaque white canvas x canvas square."""
    scaled = logo if logo_px == logo.width else logo.resize((logo_px, logo_px), Image.Resampling.LANCZOS)
    bg = Image.new('RGBA', (canvas, canvas), WHITE + (255,))
    off = (canvas - logo_px) // 2
    bg.alpha_composite(scaled, (off, off))
    return bg.convert('RGB')


def png_bytes(img):
    buf = io.BytesIO()
    img.save(buf, format='PNG', optimize=True)
    return buf.getvalue()


def planned(logo):
    """Return {relative path: bytes} for every file this tool owns."""
    out = {}
    icon = on_white(logo, ICON_SIZE, round(LOGO_SIZE[0] * ICON_SCALE))
    for s in APPICON_SETS:
        out[f'{s}/{ICON_NAME}'] = ('png', icon)
        out[f'{s}/Contents.json'] = ('bytes', json_bytes(APPICON_JSON))
    for s, name in TILE_SETS.items():
        for sfx, px in TILE_SIZES.items():
            out[f'{s}/{name}{sfx}.png'] = ('png', on_white(logo, px, px))
        out[f'{s}/Contents.json'] = ('bytes', json_bytes(tile_json(name)))
    return out


def dominant_colour(img_rgba, alpha_min=250):
    """Most common fully opaque colour that is not white."""
    counts = {}
    for n, (r, g, b, a) in img_rgba.getcolors(img_rgba.width * img_rgba.height):
        if a >= alpha_min and (r, g, b) != WHITE:
            counts[(r, g, b)] = counts.get((r, g, b), 0) + n
    return max(counts, key=counts.get)


def rule_checks(logo, rel, img):
    """Logo rules: size, opaque RGB, white corners, colour unchanged, no stretch/crop."""
    errs = []
    w, h = img.size
    if w != h:
        errs.append(f'{rel}: not square ({w}x{h})')
    if img.mode != 'RGB':
        errs.append(f'{rel}: mode {img.mode}, expected opaque RGB')
    rgb = img.convert('RGB')
    for corner in [(0, 0), (w - 1, 0), (0, h - 1), (w - 1, h - 1)]:
        if rgb.getpixel(corner) != WHITE:
            errs.append(f'{rel}: corner {corner} is not plain white')
    # Colour: the dominant non-white colour must be the logo's own colour.
    src = dominant_colour(logo)
    got = dominant_colour(rgb.convert('RGBA'))
    if max(abs(a - b) for a, b in zip(src, got)) > 2:
        errs.append(f'{rel}: dominant colour {got} differs from logo {src} (recoloured?)')
    # Geometry: the logo's opaque bounding box, scaled, must keep its aspect ratio
    # and lie fully inside the canvas (no crop, no stretch).
    l, t, r, b = logo.getchannel('A').getbbox()
    src_ratio = (r - l) / (b - t)
    nonwhite = Image.eval(rgb.convert('L'), lambda v: 255 if v < 250 else 0).getbbox()
    if not nonwhite:
        errs.append(f'{rel}: logo missing')
    else:
        nl, nt, nr, nb = nonwhite
        ratio = (nr - nl) / (nb - nt)
        if abs(ratio - src_ratio) > 0.03:
            errs.append(f'{rel}: logo aspect {ratio:.3f} != source {src_ratio:.3f} (stretched?)')
        if nl == 0 or nt == 0 or nr == w or nb == h:
            errs.append(f'{rel}: logo touches the edge (cropped?)')
    return errs


def same_pixels(a, b):
    if a.size != b.size or a.mode != b.mode:
        return False
    pa, pb = a.tobytes(), b.tobytes()
    worst = max(abs(x - y) for x, y in zip(pa, pb)) if pa != pb else 0
    return worst <= 8   # tolerate tiny resampler differences between Pillow versions


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--check', action='store_true', help='verify only; exit 1 on any difference')
    args = ap.parse_args()

    logo = load_logo()
    plan = planned(logo)
    problems, changed = [], []

    for rel, (kind, payload) in plan.items():
        path = os.path.join(ROOT, rel)
        if kind == 'png':
            problems += rule_checks(logo, rel, payload)
            data = png_bytes(payload)
            if os.path.exists(path):
                with Image.open(path) as cur:
                    cur.load()
                    if same_pixels(cur, payload):
                        continue
        else:
            data = payload
            if os.path.exists(path):
                with open(path, 'rb') as f:
                    if f.read() == data:
                        continue
        changed.append(rel)
        if not args.check:
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, 'wb') as f:
                f.write(data)

    for rel in REMOVE:
        path = os.path.join(ROOT, rel)
        if os.path.exists(path):
            changed.append(f'{rel} (remove)')
            if not args.check:
                shutil.rmtree(path) if os.path.isdir(path) else os.remove(path)

    for p in problems:
        print(f'RULE  {p}')
    for c in changed:
        print(f'{"WOULD CHANGE" if args.check else "WROTE"}  {c}')
    print(f'make-icons: {len(plan)} outputs, {len(changed)} {"to change" if args.check else "changed"}, '
          f'{len(problems)} rule problems')
    if problems or (args.check and changed):
        sys.exit(1)


if __name__ == '__main__':
    main()
