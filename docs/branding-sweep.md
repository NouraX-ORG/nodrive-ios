<!--
SPDX-FileCopyrightText: 2026 Nourax
SPDX-License-Identifier: GPL-3.0-or-later
-->
# NoDrive for iOS: the no-Nextcloud sweep

The owner's rule: no screen of the app may show Nextcloud's name, logo, colours or links, in any
language. Credit to Nextcloud lives only in the repository (README, NOTICE, licence files, source
headers). This file is the final sweep table (round 2, **PASS**), checked on 2026-10-25 against
`main` = `b03563c3c9`; the docs added afterwards change no app file.

| | |
|---|---|
| Base | upstream tag `35.2.1` (`faf9617904`) |
| Checked | `main` `b03563c3c9` and its CI build, run [40206804804](https://github.com/NouraX-ORG/nodrive-ios/actions/runs/40206804804) |
| Gate in CI | `tools/check-branding.py`, job "Branding gate", on every push |
| Result | **0 user-visible and 0 unclassified hits**, in the source and in the built app |

## Result

| Gate condition | Result |
|---|---|
| Zero unclassified user-visible hits | **Yes.** 0 user-visible, 0 unclassified, in the source and in the built app |
| Every screenshot clean | **Yes.** All 34 screenshots of run 40206804804 (en-light, en-dark, de-light, ar-light, simctl), the copies in [screenshots/ios/](screenshots/ios/) and 81 launch-video frames |
| `check-branding.py` green in CI | **Yes.** `483 hits: 264 internal, 217 legal, 2 artwork, 0 unclassified` |
| No contact with Nextcloud services | **Yes.** No Nextcloud service host in the code, the config or the built binaries; CI network gate `ok`, 0 forbidden DNS names |

## How the sweep was done

- **What ships:** the Sources and Resources build phases of the 9 product targets were read from
  `project.pbxproj` (930 shipped files on main, 940 on 35.2.1), plus each target's Info.plist and
  entitlements. Every other file in the product folders was swept too and marked "not shipped".
- **Decoding:** UTF-8 and UTF-16 (most translations are UTF-16).
- **Context of each hit:** `.strings` key, value or comment; Swift/Objective-C comment, literal or
  identifier; storyboard/XIB attribute; plist key path; project build setting.
- **Keywords (case-insensitive):** `next cloud`/`nextcloud` and `own cloud`/`owncloud` (with any
  space, `-`, `_` or `.` inside), `mirall`, `niedermann`, `twsweb`, `crypto cloud`; the App Store
  ids of Nextcloud (1125420102), Talk (1296825574) and Notes (813973264); `0082c9`, `00679e`,
  `49abe9`/`49abea`; the brand name in Arabic, Persian, Korean, Japanese, Russian, Hebrew, Thai,
  Greek, Bengali and Hindi script; the word "cloud" in those scripts (read one by one); the legal
  words `gmbh` and `faggiana`.
- **Images:** every image looked at, not only by name (contact sheets), plus colour scans of vector
  fills and pixels.
- **Built app:** all 1077 files of the `nodrive-ios-simulator-app` artifact: every plist and
  compiled `.strings` file (890), printable UTF-8/UTF-16 text in 184 binaries (Mach-O, nibs,
  `Assets.car`), every URL host, every vector inside the 7 `Assets.car` files.
- **Screens:** every screenshot of the CI walk, in four variants (section "Screenshots").

## Hits before and after

| Measure | 35.2.1 (base) | main |
|---|---|---|
| All keyword occurrences (incl. legal words and the generic word "cloud") | 4630 | 3674 |
| Spec keywords only, all swept files | 3368 | 2421 |
| Spec keywords only, shipped files | 2185 | 1713 |
| **User-visible** (`.strings` values in every language, shipped artwork, display names, licence-page links) | **784** | **0** |
| **Ids that clash with the real app** (bundle ids, app group, keychain group, URL scheme, document group) | **104** | **0** |
| **Unclassified** (Swift literals: Nextcloud links, push proxy, App Store links, `nextcloud://`, "Nextcloud notification", `#49abe9`; a shipped developer README) | **53** | **0** |
| User-visible + unclassified, shipped files only | 476 | **0** |
| Internal | 1747 | 1736 |
| Legal | 1923 | 1928 |
| Generic word "cloud" in ja/ko/th ("your cloud", "federated cloud ID") | 19 | 10 |
| Brand name in non-Latin script (Arabic ×5, Korean ×4) | 9 | 0 |
| Nextcloud colours in shipped artwork | 11 files (app icon, `directory.pdf`, `document.pdf`, 7 folder SVGs, `Reasons to use Nextcloud.pdf`) | 0 |
| Nextcloud blues in code, storyboards, SVGs and colour sets | 13 exact (`#0082C9` ×4, `#00679E` ×7, `#49ABE9` ×1, `#0075E3`) | 0 |
| `tools/check-branding.py` with today's allowlist | 1216 hits, 735 unclassified, exit 1 | 483 hits, 0 unclassified, exit 0 |

## Hits kept on purpose

| # | Pattern | Count | Class | Reason |
|---|---|---|---|---|
| 1 | `SPDX-FileCopyrightText: Nextcloud GmbH`, `Marino Faggiana` and author headers in .swift/.m/.h | 1379 | legal | Upstream copyright headers stay untouched |
| 2 | `.strings` header comment (`//  Nextcloud`, `Author Marino Faggiana`) | 535 | legal | Copyright comment; comments are never shown |
| 3 | `Acknowledgements.rtf`: "Copyright (C) Nextcloud GmbH and contributors. Modifications copyright (C) 2026 Nourax.", the NextcloudKit licence line, the MIT line for Marino Faggiana | 7 | legal | The one text-only licence page ([NOTICE.md](../NOTICE.md) section 4). No pictures; links only to gnu.org, apache.org and github.com/NouraX-ORG/nodrive-ios. Not legal advice |
| 4 | Swift/ObjC identifiers: `NextcloudKit` (609), `NextcloudVersion`, `appDatabaseNextcloud`, `versionNextcloudiOS`, … | 689 | internal | Class, module, variable and library names |
| 5 | Xcode metadata: target and scheme `Nextcloud`, `Nextcloud*Tests`, `TEST_HOST`, SPM `github.com/nextcloud/NextcloudKit`, `productName = "Crypto Cloud"`, the orphan `Nextcloud Hub.png` build file, `ORGANIZATIONNAME` | 324 | internal / legal | Build metadata only; every display name is NoDrive; `Nextcloud Hub.png` is in no build phase |
| 6 | `.strings` key names `_apps_nextcloud_detect_`, `_create_nextcloudtext_document_`, `_warning_owncloud_` (+3 uses in code) | 324 | internal | Keys are never shown; their values say "Detected %@ apps", "Create text document", "…unsupported version of Nourax Workspace…" |
| 7 | `.strings` comment `// MARK: File name validator (used by NextcloudKit…)` | 107 | internal | Comment naming a library |
| 8 | Developer comments (`nextcloud://` examples, `docs.nextcloud.com` API references, the commented-out `customerpush.nextcloud.com`) | 97 | internal | Comments are not compiled |
| 9 | Storyboard/XIB `customModule="Nextcloud"` (and `_TtC9Nextcloud…` in 70 compiled nibs) | 74 | internal | Swift module name that Interface Builder uses to find classes |
| 10 | WebDAV namespaces `http://owncloud.org/ns`, `http://nextcloud.org/ns` | 38 | internal | The server requires them |
| 11 | File names: `Nextcloud.xcodeproj`, `*.xcscheme`, `Nextcloud-Bridging-Header.h`, `NCNetworking+NextcloudKitDelegate.swift`, … | 17 | internal | Project and source file names; none ships under that name |
| 12 | SwiftUI preview fixtures (`cloudtest.nextcloud.com`, a sample address, "Good afternoon, Marino Faggiana") | 11 | internal | Only built for Xcode previews (`isXcodeRunningForPreviews`); never shown on a device |
| 13 | Queue, keychain and drag labels `com.nextcloud.*`, `text/com.nextcloud.ocId` | 8 (+library) | internal | Inside NoDrive's own process and keychain group |
| 14 | `LSApplicationQueriesSchemes` `nextcloudtalk`, `nextcloudnotes` and the `nextcloudtalk://` literals | 7 | internal | Only checks whether the Talk/Notes apps are installed; their sidebar block is off and their links are empty |
| 15 | `Package.resolved`, `iOSClient/.tx/config`, developer READMEs | 21 | internal / legal | Not in any target |
| 16 | `BGTaskSchedulerPermittedIdentifiers` `com.nextcloud.refreshTask`/`processingTask` | 4 | internal | Per-app ids; the OS never shows them |
| 17 | `nextcloud.realm`, `nextcloud(-debug).sqlite`, `Library/Application Support/Nextcloud` | 4 (+library) | internal | File and folder names inside NoDrive's own container |
| 18 | User agents `Mozilla/5.0 (iOS) Nextcloud-iOS/35.2.1 NoDrive`; editors `(iPhone) Mobile Nextcloud-iOS/…`, `(iPad) Nextcloud-iOS/…` | 3 | internal | Server 35 `USER_AGENT_CLIENT_IOS` must match ([branding.md](branding.md) section 8) |
| 19 | End-to-end encryption: certificate-request organisation `"Nextcloud"`, key self-test text | 3 | internal | Never shown; changing them could break key checks |
| 20 | `brand == "Nextcloud"`, `brand != "Nextcloud"` | 2 | internal | Comparisons; NoDrive's brand is "NoDrive" |
| 21 | Legacy ids `it.twsweb.nextcloud.metadata`, keychain service `"Crypto Cloud"`, `twofactor_nextcloud_notification`, `productName.contains("owncloud")`, `Nextcloud-Swift.h` | 7 | internal | Unarchiver id, one-time migration, server app id, server detection, generated header |
| 22 | Generic word "cloud" in ja/ko (shipped) and th (not shipped) | 10 | generic | "your cloud", "federated cloud ID"; not the brand |
| 23 | Built app: `NextcloudKit_NextcloudKitUI.bundle` and its string "The address of your Nextcloud web interface…" | 125 | internal (**watch**) | Only used by NextcloudKitUI's `ServerAddressView`, which NoDrive never shows (NoDrive uses only `UnifiedShareListView` and `CreateUnifiedShareTrigger`). Re-check after each NextcloudKit update |
| 24 | Built app: Firebase/Crashlytics hosts inside the linked SDK | n/a | internal | `FirebaseApp.configure()` never runs (`disable_crash_service = true`, no `GoogleService-Info.plist`); Google services, not Nextcloud; none seen in CI DNS |
| 25 | Built app: Swifter demo-server sample hosts | n/a | internal | Third-party sample HTML; Swifter only serves localhost |
| 26 | Built app: MobileVLCKit "Copyright … g10 Code GmbH" | 2 | legal | Third-party copyright; not Nextcloud |
| 27 | Accessibility identifier `Nextcloud.NCIntroView` in the UI-test dumps | 8 | internal | Automatic module.class identifier; not displayed and not spoken |
| 28 | Built app: `CFBundleExecutable = Nextcloud`, `Nextcloud.SceneDelegate`, the Alamofire `status.php` user agent `Nextcloud/35.2.1 (org.nourax.nodrive; …)` | 3 | internal (**borderline**) | From `PRODUCT_NAME = $(TARGET_NAME)`. Never on an app screen; visible only in crash-log file names and to drive.nourax.org. Renaming the executable is an owner decision (note A) |
| 29 | Upstream root files `Animation.gif`, `Nextcloud Hub.png`, `Reasons to use Nextcloud.pdf`, `widget.png`, `AppIcon.icon/`, `BackgroundUploadExtension/diagram.png` | 6 files | internal (not shipped) | Nextcloud art, but in no build phase and not in the built app; kept to keep upstream merges simple |
| 30 | Generic artwork near a Nextcloud blue: `rgb.svg` (colour wheel, one `#0B88DA` segment), `mac.png` (classic Mac picture) | 2 | artwork | Looked at; neither is Nextcloud art. Pinned in the allowlist |

## Images

| Set | Count | Result |
|---|---|---|
| Every tracked image outside `docs/` and `Tests/`, on white and on `#0B1220` | 88 | Only the Nourax "N" (app icon, Action Assistant icon, `logo` ×3, `intro1` ×3, `branding/nourax-logo.png`), generic glyphs, cobalt folders, `document.pdf` in `#3B82F6`, third-party marks (Collabora, ONLYOFFICE, EuroOffice, VLC, GitHub, Twitter), a Mac picture and a test photo. All Nextcloud art is in unshipped root files (row 29) |
| Text and streams of all 59 PDF/SVG files | 59 | The keyword is only in `Reasons to use Nextcloud.pdf` (not shipped) |
| Base 35.2.1 versions of the changed or removed images | 22 | Nextcloud app icon, Nextcloud logo, Talk logo, `#00679E` folders, `#0082C9` directory, `#49ABEA` document: all replaced or removed |
| Built app: loose icons and `NoDriveBlank.pdf` | 5 | The Nourax "N" on white; a blank page |
| Built app: vectors inside `Assets.car` (app, Share, Widget) | 78 | Black/white/grey glyphs, `#2563EB`, `#3B82F6`; 0 Nextcloud colours or names in all 7 `Assets.car` files |
| Icon variants | 3 sets | One 1024 universal image each; no dark or tinted variant |

## Built app (artifact `nodrive-ios-simulator-app` of run 40206804804)

| Bundle | Display name | Bundle id |
|---|---|---|
| NoDrive.app | NoDrive | `org.nourax.nodrive` (version 35.2.1 (1), NouraxVersion 35.2.1-nourax.1, URL scheme `nodrive`) |
| Action Assistant.appex | NoDrive Assistant | `org.nourax.nodrive.action-assistant` |
| File Provider Extension.appex (Files app) | NoDrive | `org.nourax.nodrive.file-provider` (document group `group.org.nourax.nodrive`) |
| File Provider Extension UI.appex | NoDrive | `org.nourax.nodrive.file-provider-ui` |
| Notification Service Extension.appex | NoDrive | `org.nourax.nodrive.notification-service` |
| Share.appex (share sheet) | NoDrive | `org.nourax.nodrive.share` |
| Widget.appex | NoDrive | `org.nourax.nodrive.widget` |
| WidgetDashboardIntentHandler.appex | NoDrive | `org.nourax.nodrive.widget-intent-handler` |
| BackgroundUploadExtension.appex | NoDrive | `org.nourax.nodrive.background-upload` |

- No value in any shipped language names Nextcloud.
- URL hosts in the bundle: `drive.nourax.org`; apple, w3, gnu, apache, github and media-standard
  hosts; Firebase (row 24); Swifter samples (row 25); placeholders such as `example.com`; the
  preview fixture (row 12); the namespace hosts (row 10). **No Nextcloud service host** (push,
  updates, App Store, news, help, docs).
- Languages: 49 + Base, the same as upstream (`knownRegions`). Arabic and other right-to-left
  languages are not among them, so on an Arabic phone NoDrive's own texts are English.

## Screenshots

All 34 screenshots of run 40206804804 were looked at, full size. The copies are in
[screenshots/ios/](screenshots/ios/) (index in [testing.md](testing.md)).

| Screen | en-light | en-dark | de-light | ar-light |
|---|---|---|---|---|
| 00-prompt-1 (notifications) | "NoDrive" Would Like to Send You Notifications | same, dark | „NoDrive" möchte dir Mitteilungen senden | Arabic prompt naming NoDrive |
| 00-prompt-2 (photo library) | Allow "NoDrive" to access your photo library? | same, dark | Darf „NoDrive" … zugreifen? | Arabic prompt naming NoDrive (usage text English) |
| 01/02 intro slides | Nourax "N" on cobalt `#2563EB`, "Log in" | same | "Anmelden" | right-to-left system UI |
| 04 sign-in browser | `drive.nourax.org` (CI stand-in page) | same | same | same |
| 05 home screen | NoDrive icon | same | same | right-to-left grid |
| 06 share sheet | "NoDrive" with the Nourax "N" | same | same | same |
| 07 share extension | "NoDrive", "No account found" | same | "Fehler / Kein Konto gefunden" | "NoDrive" |

Leftovers: none. The accessibility dumps contain only the internal identifier of row 27. The
screenshot report measured at most 0.017% Nextcloud-blue pixels per screenshot (anti-aliasing),
with no problems.

## Network

- Code and config: push proxy empty, crash service off, App Store/source/Talk/Notes/more-apps links
  empty, privacy link hidden while `NOURAX_PRIVACY_URL` is empty, no updater or news feed. Apple's
  own rating prompt (`SKStoreReviewController`) stays; it is not a Nextcloud link.
- CI network gate (run 40206804804): 565 DNS queries for 157 names, **0 forbidden**
  (no nextcloud, owncloud, crashlytics, firebase or googleapis name), no DNS query made by a NoDrive
  process; the drive.nourax.org stand-in saw 4 Login Flow v2 starts with the user agent
  `Mozilla/5.0 (iOS) Nextcloud-iOS/35.2.1 NoDrive`. Caveat: the kernel dropped packets during the
  capture, so the DNS log supports, rather than replaces, the code and binary checks above.

## Follow-ups (none blocks the gate)

1. Make `check-branding.py --app` a gate: add app-mode allowlist entries (rows 6, 10, 12, 16, 23,
   28 and the Swift-package resource-bundle ids), then remove `continue-on-error` in CI. Today it
   reports 833 hits, all classified by hand above.
2. Note A (owner decision): rename the executable to NoDrive (`PRODUCT_NAME`), or keep it.
3. The launch screen did not appear in the CI recording (black frames, then the intro). Its colour
   and image are checked in the source; the owner sees it on the Mac.
4. After sign-in (owner test): upload-conflict dialog icons, Settings → Information →
   Acknowledgements, the share screen (NextcloudKitUI).
5. Server side: the device name under Settings → Security comes from the user agent (see
   [testing.md](testing.md)).
