<!--
SPDX-FileCopyrightText: 2026 Nourax
SPDX-License-Identifier: GPL-3.0-or-later
-->
# NOTICE: NoDrive for iOS

NoDrive for iOS is made by **Nourax**. It is a modified version of the **Nextcloud iOS app**,
release tag [`35.2.1`](https://github.com/nextcloud/ios/tree/35.2.1)
(commit `faf961790404b7e574f68d6ea1bc11f1ecd0f5d3`), from
[https://github.com/nextcloud/ios](https://github.com/nextcloud/ios).

This file lists the licensed software, the trademarks, what Nourax changed, and the decision about
the in-app legal notices. **It is not legal advice.**

## 1. Licensed software

### The app

| Part | Licence | Copyright |
|---|---|---|
| Nextcloud iOS app (almost all code in this repository) | GNU GPL v3.0 or later ([LICENSE.txt](LICENSE.txt)) | Nextcloud GmbH, Marino Faggiana and the Nextcloud contributors ([AUTHORS.md](AUTHORS.md) and the SPDX headers in each file) |
| Upstream's App Store statement | [COPYING.iOS](COPYING.iOS): the upstream copyright holders will not pursue a licence violation that comes only from the conflict between the GPL and the Apple App Store terms | Nextcloud iOS copyright holders |
| Nourax's changes (`tools/`, `branding/`, `docs/`, `.github/workflows/ios.yml`, the NoDrive tests, and the edits that `tools/rebrand.py` makes) | GNU GPL v3.0 or later | 2026 Nourax |
| Translations | GNU GPL v3.0 or later | Nextcloud translators (Transifex) |
| Other files in the repository | CC0-1.0, MIT and others, as [REUSE.toml](REUSE.toml) and [LICENSES/](LICENSES/) say | as stated there |

Upstream's copyright headers, `LICENSE.txt`, `COPYING.iOS`, `LICENSES/`, `AUTHORS.md` and
`REUSE.toml` are kept exactly as upstream wrote them. New Nourax files carry
`SPDX-FileCopyrightText: 2026 Nourax` and `SPDX-License-Identifier: GPL-3.0-or-later`.

### Third-party software inside the app

The app links these libraries (Swift packages from
`Nextcloud.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`, plus two vendored
folders). The list is kept in [tools/legal/third-party.json](tools/legal/third-party.json), which
also produces the in-app licence page (section 4).

| Library | Licence | Copyright |
|---|---|---|
| NextcloudKit (incl. NextcloudKitUI) | GPL-3.0-or-later | Nextcloud GmbH and Marino Faggiana |
| Alamofire | MIT | 2014-2022 Alamofire Software Foundation |
| CodeScanner | MIT | 2021 Paul Hudson |
| DropDown | MIT | 2014 kevin-hirsch |
| EasyTipView | MIT | 2015 Teodor Patras |
| GRDB.swift | MIT | 2015-2025 Gwendal Roue |
| GzipSwift | MIT | 2014-2026 1024jp |
| KeychainAccess | MIT | 2014 kishikawa katsumi |
| LucidBanner | MIT | 2025 Marino Faggiana |
| Mantis | MIT | 2018 Yingtao Guo |
| MarkdownKit | MIT | 2016 Ivan Bruel |
| PopupView | MIT | 2019 exyte |
| QRCodeReader.swift | MIT | 2014-present Yannick Loriot |
| SwiftRichString | MIT | 2018 Daniele Margutti |
| SwiftyJSON | MIT | 2017 Ruoyu Fu |
| SwiftyXMLParser | MIT | 2016 Yahoo Japan Corporation |
| TagListView | MIT | 2015 LIU Dongyuan |
| TLPhotoPicker | MIT | 2017 wade.hawk |
| TOPasscodeViewController (vendored in `iOSClient/Utility/`) | MIT | 2017 Timothy Oliver |
| NYMnemonic (vendored in `iOSClient/Utility/`) | MIT | 2014 Nybex, Inc. |
| Swifter | BSD-3-Clause | 2014 Damian Kolakowski |
| LevelDB | BSD-3-Clause | 2011 The LevelDB Authors |
| nanopb | Zlib | 2011 Petteri Aimonen |
| OpenSSL (package by Marcin Krzyzanowski) | Apache-2.0 | The OpenSSL Project Authors |
| Realm Swift and Realm Core | Apache-2.0 | Realm Inc. |
| SwiftNIO, SwiftNIO SSL | Apache-2.0 | Apple Inc. and the SwiftNIO project authors |
| Swift Collections, Swift Atomics, Swift System | Apache-2.0 with Runtime Library Exception | Apple Inc. and the Swift project authors |
| Firebase iOS SDK and its Google dependencies (GoogleUtilities, GoogleDataTransport, GoogleAppMeasurement, App Check, Promises, GTMSessionFetcher, Interop, Google Ads on-device conversion) | Apache-2.0 | Google LLC |
| Abseil, gRPC (binaries used by Firebase) | Apache-2.0 | The Abseil Authors; The gRPC Authors |
| VLCKit (MobileVLCKit) | LGPL-2.1 | VideoLAN and VLC authors |

Firebase stays linked because upstream links it, but NoDrive never starts it
(`disable_crash_service = true`, no `GoogleService-Info.plist`). Removing the package is a later to-do.

## 2. Trademarks

- **"Nextcloud" and the Nextcloud logo are trademarks of Nextcloud GmbH**
  ([LICENSES/LicenseRef-NextcloudTrademarks.txt](LICENSES/LicenseRef-NextcloudTrademarks.txt)).
  **NoDrive is not made or endorsed by Nextcloud GmbH.** The name "Nextcloud" appears in this
  repository only as credit, in copyright and licence notices, and in internal identifiers
  (class, module, library and project names, API paths, the server-required user agent).
- The app shows no Nextcloud name, logo, colours or links on any screen. Upstream's Nextcloud artwork
  was replaced or removed from everything the app ships (see [docs/branding-sweep.md](docs/branding-sweep.md)).
  A few upstream art files stay in the repository root only to keep upstream merges simple; they are
  in no build phase and not in the built app: `AppIcon.icon/`, `Animation.gif`, `Nextcloud Hub.png`,
  `Reasons to use Nextcloud.pdf`, `widget.png`, `BackgroundUploadExtension/diagram.png`.
- **"Nourax", "NoDrive" and the Nourax logo belong to Nourax.** The logo files are
  `branding/nourax-logo.png` and the images that `tools/make-icons.py` makes from it
  (`Brand/Custom.xcassets/AppIcon.appiconset/`, `logo.imageset/`, `intro1.imageset/`,
  `Action Assistant/Images.xcassets/AppIcon.appiconset/`). `REUSE.toml` is upstream's file and still
  lists some of these paths under Nextcloud's trademark annotation; which terms apply to the Nourax
  logo files is an owner decision (to-do), after which `REUSE.toml` can be updated.
- Names and logos of other products that the app can open (Collabora, ONLYOFFICE, VLC and others)
  belong to their owners. Upstream shows them the same way.

## 3. What Nourax changed

All repeatable changes are made by `tools/rebrand.py` (code, plists, project, strings) and
`tools/make-icons.py` (images); details are in [docs/branding.md](docs/branding.md).

| Area | Change |
|---|---|
| Name | The app, the share-sheet entry, the Files-app location, widgets and notifications are called **NoDrive** (the Action extension "NoDrive Assistant") |
| Ids | Every bundle id, the app group, the keychain group and the URL scheme are new (`org.nourax.nodrive…`, `nodrive://`), so NoDrive installs next to the real Nextcloud app |
| Server | Fixed to `https://drive.nourax.org`. The intro's "Log in" starts Nextcloud's Login Flow v2 in the browser. No server-address screen, no "Sign up", no "Host your own server", one account only |
| Switched off | Nextcloud's push proxy and the push entitlement, crash reporting (Firebase Crashlytics and its upload phase), "more Nextcloud apps" and App Store links, the source-code link, the second app group shared with Nextcloud's apps |
| Privacy link | Read from the build setting `NOURAX_PRIVACY_URL`; it is empty, so the link is hidden |
| Strings | Six translated texts that named Nextcloud (or ownCloud) now name NoDrive or Nourax Workspace, in every language; widget, notification and placeholder texts |
| Images and colours | App icon, logo and intro images from the Nourax logo; Nextcloud artwork (logo, Talk logo, intro glyphs, dark/tinted icons) removed; Nextcloud blues in the tint, launch screen, folders, directory and document glyphs and avatar colours replaced with Nourax colours |
| Version | Shown as `35.2.1-nourax.1`; build number 1 |
| Licence page | Settings → Information → Acknowledgements is generated as one text-only page (section 4) |
| Tests and CI | NoDrive unit tests and a screenshot UI test; our own CI in `.github/workflows/ios.yml`; upstream's workflows moved to `.github/upstream-workflows/` (switched off; they need Nextcloud's machines) |
| Docs | This file, `README.md` (upstream's is in `docs/upstream-README.md`), `docs/` |

## 4. In-app legal notices (GPL-3.0 section 5(d)): decision

**This is not legal advice.** A lawyer should review it before NoDrive is published in a store.

**Decision:** keep **one text-only licence page**, the existing *Settings → Information →
Acknowledgements*. Remove everything else that pointed at Nextcloud (privacy link, source-code
link, Nextcloud copyright footer).

**What the page contains** (generated from `tools/legal/third-party.json` into
`iOSClient/Settings/Acknowledgements.rtf`):
- "NoDrive by Nourax is free software … GNU General Public License … version 3 … or any later version",
  the no-warranty statement, and the copyright line "Copyright (C) Nextcloud GmbH and contributors.
  Modifications copyright (C) 2026 Nourax.";
- a link to the GPL text (gnu.org) and to the source code (`https://github.com/NouraX-ORG/nodrive-ios`);
- every library in section 1 with its licence and copyright line;
- the full MIT, BSD-3-Clause and zlib texts; Apache-2.0 and LGPL-2.1 as a short statement with a
  link (apache.org, gnu.org).

No pictures, no logos, no nextcloud.com links. It names Nextcloud GmbH only as a copyright holder,
because the licences require copyright notices to be kept.

**Why:**
1. *What upstream shows:* upstream 35.2.1 shows an Acknowledgements page (third-party names,
   licences, copyright lines), a privacy link to nextcloud.com, a source-code link to
   github.com/nextcloud/ios and a "Nextcloud … for iOS" footer. It does not show a full GPL notice
   with a no-warranty statement. Under the last sentence of GPL-3.0 section 5(d), a modified version
   only has to show "Appropriate Legal Notices" if the program it is based on does; so the GPL alone
   would not force a page.
2. *What the bundled libraries require:* the MIT, BSD-3-Clause, Apache-2.0 and LGPL-2.1 libraries
   ask for their copyright and licence notices to go with copies in binary form (MIT: "in all copies
   or substantial portions"; BSD-3-Clause clause 2: "Redistributions in binary form must reproduce
   the above copyright notice…"; Apache-2.0 section 4; LGPL-2.1 section 6). An iOS app has no other
   place for these notices than the app itself, so **a notice page is needed**.
3. *Keep it as small as the law allows* (owner rule): one page, text only, reached from the
   existing Information section. The GPL notice and the source link were added to the same page
   because they cost nothing and help meet GPL-3.0 sections 4 and 6 when the app is distributed.

**Open points for the review before publishing (owner to-do):**
- whether the full Apache-2.0, LGPL-2.1 and GPL-3.0 texts (and any Apache `NOTICE` files of the
  libraries) must be shown in the app, rather than linked;
- the LGPL-2.1 relinking terms for VLCKit in an App Store app;
- whether Nourax adds an App Store statement like `COPYING.iOS` for its own changes;
- the App Store export-compliance answer (upstream's `ITSEncryptionExportComplianceCode` was removed
  because it belongs to Nextcloud's App Store record).
