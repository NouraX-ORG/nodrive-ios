<!--
SPDX-FileCopyrightText: 2026 Nourax
SPDX-License-Identifier: GPL-3.0-or-later
-->
# NoDrive for iOS: branding

How Nextcloud iOS `35.2.1` becomes **NoDrive** by **Nourax**: every id, the server, the colours and
icons, and how the three branding tools work. All values below are set by `tools/rebrand.py` and
`tools/make-icons.py`; nobody edits the files by hand.

| | |
|---|---|
| App name | **NoDrive** (Action extension: **NoDrive Assistant**) |
| Maker | Nourax (`NSHumanReadableCopyright` = "NoDrive by Nourax") |
| Server | `https://drive.nourax.org` (Nourax Workspace, Nextcloud server 35), fixed |
| Version | `35.2.1-nourax.1` (see [Version](#7-version)) |
| Bundle id base | `org.nourax.nodrive` |

## 1. Every id

All ids differ from the real Nextcloud app, so both apps can be installed side by side.

### Bundle ids (`PRODUCT_BUNDLE_IDENTIFIER`, Debug and Release)

| Target | Upstream | NoDrive |
|---|---|---|
| Nextcloud (the app) | `it.twsweb.Nextcloud` | `org.nourax.nodrive` |
| Share (share-sheet extension) | `it.twsweb.Nextcloud.Share` | `org.nourax.nodrive.share` |
| File Provider Extension (Files app) | `it.twsweb.Nextcloud.File-Provider-Extension` | `org.nourax.nodrive.file-provider` |
| File Provider Extension UI | `it.twsweb.Nextcloud.File-Provider-Extension-UI` | `org.nourax.nodrive.file-provider-ui` |
| Notification Service Extension | `it.twsweb.Nextcloud.Notification-Service-Extension` | `org.nourax.nodrive.notification-service` |
| Widget | `it.twsweb.Nextcloud.Widget` | `org.nourax.nodrive.widget` |
| WidgetDashboardIntentHandler | `it.twsweb.Nextcloud.WidgetDashboardIntentHandler` | `org.nourax.nodrive.widget-intent-handler` |
| Action Assistant | `it.twsweb.Nextcloud.Action-Assistant` | `org.nourax.nodrive.action-assistant` |
| BackgroundUploadExtension (ExtensionKit, iOS 27) | `it.twsweb.Nextcloud.BackgroundUploadExtension` | `org.nourax.nodrive.background-upload` |
| NextcloudUnitTests | `it.twsweb.NextcloudTests` | `org.nourax.nodrive.unit-tests` |
| NextcloudUITests (product `NoDriveUITests`) | `it.twsweb.NextcloudUITests.NextcloudUITests` | `org.nourax.nodrive.ui-tests` |
| NextcloudIntegrationTests | `it.twsweb.NextcloudIntegrationTests.NextcloudIntegrationTests` | `org.nourax.nodrive.integration-tests` |

The schemes that launch the app (`BundleIdentifier` in `Nextcloud.xcodeproj/xcshareddata/xcschemes/*.xcscheme`)
point at `org.nourax.nodrive`; `com.apple.springboard` in `Widget.xcscheme` stays.

### Other ids

| What | Upstream | NoDrive |
|---|---|---|
| App group (9 entitlements files, `NCBrand.capabilitiesGroup`) | `group.it.twsweb.Crypto-Cloud` | `group.org.nourax.nodrive` |
| Second app group (shared with Nextcloud's other apps) | `group.com.nextcloud.apps` | removed (`capabilitiesGroupApps = ""`) |
| Keychain access group (9 entitlements files) | `$(AppIdentifierPrefix)it.twsweb.Crypto-Cloud` | `$(AppIdentifierPrefix)org.nourax.nodrive` |
| App URL scheme (`CFBundleURLSchemes`, `NCGlobal.appScheme`, 5 widget actions, widget `open-file`, Action Assistant `assistant/shared-text`) | `nextcloud` | `nodrive` |
| Login callback scheme (`webLoginAutenticationProtocol`) | `nc://` | `nodrive://` |
| `CFBundleURLName` | `it.twsweb.Nextcloud` | `org.nourax.nodrive` |
| File Provider document group (`NSExtensionFileProviderDocumentGroup`) | `group.it.twsweb.Crypto-Cloud` | `group.org.nourax.nodrive` |
| File Provider domain (`FileProviderDomain.swift`) | id `"<userId> (<host>)"`, name `"<user> (<host>)"` | same format, so `"<user> (drive.nourax.org)"`; it lives inside `org.nourax.nodrive.file-provider` |
| Files-app location name (File Provider `CFBundleDisplayName`) | Nextcloud | **NoDrive** |
| Share-sheet name (Share `CFBundleDisplayName`) | Nextcloud | **NoDrive** |
| Action-sheet name | Nextcloud Assistant | **NoDrive Assistant** |
| Display names of the other extensions | Nextcloud, "Notification Service Extension", "WidgetDashboardIntentHandler", "BackgroundUploadExtension" | **NoDrive** |
| UI-test runner on the home screen | `NextcloudUITests-Runner` | `NoDriveUITests-Runner` |
| `DEVELOPMENT_TEAM` | `NKUJUXUJ3B` (Nextcloud's team) | empty |
| `aps-environment` (push) | development | removed |
| `ITSEncryptionExportComplianceCode` | Nextcloud's App Store record | removed |

### Kept on purpose (internal, never shown)

- Target, product, module and project names: `Nextcloud` (so the executable inside `NoDrive.app`
  is still called `Nextcloud`), `Nextcloud.xcodeproj`, `@testable import Nextcloud`,
  `Nextcloud-Bridging-Header.h`, the library names `NextcloudKit`/`NextcloudKitUI`.
- WebDAV namespaces `http://nextcloud.org/ns` and `http://owncloud.org/ns`, API paths
  (`/ocs/`, `/remote.php/`, `/index.php/login/v2`).
- File names inside NoDrive's own container: `nextcloud.realm`, `Library/Application Support/Nextcloud`.
- Keychain service `com.nextcloud.keychain` (scoped by NoDrive's keychain group), queue labels
  `com.nextcloud.*`, drag type `text/com.nextcloud.ocId`.
- BGTaskScheduler ids `com.nextcloud.refreshTask` and `com.nextcloud.processingTask` (per app).
- `LSApplicationQueriesSchemes` `nextcloudtalk`, `nextcloudnotes` (only checks whether those apps are installed).
- Siri intent types `AccountIntent`, `DashboardIntent` and widget kinds (per extension).

[docs/branding-sweep.md](branding-sweep.md) lists every kept hit with its reason.

## 2. Server and sign-in

| `NCBrandOptions` (in `Brand/NCBrand.swift`) | Upstream | NoDrive | Effect |
|---|---|---|---|
| `brand` | Nextcloud | NoDrive | name in titles, Face ID reason, share extension, widgets |
| `loginBaseUrl` | "" | `https://drive.nourax.org` | the one server |
| `disable_request_login_url` | false | true | no server-address field |
| `disable_multiaccount` | false | true | one account; no "Add account" |
| `disable_intro` | false | false | the intro is the sign-in entry |
| `linkLoginHost`, `linkloginPreferredProviders` | nextcloud.com links | "" | no "Host your own server", no "Sign up" |
| `webLoginAutenticationProtocol` | `nc://` | `nodrive://` | browser sign-in callback |
| `use_AppConfig` | false | false | no MDM server override |
| `enforce_servers` | [] | [] | |

The intro (`Brand/Intro/NCIntroViewController.swift`) has two slides (the Nourax logo tile, and the SF
Symbol `folder.badge.person.crop`) and one **Log in** button (accessibility id `nodriveLoginButton`).
"Log in" starts Login Flow v2 against `https://drive.nourax.org` and opens the browser sheet
(`ASWebAuthenticationSession`) at `https://drive.nourax.org/login/v2/flow/<token>`. The page there
offers "Log in with Nourax". The server-address screen (`NCLogin`) is never reached.

## 3. Switched off (no calls to Nextcloud services)

| Item | How |
|---|---|
| Push via Nextcloud's proxy | `pushNotificationServerProxy = ""` (also blanked in `NCBrand.init`), `aps-environment` removed |
| Crash reporting (Firebase Crashlytics) | `disable_crash_service = true`; `GoogleService-Info.plist` and the "Crashlytics dSYM Upload" build phase removed from the app target |
| "More Nextcloud apps", Talk/Notes App Store links | `disable_show_more_nextcloud_apps_in_settings = true`; `talkAppStoreUrl`, `notesAppStoreUrl`, `moreAppsUrl` = "" in `NCGlobal.swift` |
| App Store link of the app | `appStoreUrl = ""` |
| Source-code link | `disable_source_code_in_settings = true`, `sourceCode = ""` |
| Privacy link | `privacy` is read from Info.plist `NouraxPrivacyURL` = build setting `NOURAX_PRIVACY_URL`, which is empty; the button in Settings is shown only when it is set |
| Theming from the server | `use_themingColor = false` (always the Nourax colours) |
| Nextcloud art in the app | `AppIcon.icon`, `Nextcloud Hub.png` and a developer README removed from the app's Resources; "Reasons to use Nextcloud.pdf" replaced by a blank `Brand/NoDriveBlank.pdf` |
| Widget placeholder links | `https://nextcloud.com/` → `https://drive.nourax.org/` |

## 4. Texts

- Placeholders filled with `brand` now say NoDrive.
- `tools/rebrand.py` rewrites the **values** (never the keys) of six keys in every language
  (`iOSClient/Supporting Files/*.lproj/Localizable.strings`, UTF-16 and UTF-8 kept as they are):
  - to "NoDrive": `_access_photo_not_enabled_msg_`, `_privacy_footer_`, `_no_client_cert_found_desc_`;
  - to "Nourax Workspace": `_warning_unsupported_`, `_background_upload_extension_apache_warning_`;
  - `_warning_owncloud_` gets the same text as `_warning_unsupported_`.
  The format specifiers (`%@`, `%d`, …) must stay identical, or the tool stops.
- Swift literals: widget footer "NoDrive files", notification fallback "NoDrive notification".
- Storyboard/XIB placeholders: "your Nourax Workspace web interface", `user1@example.com`.
- Settings footer: "NoDrive 35.2.1-nourax.1" and "Nourax Workspace <server version>".
- Unified search shows Talk results with the system symbol `bubble.left.and.bubble.right`
  (the Talk logo `talk-template` was removed).

## 5. Colours

From `nourax/docs/THEME_BIBLE.md`: primary `#2563EB`, primary light `#3B82F6`, accent `#F97316`.

| Where | Upstream | NoDrive |
|---|---|---|
| `NCBrandColor.customer` (tint, intro and login background) | `#0082C9` | `#2563EB` |
| Launch screen background (`Brand/LaunchScreen.storyboard`) | `#0082C9` | `#2563EB` |
| File Provider UI background (`File Provider Extension UI/MainInterface.storyboard`) | `#0075E3` | `#2563EB` |
| Avatar palette (`createUserColors` stops) | magenta / yellow / `#0082C9` | `#F97316` / `#3B82F6` / `#2563EB` |
| `documentIconColor` | `#49ABE9` | `#3B82F6` |
| 7 folder SVGs in `iOSClient/Images.xcassets/folder*.imageset` | `#00679E` | `#2563EB` |
| `directory.pdf` glyph | `#0082C9` | `#2563EB` |
| `document.pdf` glyph | `#49ABEA` | `#3B82F6` |

Spreadsheet green and presentation orange (file-type colours) stay. Dark mode uses the iOS system
backgrounds; the intro, launch screen and tint stay cobalt. Fonts are the system fonts.

## 6. Icons and images

The only logo is `branding/nourax-logo.png`, a byte-identical copy of
`nourax/assets/brand/nourax-logo.png` (500×500 RGBA, cobalt "N"). It is never redrawn, recoloured,
cropped or stretched. Above 500 px it is enlarged proportionally onto a plain white square (owner
approval, 2026-10-25).

| Output (made by `tools/make-icons.py`) | Size | Content |
|---|---|---|
| `Brand/Custom.xcassets/AppIcon.appiconset/Icon-App-1024x1024@1x.png` | 1024×1024, RGB, opaque | logo ×1.30 on white, centred; one "universal" entry, Xcode makes all sizes |
| `Action Assistant/Images.xcassets/AppIcon.appiconset/Icon-App-1024x1024@1x.png` | same | same |
| `Brand/Custom.xcassets/logo.imageset/logo{,@2x,@3x}.png` | 150/300/450 px | logo scaled down on a white square (launch screen, File Provider UI) |
| `Brand/Custom.xcassets/intro1.imageset/intro1{,@2x,@3x}.png` | 150/300/450 px | same tile (intro slide 1) |

Removed: the Nextcloud `logo.svg` and `intro1.svg`, `intro2/3/4.imageset` (including the Talk
bubble), the Action Assistant icons `Senza titolo*.png` (with their dark and tinted variants), and
`iOSClient/Images.xcassets/talk-template.imageset` (Talk logo).

**No monochrome, dark, tinted or Icon Composer (`.icon`) variants** were made: they need the
owner's approval first (owner to-do). The upstream `AppIcon.icon` folder stays in the repo but is
not in the build (with it in Resources, Xcode would use it instead of the asset-catalog icon).

## 7. Version

| Setting | Value | Shown where |
|---|---|---|
| `MARKETING_VERSION` (upstream) | `35.2.1` | `CFBundleShortVersionString`, the user agent |
| `NOURAX_VERSION_SUFFIX` (new, project level) | `-nourax.1` | |
| Info.plist `NouraxVersion` | `$(MARKETING_VERSION)$(NOURAX_VERSION_SUFFIX)` = `35.2.1-nourax.1` | Settings footer "NoDrive 35.2.1-nourax.1" |
| `CURRENT_PROJECT_VERSION` | `1` (was 0) | `CFBundleVersion` of the app and all extensions |

To make `-nourax.2`: change `VERSION_SUFFIX` and `BUILD_NUMBER` at the top of `tools/rebrand.py`,
run it, and update the expected values in `Tests/NextcloudUnitTests/NoDriveBrandingTests.swift`
and `tools/ci/inspect-products.py`.

## 8. User agent

Nextcloud server 35 recognises the iOS client by `USER_AGENT_CLIENT_IOS` in
`lib/public/IRequest.php`: `/^Mozilla\/5\.0 \(iOS\) (?:ownCloud|Nextcloud)\-iOS\/([^ ]*).*$/`.
`brandUserAgent = "NoDrive"` is appended with a space (upstream used `-`), so the version group
stays `35.2.1`.

| Used for | User agent |
|---|---|
| API, WebDAV, Login Flow v2, web views | `Mozilla/5.0 (iOS) Nextcloud-iOS/35.2.1 NoDrive` |
| Document editors on iPhone (upstream code) | `Mozilla/5.0 (iPhone) Mobile Nextcloud-iOS/35.2.1` |
| Document editors on iPad (upstream code) | `Mozilla/5.0 (iPad) Nextcloud-iOS/35.2.1` |
| `status.php` checks through Alamofire's default | `Nextcloud/35.2.1 (org.nourax.nodrive; build:1; iOS <version>) Alamofire/<version>` |

The unit test `userAgentMatchesServer` checks the first line against the server pattern.

## 9. The branding tools

All three are Python 3 scripts, run from the repository root, and safe to run again and again.
CI runs `rebrand.py --check`, `make-icons.py --check` and `check-branding.py` in the
"Branding gate" job on every push.

### `tools/rebrand.py`

Applies every NoDrive change to the upstream tree (standard library only).

```bash
python3 tools/rebrand.py              # apply
python3 tools/rebrand.py --check      # change nothing; exit 1 if a run would change a file
python3 tools/rebrand.py --bundle-base org.nourax.nodrive.devxy   # other id base (local device test only; never commit)
python3 tools/rebrand.py --root ../some/checkout                  # work on another checkout
```

- **One place for every value:** the configuration block at the top (name, maker, server, URL
  scheme, version suffix, build number, privacy URL, colours, target → id suffix, display names,
  translation keys).
- **Steps, in order:** `Brand/NCBrand.swift` values, colours and user agent → the intro sign-in →
  small Swift edits (URL scheme, links, widget and notification texts, privacy-button guard, Talk
  icon) → Info.plists and entitlements → `project.pbxproj` and schemes → storyboards and XIBs →
  folder SVGs → glyph PDFs → translations → `Acknowledgements.rtf` (from
  `tools/legal/third-party.json`) → `Brand/NoDriveBlank.pdf`.
- **Idempotent:** every step sets the NoDrive value, or replaces the exact upstream text, or sees
  that the NoDrive text is already there. A second run prints `0 changed`.
- **Fails loudly:** if an upstream anchor is missing or appears twice, it stops with
  `rebrand: ERROR: …` (exit 2) and writes nothing. It never guesses.
- **Project file as text:** `project.pbxproj` is edited line by line, not re-serialised; line
  endings stay LF; new objects (the NoDrive test files) get fixed ids from a hash of their path.
- **Validation before writing:** every plist and entitlements file must parse; the project file must
  have balanced braces, unique object ids and no new dangling references.
- **Glyph PDFs:** only the colour operators in the drawing streams change; the PDF is recompressed
  and its cross-reference table rebuilt.
- **Our own source folder:** `iOSClient/Workspace/` (the Workspace apps feature: apps list, origin rules,
  session hand-off, in-app web view) and its test files are added to the Nextcloud app target and the test
  targets by the project-file step (`APP_SOURCE_FOLDERS`, `TEST_FILES`), with fixed ids from a hash of the path.
- Images are **not** made here; that is `make-icons.py`.

### `tools/make-icons.py`

Makes every icon and logo image from `branding/nourax-logo.png` (needs Pillow).

```bash
python3 tools/make-icons.py           # write the images and Contents.json files; remove Nextcloud art
python3 tools/make-icons.py --check   # write nothing; exit 1 if an output is missing, differs or breaks a rule
```

`--check` compares pixels (not PNG bytes, which differ between Pillow versions) and checks the logo
rules: sizes, opaque RGB for 1024 px icons, pure white corners, the logo's colour unchanged, the
aspect ratio of the pasted logo equal to the source, and the whole logo inside the canvas.

### `tools/check-branding.py`

The no-Nextcloud gate (spec section 6). Exit 1 when a hit is not classified.

```bash
python3 tools/check-branding.py                    # sweep the source (CI gate)
python3 tools/check-branding.py --show-allowed     # also list the classified hits
python3 tools/check-branding.py --no-allowlist     # raw hit count (e.g. on the upstream tag)
python3 tools/check-branding.py --root ../wt/x     # sweep another checkout
python3 tools/check-branding.py --list-images      # list shipped images for the visual check
python3 tools/check-branding.py --app NoDrive.app  # sweep a built app (CI: report only for now)
python3 tools/check-branding.py --json hits.json   # write all hits as JSON
```

- **Where (source mode):** the folders of the app and its extensions (`Brand`, `iOSClient`, `Share`,
  `File Provider Extension[ UI]`, `Notification Service Extension`, `Widget`,
  `WidgetDashboardIntentHandler`, `Action Assistant`, `BackgroundUploadExtension`) for files the
  Xcode project uses, plus `project.pbxproj` values and the schemes. Repository docs such as this
  file are credit, not app screens, and are not swept.
- **What:** translations (UTF-16 decoded), `.stringsdict`, `.xcstrings`, storyboards, XIBs,
  plists, entitlements, intents, RTF, JSON, SVG; Swift and Objective-C string literals (comments
  skipped); file names; bundle ids; resources copied into each target (`AppIcon.icon`,
  `GoogleService-Info.plist`, `Nextcloud Hub.png` and `Reasons to use Nextcloud.pdf` must never come back).
- **Keywords:** `next cloud`/`nextcloud` (also every Nextcloud link and `com.nextcloud`),
  `owncloud`, `mirall`, `it.niedermann`, `twsweb`, `crypto-cloud`, the App Store ids of Nextcloud,
  Talk and Notes, `0082c9`, `00679e`, and the name in Arabic, Korean, Japanese, Russian and Hebrew script.
- **Colours:** anything within distance 32 of `#0082C9`, `#00679E` or `#49ABEA`, in hex and `rgb()`
  colours, asset-catalog colour sets, Swift colour literals, the colour operators inside PDFs, and
  the pixels of PNG/JPEG/GIF images (a hit when at least 1% of opaque pixels are such a blue).
- **Allowlist** (`tools/branding/allowlist.txt`): one entry per line,
  `<path glob> | <regex on the hit text> | <class> | <reason>`. Classes: `internal` (an identifier
  the server, the OS or a library needs; never shown), `legal` (copyright or licence notice),
  `artwork` (a generic image whose colour is close to a Nextcloud blue by chance; looked at).
  Regexes are anchored so that a user-visible text can never slip through.
- **App mode** (`--app`): reads every plist and compiled `.strings` of the built bundle, file and
  asset names, and the links inside the binaries. In CI it runs as a report
  (`continue-on-error`) until app-mode allowlist entries exist (to-do); round 2 of the sweep
  classified all its hits by hand.

### CI helpers (`tools/ci/`)

| File | Job | What it does |
|---|---|---|
| `simulated-entitlements.py` | build | Writes the app-group and keychain entitlements into the unsigned simulator binaries (as Xcode does for simulator builds), through an `-xcconfig` file |
| `inspect-products.py` | build | Checks ids, display names, URL scheme and entitlements of the built app and every extension; lists links to Nextcloud services |
| `screens.sh` | screens | Simulator steps: tool check, DNS capture, certificates for the stand-in, install, launch, language/appearance switch, UI walk |
| `drive-stand-in.py` | screens | A local stand-in for `drive.nourax.org` (status, Login Flow v2 start, a plain page); the real server is never contacted |
| `network-gate.py` | screens | Fails on any DNS query for a Nextcloud, ownCloud, Firebase or Crashlytics host; checks that sign-in opened `drive.nourax.org` and the user agent |
| `screens-report.py` | screens | Checks every screenshot for the Nourax cobalt, no Nextcloud blue and no "Nextcloud" text; makes the copies for `docs/screenshots/ios/` |
| `video-frames.swift` | screens | Takes frames from the launch recording |
| `workspace-check.py` | branding, screens | Reads the stand-in's request log: the app password only went to the account's own server on the app's own requests, the other host got no credential; `--debug-only` checks that the test account exists only in Debug builds |
| `server-app-login.sh`, `server_login_check.py` | server login | Starts a throwaway Nextcloud 35 in Docker and proves the web-view sign-in (session cookies from an app password, 304 on the apps list, log-out and revoke behaviour) |
