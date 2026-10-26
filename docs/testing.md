<!--
SPDX-FileCopyrightText: 2026 Nourax
SPDX-License-Identifier: GPL-3.0-or-later
-->
# NoDrive for iOS: testing

CI tests stop at "it builds, starts, and the screens before sign-in are correct". CI cannot sign in:
the Drive's login pages only open from the owner's home network, and CI must never touch the real
`drive.nourax.org` (a local stand-in answers for it). Everything after sign-in is an **owner test**
on the owner's Mac (simulator) or iPhone.

Workspace apps (feature `feature/workspace-apps`): run [40399328940](https://github.com/NouraX-ORG/nodrive-ios/actions/runs/40399328940), commit `0585f7e0f7`, all 4 jobs green
(Branding gate, Build and unit tests, Server login, Simulator screens); on `main` after the merge the same checks run again.

Reference run: **[40206804804](https://github.com/NouraX-ORG/nodrive-ios/actions/runs/40206804804)**
on `main` (commit `b03563c3c9`), all 3 jobs green. Xcode 27.1 (build 27A9275), runner image
`xcode-27-arm64`, iPhone 17 simulator with iOS 27.0, unsigned (`CODE_SIGNING_ALLOWED=NO`).

## Results

| Feature | Who | Result | Evidence |
|---|---|---|---|
| Source is fully rebranded (`rebrand.py --check`) | CI | pass | Branding gate: `rebrand: 318 files checked, 0 would change` |
| Icons come only from the Nourax logo (`make-icons.py --check`) | CI | pass | `make-icons: 12 outputs, 0 to change, 0 rule problems` |
| No unclassified Nextcloud name, link, id or colour in the source | CI | pass | `check-branding: 483 hits: 264 internal, 217 legal, 2 artwork, 0 unclassified` |
| App, 8 extensions and test bundles build for the simulator, unsigned | CI | pass | job "Build and unit tests", `xcodebuild build-for-testing … CODE_SIGNING_ALLOWED=NO` succeeded; 0 Thread Sanitizer objects |
| Bundle ids, display names, URL scheme, app group and keychain group of the built app and every extension | CI | pass | `tools/ci/inspect-products.py`: `org.nourax.nodrive` + 8 extension ids, display names NoDrive / NoDrive Assistant, scheme `nodrive`, `group.org.nourax.nodrive` in every entitlements section |
| Unit tests (upstream + NoDrive) | CI | pass | `Test run with 145 tests in 17 suites passed`; result `Passed`, 145/145, 0 failed, 0 skipped |
| NoDrive branding unit tests (name, ids and app group, URL schemes, fixed server, version `35.2.1-nourax.1`, user agent matches server 35, Nextcloud services off, privacy link hidden, cobalt colour) | CI | pass | Suite "NoDrive branding": 9 of 9 passed |
| Built app sweep (`check-branding.py --app`) | CI | report only | 833 hits, all classified by hand in [branding-sweep.md](branding-sweep.md); becoming a gate is a follow-up |
| Launches (install with `simctl`, start, keeps running) | CI | pass | job "Simulator screens", step "simctl install, launch and screenshots" |
| Shows NoDrive's name, icon and colours | CI | pass | screenshots below; `screens-report: ok` (cobalt `#2563EB` background, no Nextcloud blue, no "Nextcloud" in any screen text) |
| Server is fixed (no address field, no "Sign up", no "Host your own server", one "Log in") | CI | pass | `NoDriveScreenshotUITests`: 0 text fields on the intro and after "Log in"; sign-up and host buttons absent |
| Sign-in opens the browser at drive.nourax.org (Login Flow v2) | CI | pass (stand-in) | `network-gate`: 4 Login Flow v2 starts and 4 browser page loads at `https://drive.nourax.org/login/v2/flow/…` (one per language variant), user agent `Mozilla/5.0 (iOS) Nextcloud-iOS/35.2.1 NoDrive` |
| System prompts name NoDrive (notifications, photo library) | CI | pass | screenshots `00-prompt-1`, `00-prompt-2` in 4 variants |
| Share sheet shows "NoDrive"; the share extension opens | CI | pass | screenshots `06-share-sheet`, `07-share-extension` ("No account found" before sign-in) |
| Dark mode | CI | pass (before sign-in) | `en-dark/` screenshots |
| Second language (German) | CI | pass (before sign-in) | `de-light/` screenshots |
| Right-to-left language (Arabic) | CI | pass (before sign-in) | `ar-light/` screenshots. Arabic is not a shipped app language (same as upstream), so NoDrive's own texts are English while the system UI is Arabic |
| No calls to Nextcloud services | CI | pass | `network-gate: 565 DNS queries for 157 names; forbidden 0`, `network-gate: ok`; no DNS query by a NoDrive process |
| Launch screen (cobalt, Nourax logo) | CI | not captured | The recording showed black, then the intro; the storyboard colour and image are checked by `rebrand.py --check`. Owner: look at it on the Mac |
| Workspace apps: the side menu lists the server's apps (Dashboard, Mail, Calendar, Talk, Contacts), in server order, without Files | CI | pass (stand-in) | run [40399328940](https://github.com/NouraX-ORG/nodrive-ios/actions/runs/40399328940) (`feature/workspace-apps`, commit `0585f7e0f7`), job "Simulator screens": `walk.jsonl` `names: [Dashboard, Mail, Calendar, Talk, Contacts]`; screenshot `workspace-light/02-workspace-menu` |
| Tapping an app opens it inside NoDrive, already signed in, no sign-in page | CI | pass (stand-in) | `NoDriveWorkspaceUITests` passed 1/1 (light and dark): page text `signed-in:Mail`, the sign-in page never shown; the page request carried the 4 session cookies and no `Authorization` header (`stand-in.jsonl`); screenshot `workspace-light/03-workspace-page` |
| The password goes only to the account's own server, only on the app's own requests | CI | pass | `workspace-check.py`: `ok`, 0 problems; credentialed paths are all `/ocs/`, `/remote.php/`, `/index.php/avatar`; the other host got 2 requests, no cookie, no credential |
| A link to another host leaves NoDrive's web view (system browser panel, no session) | CI | pass (stand-in) | UI test: clicked foreign link opens the panel (`04-foreign-link-panel`); the panel's request carried no cookies |
| Origin rules (user info, look-alike hosts, http, other port, trailing dot, IDN, `javascript:`, `data:`, `file:` ...) and notification-link routes | CI | pass | unit suite "NoDrive Workspace origin rules" (part of `Test run with 173 tests in 21 suites passed`) |
| Apps list cache, ETag/304, session hand-off, redirect refusal, web-data clearing on removal | CI | pass | unit suites "NoDrive Workspace apps", "... session", "... web" (same 173 tests) |
| Web-view sign-in on a real Nextcloud server 35.0.2 (throwaway, in Docker): both app-password kinds | CI | pass | job "Server login", `report.md`: all checks passed; cookies alone sign the page in, 304 on the apps list, a web log-out keeps the app signed in, revoking the app password ends the web session after 12 s |
| The test account used by the UI test cannot exist in a Release build | CI | pass | `workspace-check.py --debug-only` in the Branding gate; `NCUITestAccount.swift` is inside `#if DEBUG` |
| Sign in with "Log in with Nourax" on the real drive.nourax.org | owner | pending | Mac simulator at home (WAF) |
| File list after sign-in | owner | pending | |
| Upload, download, rename, move, delete | owner | pending | |
| Public link with expiry date and password | owner | pending | |
| Offline file | owner | pending | |
| Automatic photo upload | owner | pending | simulator Photos has sample pictures |
| Files app: location "NoDrive" (File Provider) | owner | pending | |
| Share extension upload into NoDrive | owner | pending | |
| Widgets (Files, Dashboard, Toolbar) show NoDrive | owner | pending | |
| Upload-conflict dialog shows the cobalt folder and blue document icons | owner | pending | start the same upload twice |
| Settings: footer "NoDrive 35.2.1-nourax.1" and "Nourax Workspace <version>"; no privacy or source-code link | owner | pending | |
| Settings → Information → Acknowledgements: text only, no logos, no nextcloud.com links | owner | pending | |
| Sign out | owner | pending | |
| Workspace apps: the side menu shows an "Apps" section with the apps your Nourax account has (Mail, Calendar, Talk ...), no "Files" entry | owner | pending | iPhone or Mac simulator, signed in at home. Names and order come from the server |
| Tapping an app opens it inside NoDrive, already signed in, with no sign-in page at any point | owner | pending | try Mail, then Talk |
| Back: the back arrow goes back inside the page; the sidebar button returns to the files | owner | pending | |
| A link inside an app that points to another website opens in a separate browser panel, not inside the app page | owner | pending | e.g. a link in a mail |
| A notification link (a "view" button in the notification list) that points to drive.nourax.org opens inside NoDrive, already signed in | owner | pending | |
| Sign out (remove the account), then sign in again: the in-app pages are signed out too; after signing in again an app opens signed in | owner | pending | after removal, no app page may show your data |
| Dark mode and German after sign-in | owner | pending | |
| Device name under Settings → Security on drive.nourax.org | owner | pending | read it back for the Workspace session |
| Sync works away from home (mobile data), after one sign-in at home | owner | pending | iPhone only |
| Installs next to the real Nextcloud app (optional) | owner | pending | different ids, app group and URL scheme by design |

## How the CI screens are made

- `tools/ci/screens.sh` boots "iPhone 17" (iOS 27.0), sets a fixed status bar (9:41), language,
  locale and appearance, removes NoDrive between variants (fresh permission prompts), and runs the
  UI test `Tests/NextcloudUITests/NoDriveScreenshotUITests.swift` from the `.xctestrun` of the build job.
- The UI test taps through the first-start prompts, takes screenshots of both intro slides, taps
  "Log in", waits for the browser sheet at `drive.nourax.org`, then checks the home screen icon,
  the Photos share sheet and the share extension. It fails if a visible text or system prompt
  contains "Nextcloud".
- `drive.nourax.org` points to `127.0.0.1`/`::1` on the runner, where `tools/ci/drive-stand-in.py`
  answers `status.php` and the Login Flow v2 start with a plain page marked "CI stand-in". The
  simulator trusts a throw-away CI root only for this.
- `tools/ci/network-gate.py` reads a DNS capture of the whole run and fails on any Nextcloud,
  ownCloud, Firebase or Crashlytics name. `tools/ci/screens-report.py` checks every screenshot and
  makes the 1200 px copies below.

## Screenshot index (`docs/screenshots/ios/`)

From the `nodrive-ios-screenshots` artifact of run 40206804804, except
`simctl/01-first-start-optimization.png` (run 40180930594, commit `79868cb2c2`, same screens).
Every screenshot was looked at for Nextcloud's name, logo, colours and links: none.
Details: [screenshots/ios/README.md](screenshots/ios/README.md).

| Screen | en-light | en-dark | de-light | ar-light |
|---|---|---|---|---|
| Notification prompt | [00-prompt-1](screenshots/ios/en-light/00-prompt-1.png) | [00-prompt-1](screenshots/ios/en-dark/00-prompt-1.png) | [00-prompt-1](screenshots/ios/de-light/00-prompt-1.png) | [00-prompt-1](screenshots/ios/ar-light/00-prompt-1.png) |
| Photo-library prompt | [00-prompt-2](screenshots/ios/en-light/00-prompt-2.png) | [00-prompt-2](screenshots/ios/en-dark/00-prompt-2.png) | [00-prompt-2](screenshots/ios/de-light/00-prompt-2.png) | [00-prompt-2](screenshots/ios/ar-light/00-prompt-2.png) |
| Intro slide 1 (Nourax logo, "Log in") | [01-intro-slide-1](screenshots/ios/en-light/01-intro-slide-1.png) | [01-intro-slide-1](screenshots/ios/en-dark/01-intro-slide-1.png) | [01-intro-slide-1](screenshots/ios/de-light/01-intro-slide-1.png) | [01-intro-slide-1](screenshots/ios/ar-light/01-intro-slide-1.png) |
| Intro slide 2 | [02-intro-slide-2](screenshots/ios/en-light/02-intro-slide-2.png) | [02-intro-slide-2](screenshots/ios/en-dark/02-intro-slide-2.png) | [02-intro-slide-2](screenshots/ios/de-light/02-intro-slide-2.png) | [02-intro-slide-2](screenshots/ios/ar-light/02-intro-slide-2.png) |
| Sign-in browser at drive.nourax.org (stand-in) | [04-sign-in-browser](screenshots/ios/en-light/04-sign-in-browser.png) | [04-sign-in-browser](screenshots/ios/en-dark/04-sign-in-browser.png) | [04-sign-in-browser](screenshots/ios/de-light/04-sign-in-browser.png) | [04-sign-in-browser](screenshots/ios/ar-light/04-sign-in-browser.png) |
| Home screen with the NoDrive icon | [05-home-screen](screenshots/ios/en-light/05-home-screen.png) | [05-home-screen](screenshots/ios/en-dark/05-home-screen.png) | [05-home-screen](screenshots/ios/de-light/05-home-screen.png) | [05-home-screen](screenshots/ios/ar-light/05-home-screen.png) |
| Share sheet with NoDrive | [06-share-sheet](screenshots/ios/en-light/06-share-sheet.png) | [06-share-sheet](screenshots/ios/en-dark/06-share-sheet.png) | [06-share-sheet](screenshots/ios/de-light/06-share-sheet.png) | [06-share-sheet](screenshots/ios/ar-light/06-share-sheet.png) |
| NoDrive share extension (no account) | [07-share-extension](screenshots/ios/en-light/07-share-extension.png) | [07-share-extension](screenshots/ios/en-dark/07-share-extension.png) | [07-share-extension](screenshots/ios/de-light/07-share-extension.png) | [07-share-extension](screenshots/ios/ar-light/07-share-extension.png) |

`simctl/` (installed and started with `xcrun simctl`, no test runner):
[01-first-start-optimization](screenshots/ios/simctl/01-first-start-optimization.png),
[02-launch-8s](screenshots/ios/simctl/02-launch-8s.png),
[03-launch-later](screenshots/ios/simctl/03-launch-later.png).

Workspace apps (feature `feature/workspace-apps`), from the `nodrive-ios-screenshots` artifact of run [40399328940](https://github.com/NouraX-ORG/nodrive-ios/actions/runs/40399328940)
(commit `0585f7e0f7`, iPhone 17, iOS 27.0; the signed-in account and the Workspace pages are made by the
CI stand-in, `docs/screenshots/ios/workspace-{light,dark}/`, 1200 px copies). Looked at for Nextcloud's name,
logo, colours and links: none.

| Screen | light | dark |
|---|---|---|
| Side menu with the "Apps" section | [02-workspace-menu](screenshots/ios/workspace-light/02-workspace-menu.png) | [02-workspace-menu](screenshots/ios/workspace-dark/02-workspace-menu.png) |
| Mail page inside NoDrive, signed in (`signed-in:Mail`, stand-in page) | [03-workspace-page](screenshots/ios/workspace-light/03-workspace-page.png) | [03-workspace-page](screenshots/ios/workspace-dark/03-workspace-page.png) |
| Link to another host: system browser panel | [04-foreign-link-panel](screenshots/ios/workspace-light/04-foreign-link-panel.png) | [04-foreign-link-panel](screenshots/ios/workspace-dark/04-foreign-link-panel.png) |
| Back in the app page after closing the panel | [05-after-panel](screenshots/ios/workspace-light/05-after-panel.png) | [05-after-panel](screenshots/ios/workspace-dark/05-after-panel.png) |

Screens after sign-in (file list, settings, licence page, Files app, widgets) need an account and
are owner tests.

## Owner test steps (Mac)

1. Install Xcode 27.1 from the Mac App Store (macOS Tahoe 26.6 or newer), open it once and let it
   install the iOS 27 simulator.
2. Terminal: `git clone https://github.com/NouraX-ORG/nodrive-ios.git`, then open
   `nodrive-ios/Nextcloud.xcodeproj`. Wait for "Resolving Package Graph".
3. Toolbar: scheme **Nextcloud**, destination **iPhone 17**. Press Run (⌘R).
4. In the simulator: Log in → the browser opens at drive.nourax.org → "Log in with Nourax" →
   use your normal Nourax account (not the emergency admin account) → Grant access.
5. Workspace apps: open the side menu, tap an app under "Apps" (it must open inside NoDrive, signed in,
   with no sign-in page), go back, then remove the account and sign in again (the pages must be signed out).
6. Go through the "owner" rows above, then read back the device name shown under
   Settings → Security on drive.nourax.org.

Building and the iPhone steps: [build.md](build.md).
