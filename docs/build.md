<!--
SPDX-FileCopyrightText: 2026 Nourax
SPDX-License-Identifier: GPL-3.0-or-later
-->
# NoDrive for iOS: building

NoDrive builds only on a Mac. CI builds it on GitHub's hosted macOS runners; nothing is signed and
nothing is uploaded to Apple.

## What you need

| Item | Version | Why |
|---|---|---|
| macOS | **Tahoe 26.6 or newer** | Apple's minimum for Xcode 27.0 and 27.1 ([Xcode system requirements](https://developer.apple.com/xcode/system-requirements/)) |
| Xcode | **27.1** (27.0 also has the iOS 27 SDK) | `BackgroundUploadExtension` targets iOS 27 and several files use iOS 27 APIs. CI and upstream use 27.1 |
| iOS Simulator | iOS 27 runtime, e.g. **iPhone 17** | CI uses iPhone 17 with iOS 27.0 |
| Apple account | none for the simulator | only needed for your own iPhone (below) |
| `GoogleService-Info.plist` | **not needed** | NoDrive removed Firebase's config and the Crashlytics upload phase |
| Python 3 | any current 3.x | the branding tools; `tools/make-icons.py` also needs Pillow (`python3 -m pip install pillow`) |

The app runs on iOS 17 or newer (project deployment target 17.0); the Background Upload extension
needs iOS 27. The Swift packages are fetched from `Package.resolved` on the first build (several
minutes).

## In Xcode (simulator)

1. `git clone https://github.com/NouraX-ORG/nodrive-ios.git`
2. Open `Nextcloud.xcodeproj`. The project, scheme and target keep their upstream name `Nextcloud`;
   the app they build is NoDrive. Wait until "Resolving Package Graph" has finished.
3. In the toolbar pick the scheme **Nextcloud** and the destination **iPhone 17** (any iOS 27 simulator).
4. Product → Run (⌘R). The simulator shows the NoDrive intro with "Log in".

Signing: the project has no team (`DEVELOPMENT_TEAM` is empty) and uses automatic signing. For the
simulator Xcode signs locally without an account. If Xcode still asks for a development team, either
build from the command line (next section, no account at all), or add any Apple account in
Xcode → Settings → Accounts and pick its "(Personal Team)" under Signing & Capabilities. Do not
commit that change.

## Command line (simulator, unsigned, as CI does)

```bash
# 1. entitlements for an unsigned simulator build (app group + keychain group)
python3 tools/ci/simulated-entitlements.py /tmp/nodrive-ents

# 2. build the app, all extensions and the test bundles
xcodebuild build-for-testing \
  -project Nextcloud.xcodeproj -scheme Nextcloud -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -derivedDataPath DerivedData \
  -clonedSourcePackagesDirPath DerivedData/SourcePackages \
  -xcconfig /tmp/nodrive-ents/simulated-entitlements.xcconfig \
  -enableThreadSanitizer NO -enableCodeCoverage NO \
  ENABLE_THREAD_SANITIZER=NO CODE_SIGNING_ALLOWED=NO

# 3. unit tests (no server needed)
xcodebuild test-without-building \
  -xctestrun "$(ls DerivedData/Build/Products/*.xctestrun | head -n 1)" \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:NextcloudUnitTests

# 4. install and start it in a booted simulator
xcrun simctl boot "iPhone 17" || true
open -a Simulator
xcrun simctl install booted DerivedData/Build/Products/Debug-iphonesimulator/Nextcloud.app
xcrun simctl launch booted org.nourax.nodrive
```

Why each option:

| Option | Reason |
|---|---|
| `CODE_SIGNING_ALLOWED=NO` | No signing of any kind (project rule for CI) |
| `-xcconfig …/simulated-entitlements.xcconfig` | Without signing, Xcode writes no entitlements, and the simulator then gives the app no app group and no keychain group (the app stops at launch: "App Group container URL not found", OSStatus -34018). The tool links the entitlements into the binaries as the Mach-O sections Xcode itself uses for simulator builds, and sets `ENABLE_DEBUG_DYLIB=NO` so they land in the main executable |
| `ENABLE_THREAD_SANITIZER=NO` (and `-enableThreadSanitizer NO`) | The scheme's test action turns Thread Sanitizer on; the command-line flag alone did not switch it off |
| `-clonedSourcePackagesDirPath DerivedData/SourcePackages` | `BackgroundUploadExtension`'s header search paths expect the packages at `$(BUILD_DIR)/../../SourcePackages` |
| `-disableAutomaticPackageResolution` (CI) | Use exactly the versions in `Package.resolved` |
| `-only-testing:NextcloudUnitTests` | The UI tests in `NextcloudUITests` need a Nextcloud test server; only the NoDrive screenshot UI test runs in CI (job "screens") |

The `.app` folder is called `Nextcloud.app` in DerivedData (internal product name); CI renames the
copy it ships to `NoDrive.app`. The bundle id, display name and icon are NoDrive's either way.

## CI (`.github/workflows/ios.yml`)

Runs on every push to `main`, `platform/ios` and the feature branches (`feature/workspace-apps*`,
`feature/smart-conflicts`, `feature/problem-reports`), and by hand (workflow_dispatch). No secrets.

| Job | Runner | What it does |
|---|---|---|
| Branding gate | `ubuntu-latest` | `rebrand.py --check`, `make-icons.py --check`, `check-branding.py` (about 15 s) |
| Build and unit tests (iOS Simulator) | `xcode-27` | Select Xcode 27.1, check every xcodebuild option in `xcodebuild -help`, restore/save the Swift-package cache, validate the project file, simulated entitlements, `build-for-testing` (unsigned), package `NoDrive.app`, inspect ids and entitlements, sweep the built app (report), unit tests (about 17 min) |
| Simulator screens | `xcode-27` | Install and launch `NoDrive.app`, UI walk in en, de, ar and dark mode with screenshots, the drive.nourax.org stand-in, DNS capture and network gate, screenshot report; the two UI tests after sign-in (Workspace apps, Smart conflicts) run in light and dark mode (about 130 min, job limit 180 min) |
| Server login | `ubuntu-24.04` | A throwaway Nextcloud 35.0.2 in Docker: the web-view sign-in checks (`server_login_check.py`) and the round 3 checks (`server_round3_check.py`: the size the app reads for Smart conflicts, and that the unit-test fixtures keep the real answer shape) |

Why `xcode-27` and not `macos-latest`: `macos-latest` is macOS 26 with Xcode 26 only, which cannot
build an iOS 27 project; GitHub's hosted `xcode-27` image (macOS 27, image `xcode-27-arm64`) has
Xcode 27.1, as upstream's own CI uses. Installing Xcode 27 on `macos-latest` would need an Apple
account secret.

Artifacts of each run:

| Artifact | Kept | Content |
|---|---|---|
| `nodrive-ios-simulator-app` | 14 days | `nodrive-ios-simulator-app.zip` with `NoDrive.app` for the iOS Simulator (Apple silicon); not installable on an iPhone |
| `nodrive-ios-test-results` | 14 days | build log, unit-test `.xcresult` and summary, product inspection, app sweep, simulated entitlements |
| `nodrive-ios-screenshots` | 14 days | full-size screenshots per variant and the docs copies |
| `nodrive-ios-screens-results` | 14 days | UI-test results, walk logs, accessibility texts, network capture summary, stand-in log, screenshot report |
| `nodrive-ios-build-products` | 3 days | input for the screens job (app, UI-test runner, `.xctestrun`) |

To install the CI build on a Mac: download `nodrive-ios-simulator-app`, unzip it twice (the
artifact zip, then `nodrive-ios-simulator-app.zip`), boot a simulator, then
`xcrun simctl install booted NoDrive.app` and `xcrun simctl launch booted org.nourax.nodrive`.

The screens job can be re-run alone with the products of an earlier run: Actions → iOS → Run
workflow → `products_run_id` = that run's id.

The screens job also runs the Workspace apps UI test and the Smart conflicts UI test (the Auto upload
setting "If a file is already in NoDrive", light and dark, Photos access granted by
`simctl privacy grant photos`). Dispatch inputs: `only_workspace` (only the Workspace test) and `only_round3`
(only the Smart conflicts test).

## On your own iPhone (optional, free Apple account)

A free Apple account can install NoDrive on your own iPhone for testing. The install stops working
after 7 days (then press Run again). Free accounts support App Groups and Keychain Sharing, which is
all NoDrive's entitlements need (push was removed). Apple limits how many App IDs a free account can
register, so do not use the real ids and keep the number of extensions small.

1. iPhone: Settings → Privacy & Security → **Developer Mode** → On (the phone restarts). Connect it
   to the Mac with a cable and tap "Trust".
2. Xcode → Settings → Accounts → **+** → Apple Account → sign in.
3. In Terminal, in the clone, give every id a private base (local only, never commit it):
   `python3 tools/rebrand.py --bundle-base org.nourax.nodrive.dev<your initials>`
   This changes all 12 bundle ids, the app group and the keychain group together.
4. Fewer App IDs: select the project → target **Nextcloud** → Build Phases. In
   **Embed Foundation Extensions** remove *Notification Service Extension* (push is off anyway),
   *Action Assistant* and *WidgetDashboardIntentHandler* with the **−** button; in the **Copy Files**
   phase (destination Extensions) remove *BackgroundUploadExtension* (it also needs iOS 27 on the
   phone). Remove the same four targets from **Target Dependencies**. What stays: the app, Share,
   File Provider Extension, File Provider Extension UI and Widget (5 App IDs).
5. For each remaining target (Nextcloud, Share, File Provider Extension, File Provider Extension
   UI, Widget): Signing & Capabilities → Team → "<your name> (Personal Team)".
6. Toolbar: scheme **Nextcloud**, destination **your iPhone**. Press Run.
7. First start only: iPhone Settings → General → VPN & Device Management → your Apple account →
   Trust.
8. When done: `git restore .` in the clone throws away these local changes (ids, team, phases).

For TestFlight or the App Store, a paid Apple Developer Program account, real signing and the real
ids (`org.nourax.nodrive…`) are needed; that is a later owner step.

## Branding tools

Before a build nothing needs to run: the repository already contains the rebranded source. After
an upstream merge, run the tools as in [upstream-updates.md](upstream-updates.md):

```bash
python3 tools/make-icons.py && python3 tools/rebrand.py && python3 tools/check-branding.py
```
