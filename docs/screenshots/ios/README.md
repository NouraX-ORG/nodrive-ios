<!--
SPDX-FileCopyrightText: 2026 Nourax
SPDX-License-Identifier: GPL-3.0-or-later
-->
# NoDrive for iOS: screenshots before sign-in

Made by CI: job "Simulator screens" of `.github/workflows/ios.yml`, run
[40206804804](https://github.com/NouraX-ORG/nodrive-ios/actions/runs/40206804804) on `main` (commit `b03563c3c9`),
iPhone 17 simulator, iOS 27.0, Xcode 27.1, unsigned simulator build. Only
`simctl/01-first-start-optimization.png` is from the earlier run
[40180930594](https://github.com/NouraX-ORG/nodrive-ios/actions/runs/40180930594) (commit `79868cb2c2`, same screens). The full-size originals, the
accessibility texts of every screen and the walk log are in the run's artifacts
`nodrive-ios-screenshots` and `nodrive-ios-screens-results`. These copies are 1200 px high.

Every screenshot was looked at for the Nextcloud name, logo, colours and links: none found.
CI also checks this automatically (`tools/ci/screens-report.py`: Nourax cobalt background, no
Nextcloud blue, no "Nextcloud" in any recorded screen text).

| Folder | Phone language | Appearance |
|---|---|---|
| `en-light/` | English | light |
| `de-light/` | German | light |
| `ar-light/` | Arabic (right to left) | light |
| `en-dark/` | English | dark |
| `simctl/` | English | light; NoDrive installed and started with `xcrun simctl`, no test runner |

| File | Screen |
|---|---|
| `00-prompt-1.png`, `00-prompt-2.png` | The two system prompts NoDrive triggers at the first start (notifications, photo library). Both name "NoDrive". |
| `01-intro-slide-1.png`, `02-intro-slide-2.png` | Intro: Nourax logo, NoDrive texts, one "Log in" button. No server address field, no "Sign up", no "Host your own server". |
| `04-sign-in-browser.png` | After "Log in": the browser sheet opens at `drive.nourax.org` (Login Flow v2). See the note on the stand-in below. |
| `05-home-screen.png` | Home screen with the NoDrive icon and name. "NoDriveUITests-Runner" is the test runner, only there during the test. |
| `06-share-sheet.png` | Share sheet of the Photos app with NoDrive in the app row. |
| `07-share-extension.png` | The NoDrive share extension without an account ("No account found"). |
| `simctl/01-first-start-optimization.png` | First start after installing: "Optimization in progress …" (a frame from a screen recording). |
| `simctl/02-launch-8s.png` | 8 s after `simctl launch`, with the notification prompt. |
| `simctl/03-launch-later.png` | A few seconds later: the same prompt over the intro (NoDrive is still running). |

Workspace apps (`workspace-light/`, `workspace-dark/`): from run
[40470638063](https://github.com/NouraX-ORG/nodrive-ios/actions/runs/40470638063) on `feature/workspace-apps-fixes`
(commit `5c6c9f8597`), same device and settings. The account and the Workspace pages come from the CI stand-in.

| File | Screen |
|---|---|
| `02-workspace-menu.png` | Side menu with the "Apps" section: Dashboard, Mail, NoMail, Calendar, Talk, Contacts (no Files, Activity or Photos). |
| `03-workspace-page.png` | The Mail page open inside NoDrive, already signed in (page text `signed-in:Mail`). |
| `04-foreign-link-panel.png` | A link to another host opens in the system browser panel, not in the app page. |
| `05-after-panel.png` | Back in the app page after closing the panel. |
| `06-nomail-panel.png` | NoMail opens in the browser panel on another host, not signed in to NoDrive. |
| `11-session-renewed.png` | The Mail page after its session ended and was renewed by itself. |
| `13-notifications.png` | The notification list with a link to the account's own server. |
| `14-notification-page.png` | That link opened inside NoDrive, signed in. |

Problem reports (`reports-light/`, `reports-dark/`): from run
[40901561115](https://github.com/NouraX-ORG/nodrive-ios/actions/runs/40901561115) on `feature/problem-reports`
(commit `1742115b08`, attempt 2), same device and settings. The account and the server answers come from the CI stand-in.

| File | Screen |
|---|---|
| `01-advanced-section.png` | Settings → Advanced: the switch "Send problem reports to Nourax" (off) and "Report a problem". |
| `02-whats-included.png` | "What's included": the contents of a report in plain words. |
| `03-saved.png` | "Saved in your NoDrive › Problem reports." (the Drive has no `nourax-support` yet). |
| `04-sent.png` | "Problem report sent". |
| `05-closed-unexpectedly.png` | After an unclean exit with the switch off: "NoDrive closed unexpectedly. Send a problem report?" with Not now and Send. |
| `06-switch-on.png` | The switch turned on. |
| `07-sent-by-itself.png` | An unclean exit with the switch on: "Problem report sent", no question. |
| `08-crash-sent.png` | After a crash: "Problem report sent". |

Looked at for Nextcloud's name, logo, colours and links: none.

Notes:
- CI never contacts the real drive.nourax.org. In the screenshot job, drive.nourax.org points to a
  local stand-in (`tools/ci/drive-stand-in.py`) that answers Login Flow v2 and serves a plain page
  marked "CI stand-in". The real "Log in with Nourax" page is checked by the owner on a device.
- NoDrive ships the same languages as Nextcloud iOS 35.2.1. Arabic is not one of them (no
  right-to-left language is), so on an Arabic iPhone NoDrive's own texts are English while the
  system prompts, the share sheet and the browser are Arabic.
- The launch screen (`Brand/LaunchScreen.storyboard`: cobalt background, Nourax logo) did not show
  in the screen recordings: right after installing, the simulator showed black, then
  "Optimization in progress …" or the intro. Its colours and image are checked in the source by
  `tools/rebrand.py --check`; the owner sees it on the Mac.
- Screens after sign-in (file list, settings, about and licences, Files app location, widgets) need
  an account and are owner tests.
