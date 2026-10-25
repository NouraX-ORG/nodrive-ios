#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Nourax
# SPDX-License-Identifier: GPL-3.0-or-later
"""Simulated entitlements for the unsigned NoDrive simulator build (CI only).

Why: our CI builds with CODE_SIGNING_ALLOWED=NO (no signing of any kind). Then
Xcode writes no entitlements into the binaries, and on the iOS Simulator the app
gets no app-group container and no keychain access group: Realm cannot open its
database in group.org.nourax.nodrive and the app stops at launch.

What Xcode itself does for a simulator build (checked on upstream's own CI
product, Nextcloud.app from nextcloud/ios run 39742792212): the entitlements are
linked into the executable as the Mach-O sections __TEXT,__entitlements (XML
plist) and __TEXT,__ents_der (DER), and the ad-hoc signature carries an empty
entitlements dict. The simulator reads the sections.

This tool does the same without any signing:
  * for each app / app-extension target that has CODE_SIGN_ENTITLEMENTS in
    Nextcloud.xcodeproj, it writes <bundle id>.plist (XML) and <bundle id>.der
    into the output folder, with $(AppIdentifierPrefix) and
    $(TeamIdentifierPrefix) empty (no team) and application-identifier set to
    the bundle id, as Xcode does; the macOS sandbox keys (com.apple.security.*
    except the app groups) are left out, as in Xcode's own simulator sections;
  * it writes simulated-entitlements.xcconfig for `xcodebuild -xcconfig`, which
    adds two `-sectcreate` linker flags to app and appex targets only and sets
    ENABLE_DEBUG_DYLIB=NO, so the sections land in the main executable (with the
    debug dylib, OTHER_LDFLAGS would go into NAME.debug.dylib).

Usage: python3 tools/ci/simulated-entitlements.py OUTDIR [--root REPO] [--self-test DIR]
Standard library only. --self-test DIR compares the DER encoder with pairs
NAME.entitlements / NAME.ents_der taken from an Xcode-built binary.
"""
import argparse
import os
import plistlib
import re
import sys

PROJECT = 'Nextcloud.xcodeproj/project.pbxproj'
KEEP_SECURITY = {'com.apple.security.application-groups'}


# ------------------------------------------------------------------ DER (CoreEntitlements format)
def der_len(n):
    if n < 0x80:
        return bytes([n])
    b = n.to_bytes((n.bit_length() + 7) // 8, 'big')
    return bytes([0x80 | len(b)]) + b


def tlv(tag, content):
    return bytes([tag]) + der_len(len(content)) + content


def der_value(v):
    if isinstance(v, bool):
        return tlv(0x01, b'\xff' if v else b'\x00')
    if isinstance(v, int):
        n = (v.bit_length() + 8) // 8 or 1
        return tlv(0x02, v.to_bytes(n, 'big', signed=True))
    if isinstance(v, str):
        return tlv(0x0c, v.encode('utf-8'))
    if isinstance(v, list):
        return tlv(0x30, b''.join(der_value(x) for x in v))
    if isinstance(v, dict):
        items = sorted(v.items(), key=lambda kv: kv[0].encode('utf-8'))
        return tlv(0xb0, b''.join(tlv(0x30, der_value(k) + der_value(x)) for k, x in items))
    raise TypeError(f'unsupported entitlement value {v!r}')


def der_entitlements(d):
    # [APPLICATION 16] { INTEGER 1 (version), [CONTEXT 16] dict }
    return tlv(0x70, tlv(0x02, b'\x01') + der_value(d))


# ------------------------------------------------------------------ project
def targets(root):
    """Yield (target name, bundle id, entitlements path) for targets with CODE_SIGN_ENTITLEMENTS."""
    with open(os.path.join(root, PROJECT), encoding='utf-8') as f:
        text = f.read()
    configs = {m.group(1): m.group(2) for m in re.finditer(
        r'^\t\t(\w{24}) /\* \w+ \*/ = \{\n\t\t\tisa = XCBuildConfiguration;\n\t\t\tbuildSettings = \{\n(.*?)\n\t\t\t\};',
        text, re.S | re.M)}
    for m in re.finditer(r'/\* Build configuration list for PBXNativeTarget "([^"]+)" \*/ = \{\n'
                         r'\t\t\tisa = XCConfigurationList;\n\t\t\tbuildConfigurations = \(\n(.*?)\n\t\t\t\);', text, re.S):
        name = m.group(1)
        ids = re.findall(r'(\w{24}) /\* Debug \*/', m.group(2))
        if len(ids) != 1 or ids[0] not in configs:
            sys.exit(f'simulated-entitlements: no Debug configuration found for target {name!r}')
        settings = configs[ids[0]]
        ent = re.search(r'^\t+CODE_SIGN_ENTITLEMENTS = "?([^";]+)"?;', settings, re.M)
        bid = re.search(r'^\t+PRODUCT_BUNDLE_IDENTIFIER = "?([^";]+)"?;', settings, re.M)
        if not ent:
            continue
        if not bid or '$' in bid.group(1):
            sys.exit(f'simulated-entitlements: target {name!r} needs a literal PRODUCT_BUNDLE_IDENTIFIER')
        path = ent.group(1).replace('$(SRCROOT)', root).replace('$(PROJECT_DIR)', root)
        path = os.path.normpath(path if os.path.isabs(path) else os.path.join(root, path))
        yield name, bid.group(1), path


def expand(obj):
    if isinstance(obj, str):
        s = obj.replace('$(AppIdentifierPrefix)', '').replace('$(TeamIdentifierPrefix)', '')
        if '$(' in s:
            sys.exit(f'simulated-entitlements: unexpanded variable in {obj!r}')
        return s
    if isinstance(obj, list):
        return [expand(x) for x in obj]
    if isinstance(obj, dict):
        return {k: expand(v) for k, v in obj.items()}
    return obj


XCCONFIG = """// Generated by tools/ci/simulated-entitlements.py for the unsigned CI simulator build.
// Do not use for device builds. See the tool's docstring.
NODRIVE_SIM_ENTITLEMENTS_DIR = {outdir}
NODRIVE_SIM_ENTITLEMENTS_LDFLAGS_app = -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __entitlements -Xlinker $(NODRIVE_SIM_ENTITLEMENTS_DIR)/$(PRODUCT_BUNDLE_IDENTIFIER).plist -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __ents_der -Xlinker $(NODRIVE_SIM_ENTITLEMENTS_DIR)/$(PRODUCT_BUNDLE_IDENTIFIER).der
NODRIVE_SIM_ENTITLEMENTS_LDFLAGS_appex = $(NODRIVE_SIM_ENTITLEMENTS_LDFLAGS_app)
OTHER_LDFLAGS = $(inherited) $(NODRIVE_SIM_ENTITLEMENTS_LDFLAGS_$(WRAPPER_EXTENSION))
ENABLE_DEBUG_DYLIB = NO
"""


def self_test(folder):
    names = sorted(f[:-len('.entitlements')] for f in os.listdir(folder) if f.endswith('.entitlements'))
    bad = 0
    for n in names:
        with open(os.path.join(folder, n + '.entitlements'), 'rb') as f:
            d = plistlib.loads(f.read().rstrip(b'\0'))
        with open(os.path.join(folder, n + '.ents_der'), 'rb') as f:
            want = f.read()
        got = der_entitlements(d)
        ok = got == want
        bad += not ok
        print(f'self-test {n}: {"same bytes" if ok else "DIFFERENT"} ({len(got)}/{len(want)})')
    if not names:
        sys.exit('self-test: no vectors')
    sys.exit(1 if bad else 0)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('outdir', nargs='?')
    ap.add_argument('--root', default=os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..')))
    ap.add_argument('--self-test', metavar='DIR')
    args = ap.parse_args()
    if args.self_test:
        self_test(args.self_test)
    if not args.outdir:
        ap.error('OUTDIR is required')
    root = os.path.abspath(args.root)
    outdir = os.path.abspath(args.outdir)
    if ' ' in outdir:
        sys.exit('simulated-entitlements: OUTDIR must not contain spaces (it goes into linker flags)')
    os.makedirs(outdir, exist_ok=True)
    count = 0
    for name, bid, path in targets(root):
        with open(path, 'rb') as f:
            ents = expand(plistlib.load(f))
        # Like Xcode's simulator sections: the macOS sandbox keys (com.apple.security.*,
        # except the app groups) are not used on iOS and are left out.
        ents = {k: v for k, v in ents.items() if not k.startswith('com.apple.security.') or k in KEEP_SECURITY}
        ents['application-identifier'] = bid
        with open(os.path.join(outdir, bid + '.plist'), 'wb') as f:
            plistlib.dump(ents, f, fmt=plistlib.FMT_XML, sort_keys=True)
        with open(os.path.join(outdir, bid + '.der'), 'wb') as f:
            f.write(der_entitlements(ents))
        print(f'{name}: {bid} <- {os.path.relpath(path, root)}: {sorted(ents)}')
        count += 1
    with open(os.path.join(outdir, 'simulated-entitlements.xcconfig'), 'w', encoding='utf-8', newline='\n') as f:
        f.write(XCCONFIG.format(outdir=outdir))
    print(f'simulated-entitlements: {count} targets, xcconfig {os.path.join(outdir, "simulated-entitlements.xcconfig")}')
    if count != 9:
        sys.exit(f'simulated-entitlements: expected 9 app/extension targets, found {count}')


if __name__ == '__main__':
    main()
