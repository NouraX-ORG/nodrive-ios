<!--
SPDX-FileCopyrightText: 2026 Nourax
SPDX-License-Identifier: GPL-3.0-or-later
-->
# NoDrive for iOS: testing

CI tests stop at "it builds, starts, and the screens before sign-in are correct". CI cannot sign in:
the Drive's login pages only open from the owner's home network, and CI must never touch the real
`drive.nourax.org` (a local stand-in answers for it). Everything after sign-in is an **owner test**
on the owner's Mac (simulator) or iPhone.

Workspace apps (feature `feature/workspace-apps`, then the fixes round `feature/workspace-apps-fixes`): run [40470638063](https://github.com/NouraX-ORG/nodrive-ios/actions/runs/40470638063), commit `5c6c9f8597`, all 4 jobs green
(Branding gate, Build and unit tests, Server login, Simulator screens). The merge to `main` adds only documents on top of
that commit; the same checks run again on the merge commit and on `main`. The first round ran as
[40399328940](https://github.com/NouraX-ORG/nodrive-ios/actions/runs/40399328940) (commit `0585f7e0f7`).

Problem reports (feature `feature/problem-reports`): run [40901561115](https://github.com/NouraX-ORG/nodrive-ios/actions/runs/40901561115) (attempt 2), commit
`1742115b08`, all 4 jobs green (Branding gate, Build and unit tests, Server login, Simulator screens). Attempt 1 failed
only in the Workspace sidebar UI test (known flakes, below) and passed on the re-run. The merge to `main` adds only
documents on top of that commit; the same checks run again on the merge commit and on `main`.

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
| Unit tests (upstream + NoDrive) | CI | pass | run [40470638063](https://github.com/NouraX-ORG/nodrive-ios/actions/runs/40470638063) (Workspace apps head): `Test run with 204 tests in 22 suites passed`; result `Passed`, 204/204, 0 failed, 0 skipped (the reference run below had 145 before the Workspace tests) |
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
| Workspace apps: the side menu lists the server's apps in server order (Dashboard, Mail, NoMail, Calendar, Talk, Contacts), without Files, Activity and Photos | CI | pass (stand-in) | run [40470638063](https://github.com/NouraX-ORG/nodrive-ios/actions/runs/40470638063), job "Simulator screens": `walk.jsonl` `sidebar-apps {"names": ["Dashboard","Mail","NoMail","Calendar","Talk","Contacts"]}`; the stand-in's list also contains Files, Activity and Photos; the UI test asserts none of the three is shown; unit test `hiddenApps` (checks `id` and `app`); screenshot `workspace-light/02-workspace-menu` |
| The Apps section fills in by itself after sign-in, without closing and reopening the menu | CI | pass (stand-in) | `walk.jsonl` `sidebar-open {"apps_listed_at_open": false}` then `sidebar-apps`, with no second open in between; `stand-in.jsonl`: the list was answered after the sidebar was open (the stand-in delays it by 6 s); 8 unit tests in "NoDrive Workspace menu" (late list, changed list, 404, other account, account switch, restored launch, sign-in again, joined reads, retries after 5, 20 and 60 s) |
| NoMail appears in the Apps menu and opens in a browser panel, not signed in to NoDrive | CI | pass (stand-in) | UI test1 step 5: the panel shows "NoMail stand-in" and the Workspace page stays behind it; `stand-in.jsonl` `foreign-nomail`: `has_authorization: false`, `cookie_names: []` (light and dark); unit tests `outsideEntries`, `otherOutsideEntry`, `unsafeOutsideEntries` (20 bad links dropped), `outsideEntryOpensThePanel`; screenshot `workspace-light/06-nomail-panel` |
| Tapping an app opens it inside NoDrive, already signed in, no sign-in page | CI | pass (stand-in) | `NoDriveWorkspaceUITests` passed 4/4 in light and 4/4 in dark (`ui-workspace-*-summary.json`): page text `signed-in:Mail`, the sign-in page never shown; the page request carried the session cookies and no `Authorization` header (`stand-in.jsonl`); screenshot `workspace-light/03-workspace-page` |
| The signed-in session is renewed by itself when it ends, and a second launch of the app is signed in again | CI | pass (stand-in) | UI test "Expire the session": `walk.jsonl` `session-renewed {"shown": true}`, no login page; `workspace-check.py` check (g) `sessions_expired: 2`, check (f) `app_launches: 10`, each page served with a session issued after its own launch; screenshots `11-session-renewed`, `12-second-launch-page` |
| The password goes only to the account's own server, only on the app's own requests | CI | pass | `workspace-check.json`: `ok: true`, `problems: []`; credentialed paths are all `/ocs/`, `/remote.php/`, `/index.php/avatar`; 10 requests reached the other host, none with a cookie or credential; `--scan-secret` finds the throwaway password nowhere |
| A link to another host leaves NoDrive's web view (system browser panel, no session): plain link, redirect to another host, `target=_blank`, `window.open` | CI | pass (stand-in) | UI test1 step 4 and test2; `stand-in.jsonl` `foreign-probe`, `foreign-redirect`, `foreign-blank`, `foreign-window-open`: all `has_authorization: false`, `cookie_names: []`; unit tests `newWindows` and the `createWebViewWith` decisions; screenshots `04-foreign-link-panel`, `10-*-panel` |
| A notification link that points to the account's own server opens inside NoDrive, signed in | CI | pass (stand-in) | UI test4 taps "Open mail" in the notification list: page `signed-in:Mail`, no Safari, Close returns to the list; unit test `notificationLinkOpensInApp`; screenshots `13-notifications`, `14-notification-page` |
| Removing the account closes every open Workspace screen, clears its web data and the saved apps list | CI | pass (unit) | unit tests `forgetClosesTheScreenAndClearsItsStore` (own non-persistent store, cookie gone, web view removed, no sign-in or load afterwards), `forgetClosesAllScreensOfTheAccountOnly`, `screensDoNotShareStores`, `forgetRemovesTheAppList`. No test runs the real "leave the main view" step yet (it is an owner row) |
| Origin rules (user info, look-alike hosts, http, other port, trailing dot, IDN, `javascript:`, `data:`, `file:` ...) and notification-link routes | CI | pass | unit suite "NoDrive Workspace origin rules" (part of `Test run with 204 tests in 22 suites passed`, run [40470638063](https://github.com/NouraX-ORG/nodrive-ios/actions/runs/40470638063)) |
| Apps list cache, ETag/304, retries, session hand-off, redirect refusal, cookie flags (Secure over https), web-data clearing on removal | CI | pass | unit suites "NoDrive Workspace apps", "... menu", "... session", "... web" (same 204 tests) |
| Web-view sign-in on a real Nextcloud server 35.0.2 (throwaway, in Docker): both app-password kinds | CI | pass | job "Server login", `report.md`: all checks passed (including `?nodrive=ws` accepted by server 35); cookies alone sign the page in, 304 on the apps list, a web log-out keeps the app signed in, revoking the app password ends the web session after 12 s |
| The test account used by the UI test cannot exist in a Release build | CI | pass | `workspace-check.py --debug-only` in the Branding gate; `NCUITestAccount.swift` is inside `#if DEBUG` |
| No Nextcloud text, link or colour in the Workspace screens or code | CI | pass | `check-branding.py`: 0 unclassified; screenshots of the Apps menu and the pages looked at: none; no new strings (names come from the server) |
| Problem reports: unit tests (scrubber, report zip, crash text, run marker, decisions, sender, one report per run) | CI | pass | run [40901561115](https://github.com/NouraX-ORG/nodrive-ios/actions/runs/40901561115), job "Build and unit tests": `unit-tests-summary.json` result `Passed`, `totalTestCount` 277, 0 failed, 0 skipped (204 before; the 73 new test functions are in `NoDriveProblemReportsTests`, among them `cutKeys`, `namesAreKept`, `diagnosticRightAfterActivation`, `crashWithWaitingReports`) |
| Problem reports: Settings → Advanced shows the switch (off) and "Report a problem" | CI | pass (stand-in) | UI test `testProblemReports` passed in light (472 s) and dark (493 s); screenshots `reports-light/01-advanced-section`, `reports-dark/01-advanced-section` |
| Problem reports: "What's included" lists the contents in plain words | CI | pass | screenshots `reports-*/02-whats-included` and the recorded screen text `02-whats-included.txt`; the 20 texts match the contract word for word (review) |
| Problem reports: "Report a problem" with the switch off sends a report; while the Drive has no `nourax-support` the app says "Saved in your NoDrive › Problem reports."; the next report says "Problem report sent" | CI | pass (stand-in) | `report-check.py`: kinds `[manual, manual, unclean-exit, crash]`, MKCOL `[201, 405, 405, 405]`, share posts `[true, false]` (one POST while no share exists, none after), UI `banner-saved/sent/auto/crash: true`; screenshots `03-saved`, `04-sent` |
| Problem reports: closing unexpectedly with the switch off asks once ("NoDrive closed unexpectedly. Send a problem report?"); "Not now" sends nothing | CI | pass (stand-in) | walk question `["Not now","Send"]`, no upload for that run; screenshot `05-closed-unexpectedly`; unit tests of the decision table and `diagnosticRightAfterActivation` (one report and at most one question even when MetricKit delivers during the launch) |
| Problem reports: with the switch on, an unclean exit and a crash are sent without a question | CI | pass (stand-in) | `reports-light/dark`: `unclean-exit` then `crash` uploaded, `banner-auto` and `banner-crash` true, `crash.txt` carries the exception name; screenshots `06-switch-on`, `07-sent-by-itself`, `08-crash-sent`. MetricKit delivery cannot be tested in the simulator (owner row) |
| Problem reports: size, name and share rules | CI | pass | `report-check: ok` (its self-test: good data passes, 15 kinds of bad data are caught): each zip at most 5,000,000 bytes, uploaded to `/Problem reports/<UTC time>_ios_<version>.zip` with `If-None-Match: *`, share `shareType 0`, `permissions 1`, `shareWith nourax-support`; unit tests: 412 gives a new name, 6 waiting reports keep the newest 5, no account keeps the report and sends it after the sign-in, one share round and one banner after a crash with older reports waiting |
| Problem reports: passwords, tokens, cookies, keys and e-mail addresses are removed; file and folder names are kept | CI | pass | scrubber unit tests (`cutKeys`, `namesAreKept` and the earlier fixtures); `report-check.py` finds no raw Bearer value in any zip and `--scan-secret` finds the throwaway app password in none; the independent review ran a harness with random fake secrets ([round3-ios-reports-review-3.md](../../plans/round3-ios-reports-review-3.md)) |
| Problem reports go only to the signed-in account's own server; nothing goes to Google | CI | pass | `network-gate`: `forbidden 0`; every report request in `stand-in.jsonl` is to `drive.nourax.org`; `disable_crash_service` is still `true` (branding unit test); `check-branding: 483 hits: 264 internal, 217 legal, 2 artwork, 0 unclassified` (no new "Nextcloud" text) |
| Problem reports on a real Nextcloud 35 server (throwaway, in Docker) | CI | pass | job "Server login", `server_reports_check.py`: MKCOL 201 then 405; PUT with `If-None-Match: *` 201, again 412 and the content unchanged; share to the missing `nourax-support`: HTTP 404 "Please specify a valid account to share with"; after `occ user:add` the same POST gives 200, `share_type` 0, `permissions` 1; the support user can read the zip but gets 403 on add, change and delete: "all problem-report server checks passed" |
| Problem reports never delete a file on the phone or on the Drive | CI | pass | review: the 7 `removeItem` calls are all inside the app's own `Application Support/NoDrive/ProblemReports/`; no WebDAV DELETE and no trash call in `iOSClient/ProblemReports` |
| Smart conflicts: the Auto upload screen has the row "If a file is already in NoDrive", default "Smart (recommended)"; its list has exactly the four choices with the contract's texts and Smart's summary "Skip it if it's the same size, otherwise keep both", and no "Ask me every time" | CI | pass (stand-in) | `NoDriveConflictSettingsUITests`, run [40696152657](https://github.com/NouraX-ORG/nodrive-ios/actions/runs/40696152657) (`only_round3`, an earlier way to run it alone, now `only_conflicts`; commit `855350f705`): 1 test, 0 failures, light and dark; `walk.jsonl` `row-default` label "If a file is already in NoDrive, Smart (recommended)"; screenshots `01-auto-upload-row`, `02-choices` |
| Each of the four choices can be selected, the row shows it, and the choice is kept after the app is closed and opened again | CI | pass (stand-in) | same run, `walk.jsonl` `chose` x4 and `kept-after-relaunch` ("… Keep both"); `03-keep-both`, `04-after-relaunch`, `05-smart-again` |
| The experimental PhotoKit background upload (it would replace same-name files) is gone from the Auto upload screen and cannot be switched on | CI | pass | UI test: no "Experimental" section, no "PhotoKit background upload extension" switch; unit suite "NoDrive background upload extension": `disable_background_upload_extension` is true, `canConfigureBackgroundUploadExtension` and `shouldUseBackgroundUploadExtension` are false |
| Smart conflicts decision: every choice against every state of the name (missing, same size, other size, folder, not clear): exact action; only "Keep the phone copy" ever uploads over a name that exists; the answer "not clear" is always "retry later" | CI | pass (unit) | suite "NoDrive conflict decision": 20 parameterised cases plus property tests; run [40687316684](https://github.com/NouraX-ORG/nodrive-ios/actions/runs/40687316684) (commit `855350f705`): all 250 unit tests passed, 0 failed |
| A Live Photo follows one decision for both parts: Smart (both the same size: both done; photo the same, video missing: only the video uploads; one part differs: both get the same new number; one part not clear: retry), Keep both, Keep the NoDrive copy (per part), Keep the phone copy | CI | pass (unit) | suites "NoDrive conflict decision" and "NoDrive conflict resolver" (renamed parts point at each other through `livePhotoFile`; a partner extracted earlier is found in the queue) |
| Numbering: `name.ext` -> `name 1.ext`, a trailing number counts on, a pair takes the first number free for both, queued names and folders are skipped, an unclear answer or 100 taken names mean "retry later" (never a taken name) | CI | pass (unit) | suite "NoDrive conflict naming" |
| The size the app reads: PROPFIND `getcontentlength` of a file (12345 bytes), a missing name (404), a folder (`d:collection`, size only in a 404 propstat), and a PUT of the same name with another size replaces it | CI | pass (real Nextcloud 35.0.2, throwaway) | job "Server login", `round3.md`: 15 checks passed; the unit-test fixtures have exactly the element paths of the real answers (drift check) |
| The answer parser (namespace aware, first response only) and the request body | CI | pass (unit) | suite "NoDrive conflict probe" |
| The probe maps the server answer: 404 is "missing"; 401, 403, 423, 500, 503, a timeout and "no session" are "not clear" (never a guess); the call is asked for the name's url with the account and the request body | CI | pass (unit) | suite "NoDrive conflict probe": `statusMapping`, `noSession`, `successMapping`, `askedWith` (the PROPFIND call is injected) |
| Two upload passes at the same time (foreground and background) never give one new name to two photos; the lock is let go after "retry later" | CI | pass (unit) | suite "NoDrive conflict resolver": `overlappingPasses` (a probe that pauses, two photos named `IMG_0001.JPG` whose Drive copy has another size: `IMG_0001 1.JPG` and `IMG_0001 2.JPG`), `lockIsReleased` |
| Two different photos with one name in the same folder (the library scan can queue both, and an upload in the background session is not on the Drive yet) never overwrite each other: with the Drive having neither, Smart and Keep both upload one as is and give the other the next number; Keep the NoDrive copy lets the second wait; Keep the phone copy still replaces, by the owner's choice; the same photo (same asset) never counts against itself | CI | pass (unit) | suites "NoDrive conflict decision" (`nameTakenByOtherPhoto`), "NoDrive conflict resolver" (`sameNameTwoAssetsSmartAndKeepBoth`, `sameNameOtherIsUploading`, `sameNameKeepNoDriveWaits`, `sameAssetIsNotTaken`, `sameNameKeepPhone`) and "NoDrive conflict database store" (`nameUploadingByOtherItem`); run [41017526380](https://github.com/NouraX-ORG/nodrive-ios/actions/runs/41017526380) (commit `fba37eeb52`) |
| Order of two photos with one name (review 3, S4 and S5): the resolver orders them by the names it has handed out for upload (the first one resolved takes the name; no `ocId` tie-break), so the two parts of a Live Photo always agree and two photos never wait for each other; a photo waits only for one that is already in flight, never for one still behind it in the queue; a name is free again when the row that held it leaves the queue (uploaded, failed or removed) | CI | pass (unit) | suite "NoDrive conflict resolver": `sameNameLivePhotosKeepNoDrive` (two Live Photos, photo and video `ocId` orders crossed: one pair uploads, the other waits, then is marked done once the first one is on the Drive), `sameNameLivePhotosSmart`, `waitingPhotoIsNotBlockedByRowBehindIt`, `staleClaimDoesNotBlock`; suite "NoDrive conflict database store": `activeOcIds`; run [41017526380](https://github.com/NouraX-ORG/nodrive-ios/actions/runs/41017526380) (commit `fba37eeb52`; the failed dark "Workspace apps menu" step was re-run once, unrelated flake, then green) |
| A Live Photo is renamed all or none: both extracted files are copied first; when a copy fails nothing is renamed, the first new copy is dropped and the pair retries later | CI | pass (unit) | `livePhotoCopyFails` (resolver) and `renamePairFails` (real store) |
| The real store (file copy, database update of `fileName`, `serverUrlFileName` and `livePhotoFile`, partner lookup, queue check by name, extracted size) | CI | pass (unit) | suite "NoDrive conflict database store" on the test app's database, with rows for a host that cannot exist (`nodrive-test.invalid`) and a temporary extracted file |
| The conflicts UI step fails when a test was skipped (no account in the environment) | CI | pass | `tools/ci/screens.sh conflicts` reads `skippedTests` from `ui-<variant>-summary.json` |
| A renamed upload also records the photo's original name once it succeeded (so the next library scan does not queue the photo again); a failed one records nothing; a second queue item of the same photo is marked done, not renamed again; a stale entry never hides a photo; the file survives a restart and is pruned after 90 days | CI | pass (unit) | suite "NoDrive conflict ledger" |
| The setting per account: default Smart, unknown value reads as Smart, kept per account and across instances; the texts are exactly the contract's | CI | pass (unit) | suite "NoDrive conflict policy" |
| No Nextcloud text in the new screens | CI | pass | UI test `assertNoUpstreamName` on the list and the Auto upload screen; `screens-report` for `conflicts-light` and `conflicts-dark`: no problem; `check-branding.py`: 0 unclassified |
| Auto upload with photos already on the Drive: the same photo is not uploaded again, a different photo with the same name is kept as `name 1.ext`, in the app (simulator or iPhone) | owner | pending | see the owner steps below; CI covers the decision logic, the size the app reads on a real server and the screen, not an upload from the simulator's Photos library |
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
| Workspace apps: the side menu shows an "Apps" section with the apps your Nourax account has (Mail, Calendar, Talk ...), with no "Files", no "Activity" and no "Photos" entry | owner | pending | iPhone or Mac simulator, signed in at home. Names and order come from the server |
| The Apps section fills in by itself a few seconds after you sign in, without closing and reopening the menu | owner | pending | sign in, open the menu at once, wait; also after removing the account and signing in again |
| NoMail appears in the Apps menu and opens in a browser panel, not signed in to NoDrive | owner | pending | tap NoMail: a Safari panel opens and you may be asked to sign in to NoMail there; close it and you are back in NoDrive |
| Tapping an app opens it inside NoDrive, already signed in, with no sign-in page at any point | owner | pending | try Mail, then Talk |
| Back: the back arrow goes back inside the page; the sidebar button returns to the files | owner | pending | |
| A link inside an app that points to another website opens in a separate browser panel, not inside the app page | owner | pending | e.g. a link in a mail |
| A notification link (a "view" button in the notification list) that points to drive.nourax.org opens inside NoDrive, already signed in | owner | pending | |
| Sign out (remove the account), then sign in again: any open app page closes at once; after signing in again an app opens signed in | owner | pending | after removal, no app page may show your data. Try it with an app page open, and once with an app opened from a notification |
| Problem reports: Settings → Advanced (side menu → Settings → Advanced, scroll down) shows the switch "Send problem reports to Nourax" turned off, and a "Report a problem" row | owner | pending | iPhone or Mac simulator, signed in |
| Report a problem: type a few words, tap "What's included" (read the list, go back), tap Send. A message appears at the top, and a file named like `2026-10-30_12-00-00_ios_35.2.1-nourax.1.zip` is in the "Problem reports" folder of your files | owner | pending | works with the switch off. Look in the NoDrive file list, then on drive.nourax.org |
| Until the Workspace session creates the account `nourax-support` the message reads "Saved in your NoDrive › Problem reports."; afterwards it reads "Problem report sent" and the folder is shared read-only with Nourax Support | owner | pending | check Sharing of the folder on drive.nourax.org. The report is never lost either way |
| Open the zip on your Mac: a note with an e-mail address shows `<email>`; no password, token or cookie is anywhere in `report.json`, `crash.txt` or `logs/` | owner | pending | file and folder names stay visible on purpose |
| With the switch off, make the app close on its own (stop it with the Stop button in Xcode while NoDrive is on screen, then start it again): NoDrive asks "NoDrive closed unexpectedly. Send a problem report?". "Not now" sends nothing; "Send" sends one report | owner | pending | swiping the app away in the app switcher is not a problem and asks nothing |
| With the switch on, the same unexpected close sends a report by itself and shows "Problem report sent", with no question | owner | pending | |
| iPhone only, optional: after a real crash the next start sends one report that contains the crash text (`crash.txt`) | owner | pending | Apple hands crash data only to a real device; the simulator cannot show it |
| If you already have a folder called "Problem reports" with your own files, NoDrive puts the report in it and shares the whole folder read-only with Nourax Support. Decide if that is acceptable | owner | pending | one answer for all three apps; see the to-do list |
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
- The screens job runs as five parallel shards (matrix in `.github/workflows/ios.yml`: smoke, walks, dark,
  workspace, reports), each on its own runner and simulator. The job "Simulator screens report" merges their
  artifacts, runs the network gate, the screenshot report and the docs copies over all of them, and uploads
  `nodrive-ios-screenshots` and `nodrive-ios-screens-results` as before. A new UI test group is a new matrix
  entry plus its steps (how-to at the top of the job in the workflow file).
- A fresh simulator is slow on its first app start, so `screens.sh prepare-first` ends with a warm-up (install, launch, wait, terminate; `switch` then reinstalls cleanly). The intro slide wait reads the cell position from one snapshot (`waitForSlide`), because the cell vanishes while the intro scrolls and a separate `exists` then `frame` failed the test on a busy Mac. The Debug-only test account hook (`NCUITestAccount`) waits for the intro screen itself before it signs in, so the scene start can not replace the main screen afterwards, and shows the main screen itself when the account creation did not (its `mainAppWindow` is nil while the scene is inactive); `conflicts` also writes `ui-<variant>-hook.log`.
- `tools/ci/network-gate.py` reads the DNS captures (all shards, joined) and fails on any Nextcloud,
  ownCloud, Firebase or Crashlytics name. `tools/ci/screens-report.py` checks every screenshot and
  makes the 1200 px copies below.

- Problem reports (`screens.sh reports`, UI test `NoDriveProblemReportsUITests`, light and dark): the app is launched
  signed in with `NODRIVE_UITEST_REPORTS=1` and the stand-in in "reports" mode. It answers the WebDAV and share
  routes like the real server (the first share answers "user does not exist", later ones 200) and saves each uploaded
  zip. `tools/ci/report-check.py` then reads the stand-in log and the zips (order of the kinds, headers, share
  fields, size, no secret). The simulator cannot deliver MetricKit data, so the crash is made with an uncaught
  exception (`NODRIVE_UITEST_REPORTS=raise`). These hooks exist only in Debug builds (`#if DEBUG`).
- Server check: `tools/ci/server_reports_check.py` runs in job "Server login" against a throwaway Nextcloud 35.

Known CI flakes (not caused by a feature; re-run the failed job): "Failed to determine hittability of NoDrive Icon"
(home-screen icon tap), and once in `NoDriveWorkspaceUITests.test1MenuSignedInPageAndForeignLink` the side menu read
"Scanned images" instead of "Contacts" after the scroll back to Mail. The screens job (before the split into shards) took
about 2 h; the longest shard (reports) takes about 40 min (limit 120 min); the runner pool may run fewer than five shards at once.

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

Workspace apps (fixes round), from the `nodrive-ios-screenshots` artifact of run [40470638063](https://github.com/NouraX-ORG/nodrive-ios/actions/runs/40470638063)
(commit `5c6c9f8597`, iPhone 17, iOS 27.0; the signed-in account and the Workspace pages are made by the
CI stand-in, `docs/screenshots/ios/workspace-{light,dark}/`, 1200 px copies). Looked at for Nextcloud's name,
logo, colours and links: none.

| Screen | light | dark |
|---|---|---|
| Side menu with the "Apps" section (no Files, Activity or Photos; NoMail with an envelope) | [02-workspace-menu](screenshots/ios/workspace-light/02-workspace-menu.png) | [02-workspace-menu](screenshots/ios/workspace-dark/02-workspace-menu.png) |
| Mail page inside NoDrive, signed in (`signed-in:Mail`, stand-in page) | [03-workspace-page](screenshots/ios/workspace-light/03-workspace-page.png) | [03-workspace-page](screenshots/ios/workspace-dark/03-workspace-page.png) |
| Link to another host: system browser panel | [04-foreign-link-panel](screenshots/ios/workspace-light/04-foreign-link-panel.png) | [04-foreign-link-panel](screenshots/ios/workspace-dark/04-foreign-link-panel.png) |
| Back in the app page after closing the panel | [05-after-panel](screenshots/ios/workspace-light/05-after-panel.png) | [05-after-panel](screenshots/ios/workspace-dark/05-after-panel.png) |
| NoMail: browser panel on another host, not signed in | [06-nomail-panel](screenshots/ios/workspace-light/06-nomail-panel.png) | [06-nomail-panel](screenshots/ios/workspace-dark/06-nomail-panel.png) |
| Session ended and renewed by itself | [11-session-renewed](screenshots/ios/workspace-light/11-session-renewed.png) | [11-session-renewed](screenshots/ios/workspace-dark/11-session-renewed.png) |
| Notification list | [13-notifications](screenshots/ios/workspace-light/13-notifications.png) | [13-notifications](screenshots/ios/workspace-dark/13-notifications.png) |
| Notification link opened inside NoDrive, signed in | [14-notification-page](screenshots/ios/workspace-light/14-notification-page.png) | [14-notification-page](screenshots/ios/workspace-dark/14-notification-page.png) |

Problem reports, from the `nodrive-ios-screenshots` artifact of run [40901561115](https://github.com/NouraX-ORG/nodrive-ios/actions/runs/40901561115) (attempt 2, commit
`1742115b08`, iPhone 17, iOS 27.0; the signed-in account is made by the CI stand-in,
`docs/screenshots/ios/reports-{light,dark}/`, 1200 px copies). Looked at for Nextcloud's name, logo, colours and
links: none.

| Screen | light | dark |
|---|---|---|
| Settings → Advanced with the switch (off) and "Report a problem" | [01-advanced-section](screenshots/ios/reports-light/01-advanced-section.png) | [01-advanced-section](screenshots/ios/reports-dark/01-advanced-section.png) |
| "What's included" | [02-whats-included](screenshots/ios/reports-light/02-whats-included.png) | [02-whats-included](screenshots/ios/reports-dark/02-whats-included.png) |
| "Saved in your NoDrive › Problem reports." | [03-saved](screenshots/ios/reports-light/03-saved.png) | [03-saved](screenshots/ios/reports-dark/03-saved.png) |
| "Problem report sent" | [04-sent](screenshots/ios/reports-light/04-sent.png) | [04-sent](screenshots/ios/reports-dark/04-sent.png) |
| The question after an unexpected close | [05-closed-unexpectedly](screenshots/ios/reports-light/05-closed-unexpectedly.png) | [05-closed-unexpectedly](screenshots/ios/reports-dark/05-closed-unexpectedly.png) |
| Switch turned on | [06-switch-on](screenshots/ios/reports-light/06-switch-on.png) | [06-switch-on](screenshots/ios/reports-dark/06-switch-on.png) |
| Report sent by itself after an unclean exit | [07-sent-by-itself](screenshots/ios/reports-light/07-sent-by-itself.png) | [07-sent-by-itself](screenshots/ios/reports-dark/07-sent-by-itself.png) |
| Report sent after a crash | [08-crash-sent](screenshots/ios/reports-light/08-crash-sent.png) | [08-crash-sent](screenshots/ios/reports-dark/08-crash-sent.png) |

Smart conflicts, from the `nodrive-ios-screenshots` artifact of run [40696152657](https://github.com/NouraX-ORG/nodrive-ios/actions/runs/40696152657)
(commit `855350f705`, iPhone 17, iOS 27.0; signed in by the CI stand-in, `docs/screenshots/ios/conflicts-{light,dark}/`,
1200 px copies). Looked at for Nextcloud's name, logo, colours and links: none.

| Screen | light | dark |
|---|---|---|
| Auto upload with the row "If a file is already in NoDrive" (Smart, the default) | [01-auto-upload-row](screenshots/ios/conflicts-light/01-auto-upload-row.png) | [01-auto-upload-row](screenshots/ios/conflicts-dark/01-auto-upload-row.png) |
| The four choices (Smart with its summary, checkmark on the chosen one) | [02-choices](screenshots/ios/conflicts-light/02-choices.png) | [02-choices](screenshots/ios/conflicts-dark/02-choices.png) |
| "Keep both" chosen | [03-keep-both](screenshots/ios/conflicts-light/03-keep-both.png) | [03-keep-both](screenshots/ios/conflicts-dark/03-keep-both.png) |
| After closing and opening the app: the choice is kept | [04-after-relaunch](screenshots/ios/conflicts-light/04-after-relaunch.png) | [04-after-relaunch](screenshots/ios/conflicts-dark/04-after-relaunch.png) |
| Smart chosen again | [05-smart-again](screenshots/ios/conflicts-light/05-smart-again.png) | [05-smart-again](screenshots/ios/conflicts-dark/05-smart-again.png) |

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
5. Workspace apps: open the side menu right after signing in and wait: the "Apps" section appears by itself
   (no Files, Activity or Photos). Tap an app (it must open inside NoDrive, signed in, with no sign-in page),
   go back, tap NoMail (a browser panel, not signed in to NoDrive), then remove the account while an app page
   is open (the page must close) and sign in again (the pages must be signed out).
6. Problem reports: side menu → Settings → Advanced. Check that the switch is off, tap "Report a problem", write a few
   words, look at "What's included", tap Send, then look for the zip in the "Problem reports" folder of your files.
   Stop the app with the Stop button in Xcode while it is on screen and start it again to see the question.
7. Smart conflicts (Auto upload). Auto upload only looks at photos it has not uploaded before: a photo that is in this
   install's upload history is skipped by name, and an edited photo keeps its name and date. So the test needs
   photos that this install has not seen yet:
   1. Before the first install (or on a second device that has no Auto upload), have some photos already on the
      Drive, and edit one of them on the phone (an edit changes its size, the name stays).
   2. Install NoDrive, open the side menu → Auto upload. The row "If a file is already in NoDrive" reads
      "Smart (recommended)". Turn on Auto upload with the existing photos included.
   3. Expect with Smart: photos of the same size upload nothing (no second copy, no question), the edited photo
      uploads as `name 1.jpg` and the Drive keeps `name.jpg` untouched.
   4. Try each of the other three choices the same way, with a small test album only (Auto upload lets you choose
      albums): with "the existing photos included" every photo of the chosen albums is affected. A reinstall resets
      the choice to Smart and the upload history to empty, so for every try: reinstall NoDrive, choose the setting
      first, then turn on Auto upload with the existing photos included. "Keep the phone copy" replaces the file on
      the Drive for every photo of the album (each replacement is a new version of the file; the old one stays in
      the file's versions); "Keep the NoDrive copy" uploads nothing for a name that is there; "Keep both" makes a
      numbered copy of every photo of the album that is already on the Drive, always under the next free number
      (after the Smart try `name 1.jpg` exists, so the edited photo becomes `name 2.jpg`).
   Existing installs move from the old silent skip to Smart when they update. Known limits (both apps, the owner
   decides later): after a reinstall, a photo that was renamed once is uploaded again under the next number, and a
   different photo whose name is already in this install's upload history (for example `IMG_0001` after the
   counter wraps, with original file names on) is skipped by the library scan before Smart sees it.
8. Go through the "owner" rows above, then read back the device name shown under
   Settings → Security on drive.nourax.org.

Building and the iPhone steps: [build.md](build.md).
