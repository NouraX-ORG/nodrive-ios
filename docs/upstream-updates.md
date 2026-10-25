<!--
SPDX-FileCopyrightText: 2026 Nourax
SPDX-License-Identifier: GPL-3.0-or-later
-->
# NoDrive for iOS: updating from upstream

How to move NoDrive to a new Nextcloud iOS release (for example `35.3.0`). The idea: merge
upstream's tag, take upstream's version of every file our tools rewrite, then let the tools
re-apply NoDrive. Never hand-edit the rebranded files.

Current base: upstream tag `35.2.1`. Remotes in a working clone: `origin` =
`NouraX-ORG/nodrive-ios`, `upstream` = `nextcloud/ios`.

## Steps

1. **Fetch and pick the tag** (a stable release tag, not `master`):
   ```bash
   git remote add upstream https://github.com/nextcloud/ios.git   # once
   git fetch upstream --tags
   git switch platform/ios && git pull && git merge origin/main
   ```
2. **Check what changed upstream before merging** (helps with step 4):
   ```bash
   git diff --stat 35.2.1 <new-tag> -- Brand Nextcloud.xcodeproj .github/workflows
   git diff 35.2.1 <new-tag> -- Nextcloud.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
   ```
3. **Merge the tag** (a merge, so upstream's history stays):
   `git merge --no-ff <new-tag> -m "merge: Nextcloud iOS <new-tag>"`
4. **Resolve conflicts** with these rules:

   | Files | Rule |
   |---|---|
   | Files that `tools/rebrand.py` edits (table below) | take **upstream's** version: `git checkout --theirs -- <file>`; the tool re-applies NoDrive in step 6 |
   | Images that `tools/make-icons.py` writes or removes (`Brand/Custom.xcassets/…`, `Action Assistant/Images.xcassets/AppIcon.appiconset/…`, `talk-template.imageset`) | take upstream's version or keep the deletion; the tool rewrites them in step 6 |
   | `README.md` | keep **ours**; put upstream's new text into `docs/upstream-README.md`: `git show <new-tag>:README.md > docs/upstream-README.md` |
   | `.github/workflows/` | ours holds only `ios.yml`. If upstream added or changed a workflow, move it to `.github/upstream-workflows/` (reference only, switched off) |
   | Our own files (`tools/`, `branding/`, `docs/`, `NOTICE.md`, `.github/workflows/ios.yml`, `Tests/*/NoDrive*.swift`) | keep ours (upstream does not have them) |
   | Everything else (upstream code we never touched) | upstream's version; normally no conflict |

   Then `git add -A` and `git commit` to finish the merge.
5. **Update what depends on the version or on upstream's tooling:**
   - Xcode: read `XCODE_VERSION` and the destination in `.github/upstream-workflows/xcode.yml`; if
     upstream moved to a newer Xcode, change `XCODE_APP`, `DESTINATION` and the `runs-on` image in
     `.github/workflows/ios.yml` (check the runner-images list first).
   - Version: `MARKETING_VERSION` comes from upstream. Reset `VERSION_SUFFIX = '-nourax.1'` and
     `BUILD_NUMBER` at the top of `tools/rebrand.py`, and update the expected values in
     `Tests/NextcloudUnitTests/NoDriveBrandingTests.swift` (`version`, `userAgentMatchesServer`) and
     `tools/ci/inspect-products.py` (`NouraxVersion`).
   - Libraries: if `Package.resolved` changed, update `tools/legal/third-party.json` (new or removed
     libraries, licences, copyright lines). If NextcloudKit changed, re-check NextcloudKitUI's texts
     ([branding-sweep.md](branding-sweep.md) row 23).
   - Server: if the server moved to a new major version, re-check `USER_AGENT_CLIENT_IOS` in
     `lib/public/IRequest.php` and the pattern in `NoDriveBrandingTests.swift`.
6. **Re-apply NoDrive:**
   ```bash
   python3 tools/make-icons.py          # icons from the Nourax logo
   python3 tools/rebrand.py             # everything else
   python3 tools/rebrand.py             # must print "0 changed"
   python3 tools/make-icons.py --check && python3 tools/rebrand.py --check
   ```
   If `rebrand.py` stops with `rebrand: ERROR: … not found` (an upstream file changed where the tool
   anchors), look at the upstream change, adjust that one step in `tools/rebrand.py`, and run again.
   Do not edit the target file by hand.
7. **Sweep:** `python3 tools/check-branding.py`. Every new hit must be fixed or classified:
   - user-visible text in a `.strings` value → add its key to `STRINGS_APP_KEYS` or
     `STRINGS_SERVER_KEYS` in `tools/rebrand.py`;
   - a new Nextcloud link, logo or colour → a new step in `rebrand.py` or `make-icons.py`;
   - an internal identifier or legal notice → an anchored line in `tools/branding/allowlist.txt` with
     the reason. Never allowlist something a user can see.
   Then look at upstream's new or changed images (`python3 tools/check-branding.py --list-images`).
8. **Commit, push, CI:** commit (message ends with the attribution lines), `git push origin
   platform/ios`, wait for the iOS workflow to be green. Download `nodrive-ios-screenshots`, look at
   every screenshot, refresh `docs/screenshots/ios/` from its `screenshots-docs/` folder, and update
   [testing.md](testing.md) and [branding-sweep.md](branding-sweep.md) with the new run.
9. **Merge into main** only when the branch run is green: `git merge origin/main`, push, wait for
   green, then `git push origin HEAD:main` (fast-forward only; never force-push `main`).

## Files that will conflict

Upstream files that NoDrive changes (as of `35.2.1`). A conflict in any of them is expected; take
upstream's side and re-run the tools.

| Area | Files | Changed by |
|---|---|---|
| Brand hooks | `Brand/NCBrand.swift`, `Brand/Intro/NCIntroViewController.swift`, `Brand/LaunchScreen.storyboard`, all 9 `Brand/*.plist` and 9 `Brand/*.entitlements` | `rebrand.py` |
| Project | `Nextcloud.xcodeproj/project.pbxproj`; schemes `Nextcloud`, `Share`, `Widget`, `File Provider Extension`, `Notification Service Extension`, `BackgroundUploadExtension` (`.xcscheme`) | `rebrand.py` |
| Translations | `iOSClient/Supporting Files/*.lproj/Localizable.strings` (107 files, UTF-16; upstream syncs them from Transifex) | `rebrand.py` |
| Swift | `iOSClient/NCGlobal.swift`, `iOSClient/Settings/Settings/NCSettingsView.swift`, `iOSClient/Main/Collection Common/Cell/NCCellMain.swift`, `iOSClient/Scan document/NCUploadScanDocument.swift`, `Widget/Dashboard/DashboardData.swift`, `Widget/Files/FilesData.swift`, `Widget/Files/FilesWidgetView.swift`, `Notification Service Extension/NotificationService.swift`, `Action Assistant/ActionViewController.swift` | `rebrand.py` |
| Storyboards and XIBs | `File Provider Extension UI/MainInterface.storyboard`, `iOSClient/Login/NCLogin.storyboard`, `iOSClient/Share/NCShareUserCell.xib` | `rebrand.py` |
| Glyphs | 7 folder SVGs in `iOSClient/Images.xcassets/folder*.imageset`, `directory.pdf`, `document.pdf` | `rebrand.py` |
| Licence page | `iOSClient/Settings/Acknowledgements.rtf` (generated from `tools/legal/third-party.json`) | `rebrand.py` |
| Icons and images | `Brand/Custom.xcassets/AppIcon.appiconset`, `logo.imageset`, `intro1.imageset` (changed); `intro2/3/4.imageset` (deleted); `Action Assistant/Images.xcassets/AppIcon.appiconset` (changed, 3 PNGs deleted); `iOSClient/Images.xcassets/talk-template.imageset` (deleted) | `make-icons.py` |
| Docs and CI | `README.md` (ours; upstream's in `docs/upstream-README.md`, with `docs/upstream-README.md.license`); upstream workflows and `dependabot.yml` moved to `.github/upstream-workflows/` | by hand, rarely |

Files we never change, so upstream's updates arrive without conflicts: all other source, `LICENSE.txt`,
`COPYING.iOS`, `LICENSES/`, `AUTHORS.md`, `REUSE.toml`, the copyright headers.

`git diff --name-status 35.2.1 HEAD` shows the full list at any time.
