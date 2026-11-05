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

Smart conflicts (feature `feature/smart-conflicts`, with the final fixes of review 1 to 3): run [41053798105](https://github.com/NouraX-ORG/nodrive-ios/actions/runs/41053798105),
commit `20ce353bbb` (the branch merged with `main` after Problem reports), all 10 jobs green (Branding gate, Build and unit tests,
Server login, the 6 Simulator screens shards, Simulator screens report); no re-run was needed. The code before the merge had
passed as run [41017526380](https://github.com/NouraX-ORG/nodrive-ios/actions/runs/41017526380) (commit `fba37eeb52`). `main` was moved to
`20ce353bbb` by a fast-forward, so the same checks ran again on `main`: run [41067448530](https://github.com/NouraX-ORG/nodrive-ios/actions/runs/41067448530), green after re-runs of the shard "smoke" (the known flake "Failed to determine hittability of NoDrive Icon") and of the shard "walks" (twice: the German walk did not find the first intro slide, a start-up timing flake that the branch `ci/settle-wait` works on; the code is the same as in the green run above). The documents on top of it are the only later change.

NoAgenda (feature `feature/noagenda-core`, with the final fixes of review 1 to 3 and the final review): run [41230680780](https://github.com/NouraX-ORG/nodrive-ios/actions/runs/41230680780),
commit `ce48f28a66` (already on top of `main`, so no merge was needed), all 12 jobs green on the first attempt (Branding gate, Build and
unit tests, NoAgenda server, Server login, the 7 Simulator screens shards, Simulator screens report). Earlier runs of the branch failed in
the shard `agenda` on a finder that lost the list (`41221832640`, fixed by `ce48f28a66`). The merge to `main` adds only documents on top of
that commit; the same checks run again on the merge commit and on `main`.

NoAgenda editing and conflicts (feature `feature/noagenda-edit`, with the fixes of review 1 and 2 and the approval of review 3): run [41393142152](https://github.com/NouraX-ORG/nodrive-ios/actions/runs/41393142152),
commit `ab1cda20d5` (already on top of `main` at `12f48e2e63`, so no merge was needed), all 16 jobs green (Branding gate, Build and unit tests,
NoAgenda server, NoAgenda replay, Server login, the 9 Simulator screens shards, Simulator screens report). Earlier runs of the branch failed on
finders and on test strings that later commits repaired (`41392069569`: a test text held a literal line break, fixed by `ab1cda20d5`). The
merge to `main` adds only documents on top of that commit; the same checks run again on the docs commit and on `main`.

NoAgenda Timeline round 2 (review fixes; the fully green run of the branch is [41579821599](https://github.com/NouraX-ORG/nodrive-ios/actions/runs/41579821599) on `e90ceb88b0`, all 17 jobs; the code commit is `067f488940`, the run [41562291822](https://github.com/NouraX-ORG/nodrive-ios/actions/runs/41562291822) of it was cancelled in the shard agenda and the report job after the rest had passed; an earlier run of `e28ef24c3c` failed in the two Timeline shards because an empty banner area took 140 points of the chart and the finder's drags missed the chart, fixed in `067f488940`; the last commit changes only documents, the screenshots and one screenshot call of the UI test). First round: NoAgenda Timeline (feature `feature/noagenda-timeline`): run [41497689323](https://github.com/NouraX-ORG/nodrive-ios/actions/runs/41497689323), commit `a0e2e25f07` (on top of `main` at `ead7f3d791`, so no merge was needed), all 18 jobs green (Branding gate, Build and unit tests, NoAgenda server, NoAgenda replay, Server login, the 11 Simulator screens shards, Simulator screens report). Earlier runs of the branch failed on a missing switch case (`41475201488`), on the seed check (NoGantt answers `EA` for a finish-to-start, `41475201488`), on two arithmetic expectations of the new unit tests, on the replay check that expected the old scenario count (`41487370522`), and in the screenshot the name column did not follow the scroll (fixed with `onScrollGeometryChange`, `f0548541a7`). The merge to `main` adds only documents on top of the code commit.

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
| Merged head of Smart conflicts and Problem reports: unit tests, the 2 UI tests of the Smart conflicts setting, the real-server checks, the network gate | CI | pass | run [41053798105](https://github.com/NouraX-ORG/nodrive-ios/actions/runs/41053798105) (commit `20ce353bbb`): unit tests result `Passed`, 346/346, 0 failed, 0 skipped; `ui-conflicts-light` and `ui-conflicts-dark` 1 test each, passed, 0 skipped (shard "conflicts", about 47 min); `round3.md`: 15 checks passed, "all round 3 server checks passed"; `network.json` ok, `forbidden_names` 0; `screens-report.json` `problems` empty; every shard wrote its `secret-scan-ok` file; `rebrand.py --check`: 336 files, 0 would change; `check-branding`: 484 hits, 0 unclassified |
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
| NoAgenda: unit tests (registry, iCalendar, CalDAV, NoGantt and Deck answers, rules of design 6.1, agents, integrity flags with their audience, team problems, dedupe, chips, All/Work/Personal, day plan, transport, store, offline cache, log) | CI | pass | run [41230680780](https://github.com/NouraX-ORG/nodrive-ios/actions/runs/41230680780): `Test run with 474 tests in 53 suites passed`; the 15 suites `NoDrive NoAgenda ...` passed (including the review-3 tests: unique problem keys, my stray agent said once, a refused project marked, card sentences like task sentences, problems hidden under Personal) |
| NoAgenda on a real Nextcloud 35.0.2 with Calendar 6.6.4, Tasks 0.18.1, Deck 1.19.1 and nc_gantt 2.4.1 (each from its pinned release, SHA-256 checked): the app password plus `OCS-APIRequest` is accepted by NoGantt, Deck, CalDAV and `cloud/user` | CI | pass (throwaway server) | job "NoAgenda server", `agenda-server.md`: 44 PASS, 0 FAIL; 412 without `OCS-APIRequest`; "reading changed no calendar object" |
| NoAgenda reads: the app's own request bodies and every NoGantt and Deck answer fit the 2.4.1 contract (a nullable key must be present); the seed of design section 12 is read back | CI | pass (throwaway server) | same job: `server_agenda_check.py` 0 FAIL; `seed.json` has the stray label card and the writer and design planning resources |
| NoAgenda screens in light and dark as three people (Ali, Mara, Olaf): the sidebar entry, the one-time question "Which of your calendars are personal?", Day, Week, Month, the detail sheet, Personal only, Sources, My team with the integrity problems, "Show all team tasks", "Not linked" | CI | pass (stand-in) | shard `agenda`: 9 UI runs `Passed` (ali, mara, olaf in light and dark, plus the 3 states), 27 screenshots, no `finder-failed-*.png`; stand-in log: only drive.nourax.org, every request with `OCS-APIRequest`, reads only |
| NoAgenda banners for NoGantt offline, NoBoard refused and Deck 1.20.0 (read only); saved rows stay | CI | pass (stand-in) | screenshots `agenda-state-offline-gantt`, `agenda-state-refuse-deck`, `agenda-state-deck-version-1.20.0` (light) |
| NoAgenda changes nothing on any server and deletes nothing | CI | pass | review: `NCAgendaMethod` has only GET, PROPFIND and REPORT; `agenda-check.py` finds no other method in the stand-in log; the cache is the app's own files and holds no secret |
| No Nextcloud text, logo or colour in the NoAgenda screens; the accent is cobalt | CI | pass | `check-branding.py`: `486 hits: 267 internal, 217 legal, 2 artwork, 0 unclassified`; `rebrand.py --check`: `344 files checked, 0 would change`; `screens-report` ok; screenshots looked at |
| NoAgenda editing: unit tests (iCalendar patch keeps what it does not know, CalDAV writer with `If-Match` and `If-None-Match: *`, NoGantt and Deck writers with the version check, edit queue with waiting, held, folded and Not sent states and undo, one Save with two changes, date-only to-dos, statuses, agent on a task, clashes and soft clashes, workload and free time, agents overbooked, days off and blocked, a description that was not read is never edited, delete checks again when sent, signed out holds the commands, read-only boards lock their cards) | CI | pass | run [41393142152](https://github.com/NouraX-ORG/nodrive-ios/actions/runs/41393142152), job "Build and unit tests": `"failedTests" : 0`, `"passedTests" : 629`; 27 suites `NoDrive NoAgenda ...` passed, among them "edit queue", "CalDAV writer", "NoGantt and Deck writers", "iCalendar patch", "edit draft", "clashes", "workload", "agent load", "waiting edits on the rows" |
| NoAgenda edit requests on a real Nextcloud 35.0.2 with nc_gantt 2.4.1 and Deck 1.19.1: the app's own request bytes (17 scenarios exported by the unit test) change what they should and nothing else (the unknown property, the alarm and the UID stay; an all-day event stays all-day; a date-only to-do stays a date; Gantt move with the follower task, undo, percent, status, agent to Self and back; Deck due date and agent label; a second create of the same name is refused with 412; the only DELETE is the event delete) | CI | pass (throwaway server) | job "NoAgenda replay", `agenda-replay.md`: 158 PASS, 0 FAIL; `agenda replay: 158 rows, 0 failed`; `ok the only DELETE of the job is the event delete - 1`; the stand-in answers like the real server (status and answer shape of every scenario) |
| NoAgenda editing in the simulator, light and dark (6 tests each): clashes marked on Day (two timed Self items of mine; a tentative one is soft; an agent item never clashes), the Conflicts chip, the workload bar of the day and of the week, change the agent of a Gantt task to Self and back, create an event with Self preselected, a task of a project I may only view is locked with its reason, a repeating event is locked with "Open in NoCalendar", tick a to-do done | CI | pass (stand-in) | shards `agenda-edit` and `agenda-edit-dark`: `edits: xcodebuild exit 0, passed tests 6 of 6` in each; 14 screenshots per colour mode (`agenda-edit-light/`, `agenda-edit-dark/`) |
| NoAgenda: another change somewhere else wins and is never overwritten (conflict, in two parts with an app restart between), and a change made without a connection waits, survives the restart and is sent afterwards (waiting, in two parts) | CI | pass (stand-in) | same shards: `conflict-a`, `conflict-b`, `waiting-a`, `waiting-b` each `passed tests 1 of 1`, light and dark; `agenda-edit-check.py`: `0 problem(s)` (the stand-in log shows the right method, `If-Match` and version checks on every write) |
| NoAgenda editing deletes only what the person deletes: no Gantt task or card is ever deleted; the only DELETE in the code is the event delete (calendar or to-do list), sent with `If-Match` after a fresh read, and refused for a series, an object with several components and an invitation | CI | pass | review 3: `git grep "\.delete"` in `iOSClient/NoAgendaEdit` and `iOSClient/NoAgenda` finds one DELETE (`NCAgendaCalDAVWriter.swift`); unit test `deleteRefuses` asserts that no DELETE request was sent; replay: `event-delete` 204 then 404 |
| NoAgenda editing sends only to the account's own server with its existing app password and creates no new credential; no new host, no new transport | CI | pass | review 3: no new `https://` in `iOSClient/`, no `URLSession` or `URLRequest(` in the new files (every write goes through `NCAgendaHTTP.makeRequest`: same origin, no redirects); a scan of the added lines for secrets finds none |
| No Nextcloud text in the NoAgenda editing screens; the accent is cobalt; the workload bar follows the accent | CI | pass | `check-branding.py`: `486 hits: 267 internal, 217 legal, 2 artwork, 0 unclassified`; `screens-report` ok (no Nextcloud blue on the agenda-edit screens); screenshots looked at |
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
| NoAgenda: side menu → Apps shows **NoAgenda** as the first entry; it opens a screen with Day, Week and Month | owner | pending | drive.nourax.org, your own account; the first time a question "Which of your calendars are personal?" appears once and does not come back |
| NoAgenda Day, Week and Month show your own events, to-dos, NoGantt tasks and NoBoard cards, each once, with its source colour and "🤖 Writer-Bot" or "👤 Self" | owner | pending | compare with NoCalendar, NoTasks, NoGantt and NoBoard on the web; a meeting that is in two calendars shows once |
| NoAgenda proves the app password is accepted by NoGantt and NoBoard on the real server | owner | pending | your NoGantt tasks show; if a banner says NoGantt or NoBoard did not accept NoDrive's sign-in, tell the Workspace session |
| NoAgenda: if you run a project or board, "My team" shows only problems (late, due today, blocked, not assigned, overbooked), and "Show all team tasks" shows the rest; under Personal the team part is empty | owner | pending | a project or board you manage |
| NoAgenda offline: switch on flight mode and open NoAgenda; the last data is there, marked with the time it was saved | owner | pending |  |
| NoAgenda Sources: set a calendar to Hidden and back to Personal; its events leave and come back in Day. Change an event in NoCalendar on the web: the row follows after you come back to the app | owner | pending |  |
| NoAgenda: open a row and tap "Open in NoCalendar" (or NoTasks, NoGantt, NoBoard): the signed-in page of that item opens | owner | pending | the real pages are not tested in CI |
| NoAgenda (reading only, step 1) changes nothing and deletes nothing | owner | superseded | the editing rows below replace this row: now the app changes only what you save and deletes only an event or to-do you delete |
| NoAgenda editing: open a to-do or an event of yours, tap Edit, change the title or the time, tap Save: the row changes at once, and the same change is there in NoCalendar or NoTasks on the web, with the rest of the item (reminders, notes, attendees) untouched | owner | pending | the real server, your own account |
| NoAgenda: tick a to-do as done in the app; it shows done in NoTasks on the web | owner | pending | |
| NoAgenda: tap + and make a new event in your Personal or Work calendar; it is in NoCalendar on the web, and your agents' calendars are not offered unless you pick an agent | owner | pending | |
| NoAgenda: delete an event you made yourself; it is gone from NoCalendar (it moves to the calendar's trash bin). An event you were invited to, and a repeating one, cannot be deleted from the app | owner | pending | only try it on a test event |
| NoAgenda: on a NoGantt task, change who does it (you or one of your agents) and the dates; NoGantt on the web shows the same, and Undo right after a date move puts the dates back | owner | pending | a project you manage, a test task |
| NoAgenda: on a NoBoard card, change the due date and who does it; NoBoard on the web shows the same | owner | pending | a board you may edit |
| NoAgenda: a task of a project you may only view, a card on a board you may only read, a repeating event and a meeting you were invited to are locked, with a short reason and the "Open in ..." button for the signed-in page | owner | pending | |
| NoAgenda Day: two events of yours at the same time show a red mark and the Conflicts chip lists only those; the bar at the top shows planned hours and free hours and turns orange when the day is too full; an agent's item never counts as a clash with yours | owner | pending | make two events at the same time to see it |
| NoAgenda: switch on flight mode, change an event, tap Save: the row says the change is waiting and the banner shows "Waiting to send"; switch the network back on: it is sent and the row is normal again. Close the app while a change waits and open it again: it is still waiting | owner | pending | |
| NoAgenda: change an event in the app while someone changes the same event on the web: the app does not overwrite the other change; the item shows under "Not sent" with "Apply my change again", "Keep the other change" and "Open in NoCalendar" | owner | pending | needs two devices, or the app and the web page |
| NoAgenda: an event or to-do whose description the app has not read yet shows "This description is not loaded yet" instead of an empty field; it fills after the next refresh | owner | pending | right after updating the app from the reading-only version |
| NoAgenda: after a change made in the app, edit the same item on the web: an agent's tag and id are still there (Calendar keeps both; Tasks keeps the tag and drops the id, see `docs/noagenda.md`) | owner | pending | the real Calendar and Tasks pages; the CI proof is the desktop and Android jobs |
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

## NoAgenda (step 1, read only)

See `docs/noagenda.md` for what is tested where. Screenshots (light and dark) are in
`docs/screenshots/ios/agenda-light/` and `docs/screenshots/ios/agenda-dark/` (1200 px copies from run
[41230680780](https://github.com/NouraX-ORG/nodrive-ios/actions/runs/41230680780), commit `ce48f28a66`, iPhone 17, iOS 27.0; the signed-in account and the answers are made by the CI stand-in
that replays the recorded answers of the real NoGantt, Deck and Calendar). Looked at for Nextcloud's name, logo,
colours and links: none; the accent is cobalt.

| Screen | light | dark |
|---|---|---|
| Side menu with NoAgenda as the first entry of Apps | [agenda-sidebar](screenshots/ios/agenda-light/agenda-sidebar.png) | [agenda-sidebar](screenshots/ios/agenda-dark/agenda-sidebar.png) |
| The one-time question "Which of your calendars are personal?" | [agenda-personal-question](screenshots/ios/agenda-light/agenda-personal-question.png) | [agenda-personal-question](screenshots/ios/agenda-dark/agenda-personal-question.png) |
| Day | [agenda-day](screenshots/ios/agenda-light/agenda-day.png) | [agenda-day](screenshots/ios/agenda-dark/agenda-day.png) |
| Week | [agenda-week](screenshots/ios/agenda-light/agenda-week.png) | [agenda-week](screenshots/ios/agenda-dark/agenda-week.png) |
| Month | [agenda-month](screenshots/ios/agenda-light/agenda-month.png) | [agenda-month](screenshots/ios/agenda-dark/agenda-month.png) |
| A row opened (detail, read only) | [agenda-detail](screenshots/ios/agenda-light/agenda-detail.png) | [agenda-detail](screenshots/ios/agenda-dark/agenda-detail.png) |
| Personal only | [agenda-personal-only](screenshots/ios/agenda-light/agenda-personal-only.png) | [agenda-personal-only](screenshots/ios/agenda-dark/agenda-personal-only.png) |
| Sources | [agenda-sources](screenshots/ios/agenda-light/agenda-sources.png) | [agenda-sources](screenshots/ios/agenda-dark/agenda-sources.png) |
| My team as manager (problems only) | [agenda-team](screenshots/ios/agenda-light/agenda-team.png) | [agenda-team](screenshots/ios/agenda-dark/agenda-team.png) |
| "Show all team tasks" | [agenda-team-all](screenshots/ios/agenda-light/agenda-team-all.png) | [agenda-team-all](screenshots/ios/agenda-dark/agenda-team-all.png) |
| A person not linked to an account | [agenda-not-linked](screenshots/ios/agenda-light/agenda-not-linked.png) | [agenda-not-linked](screenshots/ios/agenda-dark/agenda-not-linked.png) |
| NoGantt offline, saved rows stay (light only) | [agenda-state-offline-gantt](screenshots/ios/agenda-light/agenda-state-offline-gantt.png) |  |
| NoBoard refused, banner with "Open in NoBoard" (light only) | [agenda-state-refuse-deck](screenshots/ios/agenda-light/agenda-state-refuse-deck.png) |  |
| Deck 1.20.0, read only (light only) | [agenda-state-deck-version-1.20.0](screenshots/ios/agenda-light/agenda-state-deck-version-1.20.0.png) |  |

NoAgenda editing (step 2): screenshots (light and dark) are in `docs/screenshots/ios/agenda-edit-light/` and
`docs/screenshots/ios/agenda-edit-dark/` (1200 px copies from run [41393142152](https://github.com/NouraX-ORG/nodrive-ios/actions/runs/41393142152), commit `ab1cda20d5`; the tests
`NoDriveAgendaEditUITests`).

| Screen | Light | Dark |
|---|---|---|
| Day with clashes marked and the workload bar | [agenda-day-conflicts](screenshots/ios/agenda-edit-light/agenda-day-conflicts.png) | [agenda-day-conflicts](screenshots/ios/agenda-edit-dark/agenda-day-conflicts.png) |
| The Conflicts chip | [agenda-conflicts-chip](screenshots/ios/agenda-edit-light/agenda-conflicts-chip.png) | [agenda-conflicts-chip](screenshots/ios/agenda-edit-dark/agenda-conflicts-chip.png) |
| Week with the workload bar per day | [agenda-week-workload](screenshots/ios/agenda-edit-light/agenda-week-workload.png) | [agenda-week-workload](screenshots/ios/agenda-edit-dark/agenda-week-workload.png) |
| Editing the agent of a Gantt task (the picker) | [agenda-edit-agent](screenshots/ios/agenda-edit-light/agenda-edit-agent.png) | [agenda-edit-agent](screenshots/ios/agenda-edit-dark/agenda-edit-agent.png) |
| After Save, the task is done by the agent again | [agenda-edit-agent-saved](screenshots/ios/agenda-edit-light/agenda-edit-agent-saved.png) | [agenda-edit-agent-saved](screenshots/ios/agenda-edit-dark/agenda-edit-agent-saved.png) |
| New event (Self preselected) | [agenda-create](screenshots/ios/agenda-edit-light/agenda-create.png) | [agenda-create](screenshots/ios/agenda-edit-dark/agenda-create.png) |
| The new event in the Day list | [agenda-created](screenshots/ios/agenda-edit-light/agenda-created.png) | [agenda-created](screenshots/ios/agenda-edit-dark/agenda-created.png) |
| A task of a project I may only view (locked, with the reason) | [agenda-locked](screenshots/ios/agenda-edit-light/agenda-locked.png) | [agenda-locked](screenshots/ios/agenda-edit-dark/agenda-locked.png) |
| A repeating event (locked, "Open in NoCalendar") | [agenda-repeating](screenshots/ios/agenda-edit-light/agenda-repeating.png) | [agenda-repeating](screenshots/ios/agenda-edit-dark/agenda-repeating.png) |
| A to-do ticked done | [agenda-todo-done](screenshots/ios/agenda-edit-light/agenda-todo-done.png) | [agenda-todo-done](screenshots/ios/agenda-edit-dark/agenda-todo-done.png) |
| A change waiting for the connection | [agenda-waiting](screenshots/ios/agenda-edit-light/agenda-waiting.png) | [agenda-waiting](screenshots/ios/agenda-edit-dark/agenda-waiting.png) |
| The change sent after the connection came back | [agenda-sent-after-waiting](screenshots/ios/agenda-edit-light/agenda-sent-after-waiting.png) | [agenda-sent-after-waiting](screenshots/ios/agenda-edit-dark/agenda-sent-after-waiting.png) |
| Not sent: the other change was kept | [agenda-not-sent](screenshots/ios/agenda-edit-light/agenda-not-sent.png) | [agenda-not-sent](screenshots/ios/agenda-edit-dark/agenda-not-sent.png) |
| "Apply my change again" done | [agenda-applied-again](screenshots/ios/agenda-edit-light/agenda-applied-again.png) | [agenda-applied-again](screenshots/ios/agenda-edit-dark/agenda-applied-again.png) |

The tests check: Day (the meeting in two calendars once, the task once, the agent-without-person problem, no tasks of
other people), Sources (the hidden board calendar with its reason, the project and board defaults), the team problems
as manager (not assigned, not linked, not shared, "belongs to X, not Y") and the switch "Show all team tasks"
(scrolled to), and the three states of the homes. The shard `agenda` was flaky in earlier runs (the Browse tab showed
the Files root while a finder looked for the list); the finders now scroll by a drag on the screen and save
`finder-failed-<text>.png` when they give up. Watch it when a run of `main` turns red.

## NoAgenda Timeline (step 3)

See `docs/noagenda.md` ("Timeline"). Screenshots in `docs/screenshots/ios/agenda-timeline-light/` and `agenda-timeline-dark/` (1200 px copies from run
[41579821599](https://github.com/NouraX-ORG/nodrive-ios/actions/runs/41579821599), commit `e90ceb88b0` (the light copy of "moved" was refreshed from it; an earlier frame showed the move before NoGantt answered), iPhone 17, iOS 27.0, Ali against the CI stand-in that replays the real server's answers). Looked at for
Nextcloud's name, logo, colours and links: none; the accent is cobalt.

| Screen | light | dark |
|---|---|---|
| Lower rows of the Timeline, scrolled to the end and clear of the tab bar: phase "Copy", the 40 % bar (filled part) done by Writer-Bot with its arrow, the dashed to-do bar with the day-off mark, the NoBoard diamonds, shaded today | [agenda-timeline](screenshots/ios/agenda-timeline-light/agenda-timeline.png) | [agenda-timeline](screenshots/ios/agenda-timeline-dark/agenda-timeline.png) |
| Top of the Timeline: project, bars with the agent after them, arrow, shaded today | [agenda-timeline-top](screenshots/ios/agenda-timeline-light/agenda-timeline-top.png) | [agenda-timeline-top](screenshots/ios/agenda-timeline-dark/agenda-timeline-top.png) |
| A stub tapped: "After: Publish banners (Sara)" | [agenda-timeline-stub](screenshots/ios/agenda-timeline-light/agenda-timeline-stub.png) | [agenda-timeline-stub](screenshots/ios/agenda-timeline-dark/agenda-timeline-stub.png) |
| Days zoom | [agenda-timeline-days](screenshots/ios/agenda-timeline-light/agenda-timeline-days.png) | [agenda-timeline-days](screenshots/ios/agenda-timeline-dark/agenda-timeline-days.png) |
| Legend | [agenda-timeline-legend](screenshots/ios/agenda-timeline-light/agenda-timeline-legend.png) | [agenda-timeline-legend](screenshots/ios/agenda-timeline-dark/agenda-timeline-legend.png) |
| Locked task (viewer project) with its reason | [agenda-timeline-locked](screenshots/ios/agenda-timeline-light/agenda-timeline-locked.png) | [agenda-timeline-locked](screenshots/ios/agenda-timeline-dark/agenda-timeline-locked.png) |
| Editor with the two dates and Move by | [agenda-timeline-move-by](screenshots/ios/agenda-timeline-light/agenda-timeline-move-by.png) | [agenda-timeline-move-by](screenshots/ios/agenda-timeline-dark/agenda-timeline-move-by.png) |
| A move saved (toast "Moved to ...") | [agenda-timeline-moved](screenshots/ios/agenda-timeline-light/agenda-timeline-moved.png) | [agenda-timeline-moved](screenshots/ios/agenda-timeline-dark/agenda-timeline-moved.png) |

| Feature | Who | Result | Evidence |
|---|---|---|---|
| Timeline unit tests: date and x at both zooms, range, group and row order, what is drawn, shapes, the four arrow types with lags and routes, stubs, shading shares, hatch days, Move by (same command as the sheet, summer time, to-do, locked), spoken labels, strings and symbols, the person on a predecessor | CI | pass | run 41579821599, job "Build and unit tests": 7 suites `NoDrive NoAgenda Timeline ...` passed, `failedTests` 0 |
| Timeline in the simulator, light and dark (6 tests each): groups and phase, the 40 % bar done by Writer-Bot, the arrow, the stub with its text, milestone, dated card and to-do bar, a to-do without a start is not drawn; Days zoom; a viewer task is locked with its reason and the Team chip is dimmed; legend and range arrows; the editor with Move by -7, -1, +1, +7; a move saved with the "Moved to" toast | CI | pass (stand-in) | run 41579821599, shards `agenda-timeline`, `agenda-timeline-dark`: `timeline: xcodebuild exit 0, passed tests 6 of 6`; 9 screenshots per colour mode (the test scrolls to the lower rows and checks that the last row is clear of the tab bar) |
| The Timeline move asks NoGantt to move the followers (`adjust_lag`) and writes nothing else | CI | pass | run 41579821599, `agenda-edit-check.py --timeline`: `0 problem(s)` on the stand-in log (a NoGantt `PUT` with `moves_dates` and `adjust_lag`) |
| A Timeline move (+7 days) and its Undo on a real Nextcloud 35.0.2 with nc_gantt 2.4.1: start a week later, the end a week later or the working day before, the dependent task moved, Undo puts all back | CI | pass (throwaway server) | run 41579821599, job "NoAgenda replay": `timeline-move`, `timeline-undo` rows PASS; the stand-in answers like the real server |
| The seed has the Timeline data on the real server: "Review banners" follows two tasks, a task in a phase, a dated milestone, a to-do with start and due | CI | pass (throwaway server) | job "NoAgenda server", `agenda-server.md`: the four `timeline seed` rows PASS |
| No Nextcloud text in the Timeline screens; the accent is cobalt | CI | pass | run 41579821599, `check-branding.py` 0 unclassified; `screens-report` ok, network gate forbidden 0; screenshots looked at |
| Timeline on the real account: side menu, NoAgenda, Timeline: your tasks as bars under their project and phase with the % filled, to-dos with two dates, milestones and dated cards as diamonds, an arrow where one task follows another, your busy time shaded | owner | pending | drive.nourax.org, your own account; compare with NoGantt on the web |
| Timeline: tap a task, Edit, Move by +1 day, Save: NoGantt on the web shows the new dates and the tasks that follow moved; Undo in the toast puts them back | owner | pending | a project you manage, a test task |

## Device calendar and contacts sync (step 4)

See `docs/noagenda.md` ("Device calendar and contacts sync"). Screenshots in `docs/screenshots/ios/devicesync-light/` and `devicesync-dark/` (1200 px copies from run
[41883507135](https://github.com/NouraX-ORG/nodrive-ios/actions/runs/41883507135), iPhone 17, iOS 27.0, the app against the CI stand-in that plays Login Flow v2). Looked at for Nextcloud's name, logo, colours and links: none.
Final head `a22f4c68da`: all 18 jobs green on attempt 1 in run [41969655176](https://github.com/NouraX-ORG/nodrive-ios/actions/runs/41969655176), and the independent final review approved it (no blocking and no should-fix finding). Round 3 (review of round 2): the removal of a password that arrives after Cancel now runs in a task of its own (a cancelled task cannot send the DELETE), and Cancel in the waiting state polls once more. The app code of the head is the code of round 3 (`0ca32a61a0`); the commits after it changed only a test and the docs. Mutation check: commit `82b05428d3` ("MUTATION CHECK (reverted next)") puts `await discard(granted)` back in place of the fresh task and is broken on purpose; its unit job failed in run 41966755745 (`cancelDuringPoll`: "the password that arrived after Cancel was not removed", no DELETE sent), and `a22f4c68da` reverts it exactly. So that test guards the fix. The commit stays in the history of main. Round 2 code commit `aac0632825`: all 18 jobs green in run 41883507135 (the screenshots are from it). The device-sync shard of the same run needed re-runs of runner trouble ("The job was not acquired by Runner of type hosted"), and the walks shard once of a transient intro-slide colour sample; none of that touches this code. Earlier runs of the branch failed on test details that later commits repaired, and in
run 41716741376 on a flake of the account injection (the intro stayed on screen for 300 s in 6 shards, device-sync among them); the UI tests now relaunch once, see "Choices and status" in `docs/noagenda.md`.

| Check | Who | Result | Evidence |
|---|---|---|---|
| Device sync unit tests: the profile (Apple's keys, principal URL, stable identifier, new UUIDs, no upstream name, https only, redacted copy), the loopback server (127.0.0.1 only, random path, served once, closes), the sign-in with a fake transport (user agent, other origin stops, mismatching server refused and revoked, timeout, DELETE with the new password), the flow steps, secrecy (the password is in the served bytes only), the removal message, the texts | CI | pass | run [41969655176](https://github.com/NouraX-ORG/nodrive-ios/actions/runs/41969655176) (head `a22f4c68da`), job "Build and unit tests", `failedTests` 0: the 7 suites `NoDrive device sync ...` passed, now also: the owner question (GET cloud/user), a removal counts only on HTTP 200 with OCS 100/200, a grant for another user or an unknown owner (DELETE, no profile, no Safari), "It didn't work" with 401 / no answer / an OCS error (could not be removed, the password kept, Try again), Cancel while the poll answer or the loopback server is in flight, Cancel while a successful poll is on its way (exactly one DELETE), Cancel while waiting (one more poll, the password allowed in the last seconds is removed) |
| Login Flow v2 for the profile on a real Nextcloud 35.0.2: a separate app password named "NoDrive Calendar & Contacts (iPhone)", it does CalDAV, CardDAV and principals PROPFIND (207), its revocation by DELETE works (200) and the same requests are then 401, the token is gone | CI | pass (throwaway server) | job "NoAgenda server", `devicesync.md`: every check PASS |
| The server's own Apple profile is not usable: no `CalDAVPassword`/`CardDAVPassword`, and it names the server's theme ("Nextcloud"), so the app builds its own and switches the upstream entry off (`disable_mobileconfig`) | CI | pass (recorded) | same file, check 7 |
| Add to iPhone Calendar & Contacts in the simulator, light and dark (3 tests each): the section and its footer, step 1, the waiting step, the hand-over to Safari, the install steps, Installed and the done text; "It didn't work" revokes the password (the stand-in sees the DELETE); removing the account shows how to remove the profile | CI | pass (stand-in) | shard `device-sync`: `passed tests 3` in light and in dark; `devicesync-check.py` ok: 4 grants, 4 identity checks, 2 revocations, only drive.nourax.org, the grant only after the page was opened, 2 payloads in each redacted profile (`<redacted>` passwords), no throwaway password in any screenshot, log or result |
| Safari fetches the profile from the loopback server: `GET`, 200, 2584 bytes, in both variants and both sign-ins; `devicesync-check.py --require-safari-fetch` fails a variant without it | CI | pass | `devicesync-server.jsonl` (method, status and byte count only) and the check output in the shard, runs 41883507135 and [41969655176](https://github.com/NouraX-ORG/nodrive-ios/actions/runs/41969655176) |
| Apple's own screens in the simulator: Safari's "trying to download a configuration profile" dialog, Allow, Settings "Profile Downloaded", the install screen naming "NoDrive Calendar & Contacts" (Not Signed), Install and its "not signed" warning; the test stops there | CI | PASS in both variants | `apple-screens.json`; screenshots `devicesync-11` to `-14` (`-10` and `-15` were repeats or a black frame and are dropped; the UI test now waits for Safari to draw before `-10` and takes `-15` only when the prompt is missing). The install itself and the sync are owner rows |
| No Nextcloud text in the device-sync screens; the accent is the app's | CI | pass | `check-branding.py` 0 unclassified; `screens-report` ok |
| Identity check on a real Nextcloud 35.0.2: the new password names the account (`GET ocs/v2.php/cloud/user` answers Ali) and its DELETE answers OCS 100/200 | CI | pass (throwaway server) | job "NoAgenda server", `devicesync.md` rows 4b and 6 |
| Install the profile on a real iPhone: Settings, NoDrive, Calendar and contacts, Add to iPhone Calendar & Contacts, Continue, allow in the sign-in sheet, allow the download in Safari, Settings, Profile Downloaded, Install; then events, reminders (to-do lists) and contacts of your account show in Calendar, Reminders and Contacts, both ways | owner | pending | real iPhone (the simulator cannot install a profile) |
| The new password is listed as "NoDrive Calendar & Contacts (iPhone)" under Security on drive.nourax.org; remove the NoDrive account in the app: the message names the steps to remove the profile (Settings, General, VPN & Device Management) | owner | pending | real iPhone and the web security settings |
| An alarm fires: make an event in NoAgenda or NoCalendar with an alarm a few minutes ahead, wait for it on the iPhone | owner | pending | real iPhone, after the install; Apple's Calendar app plays the alarm (plan 5.7 row 4) |
| Design 4.2, the agent survives the iPhone: set an agent on an event in NoAgenda, change the event's title in the iPhone Calendar app, open the event in NoAgenda again. The agent is still shown. If it is gone but the event still carries the agent's tag (the `CATEGORIES` value), write that down: Apple's client dropped `X-NOURAX-AGENT-ID` and the tag is the fallback. If both are gone, tell the NoAgenda session (that would be a loss of data) | owner | pending | real iPhone, a test event; the answer decides plan risk E4 / S6 ("iPhone Calendar may drop `X-NOURAX-AGENT-ID`") |
| Wrong user: in the sign-in sheet allow access as another NoDrive user than the one signed in to the app: NoDrive says "You allowed access as another user...", no profile is offered, and the other user's Security list does not keep a "NoDrive Calendar & Contacts (iPhone)" entry | owner | pending | needs a second account; the CI proof is the unit tests and the stand-in |
| "It didn't work" with flight mode on (after Safari opened): it says "The separate password could not be removed" and names it; switch flight mode off, Try again: "The separate password was removed", and the entry is gone from Security on the web | owner | pending | real iPhone |
| Apple's Calendar app lists NoGantt's one-way task-copy calendar (if NoGantt's copy is on) and Deck's board calendars; edit one there and watch it be overwritten. Suggestion: switch NoGantt's copy off in NoGantt's settings. Each run of the flow makes a new password, and a reinstall replaces the profile but leaves the older password valid: remove old entries named "NoDrive Calendar & Contacts (iPhone)" under Security on the web | owner | pending | explains what you may see after the install; nothing is deleted by NoDrive |

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
8. NoAgenda (on drive.nourax.org, with your own account): side menu → Apps → **NoAgenda** (first entry). Expect:
   1. The question "Which of your calendars are personal?" once; after Done it does not come back.
   2. Day shows your events and to-dos; an event with a Writer-Bot tag shows "🤖 Writer-Bot"; an invitation shows
      "👤 Self" and no declined invitation. Week and Month show the same rows.
   3. NoGantt tasks assigned to you show with their project; "NoAgenda shows NoGantt tasks" proves the app password
      is accepted by NoGantt on the real server. If a banner says NoGantt or NoBoard did not accept NoDrive's sign-in,
      tell the Workspace session (the page then opens through Open in NoGantt).
   4. If you run a project or board: My team shows problems only; "Show all team tasks" shows the rest.
   5. Switch the phone to flight mode and open NoAgenda: the last data stays, marked with the time it was saved.
   6. Nothing is ever changed or deleted from NoAgenda in this step.
   7. Sources: set one of your calendars to Hidden, then back to Personal: its events are back in Day. Leave the app,
      change an event in NoCalendar on the web, come back to the app with NoAgenda open: the row follows.
   8. Open a row and tap "Open in NoCalendar" / "NoTasks" / "NoGantt" / "NoBoard": the signed-in page of that item
      opens (the real pages are not tested in CI, see `docs/noagenda.md`, open points).
9. NoAgenda editing (same app, same account; use test items, not your real meetings):
   1. Open a to-do or an event of yours, tap Edit, change the title, tap Save. The row changes at once. Look at NoCalendar or
      NoTasks on the web: the same change is there and nothing else about the item changed.
   2. Tap + and make a new event. It is in your Personal or Work calendar on the web. Delete it again from the app (it moves to the calendar's trash bin).
   3. On a NoGantt task of a project you manage, change the agent (you, or one of your agents) and the dates; then Undo the date
      move. Do the same for the due date and the agent of a NoBoard card.
   4. Make two events at the same time: a red mark appears, the Conflicts chip lists them, and the bar at the top shows planned
      and free hours.
   5. Switch the phone to flight mode, change an event and Save: it waits (banner "Waiting to send"). Close the app, open it,
      switch the network on: it is sent.
   6. Change an event in the app and on the web at nearly the same time: the app keeps the other change and shows it under
      "Not sent" with three choices.
   7. Check that a project or board you may only view, a repeating event and an invitation are locked with a reason, and that
      "Open in ..." opens the signed-in page.
10. NoAgenda Timeline (same app, same account): open NoAgenda and tap **Timeline** next to Day, Week and Month. Expect:
   1. Your NoGantt tasks as bars under their project (and phase), with the filled part showing the percent done, the person or agent after
      the bar, a to-do with a start and a due date as a dashed bar, milestones and dated cards as diamonds, and the busy time of your own
      calendars shaded. Compare with the same project in NoGantt on the web: same dates, same order.
   2. A line with an arrow where one task follows another. Tap the little stub ("After: ...") to read what it follows. Scroll to the end:
      the last rows can be scrolled clear of the tab bar. The names on the left stay while you scroll sideways.
   3. Weeks and Days switch the zoom; the info button explains the marks. The chips Me, My agents, the All/Work/Personal switch and the
      Conflicts chip work as in the other views (My team is dimmed).
   4. Tap a task you manage, tap Edit, use "Move by" (-7, -1, +1, +7 days), Save. The bar moves, a toast reads "Moved to ..." with Undo, and
      NoGantt on the web shows the new dates with the tasks that follow moved too. Undo puts them back. Use a test task.
   5. A task of a project you may only view is locked with its reason. A task with only a start date is a one-day bar.
   6. Arabic: the chart stays left to right on purpose; the controls and sheets follow the language (not yet checked by a screenshot).
   Nothing is deleted from the Timeline.
11. Device calendar and contacts sync (same app, real iPhone, Safari as the default browser): Settings, "Add to iPhone Calendar & Contacts" (the same button is at the bottom of NoAgenda's Sources). Expect:
   1. A sheet that explains the steps. Continue opens the sign-in sheet: allow access. Safari opens and iOS asks to allow a configuration profile download; then
      Settings, Profile Downloaded, Install (within 8 minutes; Apple's install screen says "Signed by: Not Signed" and warns that the profile is not signed, because it is not signed yet).
   2. Calendar, Reminders and Contacts show your NoDrive calendars, to-do lists and contacts; a change on the iPhone shows on the web and the other way.
   3. The password was never shown. On drive.nourax.org, Settings, Security lists "NoDrive Calendar & Contacts (iPhone)". "It didn't work" removes it again and says so only when the
      server confirmed it; with no connection it says it could not remove it, and Try again does.
   4. Remove the NoDrive account in the app: the message tells how to remove the profile (Settings, General, VPN & Device Management). Nothing is deleted from the iPhone or the Drive.
   5. An alarm: make an event with an alarm a few minutes ahead in NoAgenda or NoCalendar. It fires on the iPhone.
   6. The agent (design 4.2, plan risk E4): set an agent on an event in NoAgenda, change the event's title in the iPhone Calendar app, open the event in NoAgenda. The agent is still
      shown. If only the `CATEGORIES` tag is left, note it: Apple's client dropped `X-NOURAX-AGENT-ID`. If both are gone, tell the NoAgenda session.
   7. In the sign-in sheet, allow access as a different user than the one signed in: NoDrive says "You allowed access as another user" and offers no profile.
   8. Apple's apps may also show NoGantt's task-copy calendar and Deck's board calendars; changes made there are overwritten. Suggestion: switch NoGantt's copy off. Every run makes a new
      password and a reinstall leaves the older one valid: remove old "NoDrive Calendar & Contacts (iPhone)" entries under Security on the web.
   9. Cancel: tap Cancel in the sign-in sheet's wait state, and (after allowing access) right after the system sheet closes. The sheet closes at once or says it is removing the password
      (the Cancel button is off meanwhile); afterwards no "NoDrive Calendar & Contacts (iPhone)" entry is left under Security on the web. If one is, remove it there and tell the iOS session.
   10. The Sources button at the bottom of NoAgenda ("Add to iPhone Calendar & Contacts") opens the same sheet; with no NoDrive account signed in it is off and says "Sign in to NoDrive first."
       (no UI test or screenshot covers these two states yet).
12. Go through the "owner" rows above, then read back the device name shown under
   Settings → Security on drive.nourax.org.

Building and the iPhone steps: [build.md](build.md).
