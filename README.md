<!--
SPDX-FileCopyrightText: 2026 Nourax
SPDX-License-Identifier: GPL-3.0-or-later
-->
# NoDrive for iOS

NoDrive is the file app for iPhone and iPad made by **Nourax**. It connects to one server only:
**Nourax Workspace** at `https://drive.nourax.org`.

With NoDrive you can:
- browse, open, upload, download, rename, move and delete your files;
- share files with public links (with expiry date and password);
- keep files offline;
- upload new photos automatically;
- reach your files from the Files app, the share sheet and widgets;
- open your Workspace apps (Mail, Calendar, Talk ...) from the side menu: the page opens inside NoDrive, already
  signed in. The apps come from the server's own list. Links in the notification list that point to your
  Workspace open there too. Your sign-in is sent only to your own server (`drive.nourax.org`), never to other sites.

Sign-in happens in the browser ("Log in with Nourax"). There is no server address to type in.

| | |
|---|---|
| Version | `35.2.1-nourax.1` (shown in the app as "NoDrive 35.2.1-nourax.1") |
| App id | `org.nourax.nodrive` (all ids: [docs/branding.md](docs/branding.md)) |
| Based on | Nextcloud iOS, tag [`35.2.1`](https://github.com/nextcloud/ios/tree/35.2.1) |
| Licence | GNU GPL v3.0 or later (see below) |
| Status | Test builds only. Not signed, not on the App Store, not on TestFlight |

## Based on Nextcloud iOS (thank you)

NoDrive is a rebranded build of the **Nextcloud iOS app**:
[https://github.com/nextcloud/ios](https://github.com/nextcloud/ios).

Almost all of the code in this repository was written by Nextcloud GmbH, Marino Faggiana and the
Nextcloud community. Thank you for building it and for publishing it as free software.
Nourax changed the name, the logo, the colours, the ids and the fixed server, and switched off
the services that only Nextcloud's own app may use. [NOTICE.md](NOTICE.md) lists every change.

Upstream's own README is kept unchanged in [docs/upstream-README.md](docs/upstream-README.md)
(its relative links point to the repository root).

"Nextcloud" is a trademark of Nextcloud GmbH. NoDrive is not made or endorsed by Nextcloud GmbH.

## Licence

- The app is licensed under the **GNU General Public License v3.0 or later**: [LICENSE.txt](LICENSE.txt).
- [COPYING.iOS](COPYING.iOS): the upstream copyright holders commit not to pursue a licence
  violation that comes only from the conflict between the GPL and the Apple App Store terms.
- Other licences used in this repository are in [LICENSES/](LICENSES/), and [REUSE.toml](REUSE.toml)
  says which files they cover. Upstream's copyright headers, licence files and [AUTHORS.md](AUTHORS.md)
  are unchanged.
- Third-party libraries inside the app, the trademarks, and the decision about the in-app licence
  page: [NOTICE.md](NOTICE.md).

## How to build

You need a Mac with **macOS Tahoe 26.6 or newer** and **Xcode 27.1 or newer** with the
**iOS 27 simulator**. The project needs the iOS 27 SDK, so older Xcode versions cannot build it.
No Apple account, no certificate and no `GoogleService-Info.plist` are needed for the simulator.

In Xcode:
1. `git clone https://github.com/NouraX-ORG/nodrive-ios.git`
2. Open `Nextcloud.xcodeproj` (the project keeps its upstream file name; the app it builds is NoDrive).
   Wait until "Resolving Package Graph" has finished.
3. In the toolbar pick the scheme **Nextcloud** and a simulator such as **iPhone 17**.
4. Press **Run** (⌘R).

From the command line, unsigned, the way CI builds it (`CODE_SIGNING_ALLOWED=NO`):

```bash
python3 tools/ci/simulated-entitlements.py /tmp/nodrive-ents
xcodebuild build \
  -project Nextcloud.xcodeproj -scheme Nextcloud -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -derivedDataPath DerivedData -clonedSourcePackagesDirPath DerivedData/SourcePackages \
  -xcconfig /tmp/nodrive-ents/simulated-entitlements.xcconfig \
  ENABLE_THREAD_SANITIZER=NO CODE_SIGNING_ALLOWED=NO
```

The first line is needed only for an unsigned build: it gives the simulator app its app group
and keychain group without signing. Details, the reasons behind each option, unit tests, and how to
run the app on your own iPhone: [docs/build.md](docs/build.md).

## Test builds

Test builds exist only as **GitHub Actions artifacts**. There are no GitHub releases and no
store uploads.

1. Open the repository's **Actions** tab, workflow **iOS**.
2. Open the newest green run on `main`.
3. Download the artifact **`nodrive-ios-simulator-app`** (you must be signed in to GitHub).
   It holds `NoDrive.app` for the iOS Simulator on a Mac with Apple silicon. It cannot be installed
   on a real iPhone. Artifacts are deleted after 14 days.

The same run also has `nodrive-ios-test-results` (unit tests, build checks),
`nodrive-ios-screenshots` and `nodrive-ios-screens-results` (screens, network check).

## Documents

| File | What it holds |
|---|---|
| [NOTICE.md](NOTICE.md) | Licensed software, trademarks, what Nourax changed, the in-app licence page decision |
| [docs/branding.md](docs/branding.md) | Every id, the colours and icons, and how the branding tools work |
| [docs/branding-sweep.md](docs/branding-sweep.md) | The "no Nextcloud on any screen" sweep: hits before and after, and what is kept on purpose |
| [docs/build.md](docs/build.md) | Building in Xcode, on the command line and in CI; running on your own iPhone |
| [docs/testing.md](docs/testing.md) | Test results (CI and owner tests) and the screenshot index |
| [docs/upstream-updates.md](docs/upstream-updates.md) | How to merge a new Nextcloud iOS release |
| [docs/screenshots/ios/](docs/screenshots/ios/) | Screenshots of every screen before sign-in (English, German, Arabic, dark mode) and of the Workspace apps menu (`workspace-light/`, `workspace-dark/`) |

## Branding tools

| Tool | What it does |
|---|---|
| `tools/rebrand.py` | Applies every NoDrive change to the upstream source. Safe to run again; `--check` changes nothing and fails if anything is missing |
| `tools/make-icons.py` | Makes every icon and logo image from the one Nourax logo (`branding/nourax-logo.png`) |
| `tools/check-branding.py` | Fails if a Nextcloud name, link, id or colour can reach a user again |

CI (`.github/workflows/ios.yml`) runs all three on every push to `main` and `platform/ios`.
