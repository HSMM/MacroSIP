# MacroSIP — development notes

MicroSIP-style SIP softphone for macOS 14+ on Apple Silicon. Swift 6, SwiftUI/AppKit,
SwiftPM only (no Xcode project), PJSIP 2.17 linked statically through the `CPJSUA` C target.

## Read first
- `docs/ROADMAP.md` — milestones and their done criteria.
- `docs/GLOSSARY.md` — shared vocabulary. Use these terms in code and docs.
- `docs/adr/` — settled decisions. Do not reopen them silently; add a new ADR to change one.
- `docs/design/mockups.html` — approved UI mockups; `docs/design/SCREENS.md` — their text spec (elements, states, strings). UI code follows both.

## Layout
- `Sources/CPJSUA` — C shim and umbrella header over pjsua. The only place that includes PJSIP headers.
- `Sources/MacroSIPCore` — Swift engine: accounts, calls, presence, recording, storage. No UI imports.
- `Sources/MacroSIPApp` — SwiftUI/AppKit app.
- `Tests/` — Swift Testing (`import Testing`) for Core; XCTest is unavailable with Command Line Tools only.
- `scripts/` — `build-pjsip.sh`, `make-app.sh`, `make-dmg.sh`, `make-icon.swift`, `update-cask.sh`, `test.sh`, `selftest-call.sh`, `check-strings.sh`. `third_party/` holds the PJSIP build (git-ignored except `pjsip/config_site.h`).

## Rules
- One product, one build: `MacroSIP`, bundle id `com.hsmm.macrosip` (ADR 0010, 2026-10-12). The earlier Lite/Full split is gone; `[Full]` in `docs/design/SCREENS.md` now just marks the features of milestone 5. Never add edition flags back.
- PJSIP callbacks arrive on PJSIP worker threads. Hop to the main actor before touching app state; never block a PJSIP thread on the main actor.
- Every `pjsua_*` call that can fail returns `pj_status_t`; check it and surface the error text via `pj_strerror`.
- Passwords live only in Keychain. Everything else is JSON in `~/Library/Application Support/MacroSIP/`.
- Strings: see "Localization" below. English is the base, Russian is maintained alongside; a new string is not done until both languages have it.
- Run tests with `scripts/test.sh`, never bare `swift test` (it cannot find the Testing macro plugin under Command Line Tools). A milestone is done only after: `swift build` clean, tests green, `scripts/selftest-call.sh` passes, and a real call verified (pjsua CLI as the second phone, or the owner's SIP account).
- Commit after each working milestone and push to `main`.
- SwiftUI `@State` does not compile under Command Line Tools (its macro plugin ships only with Xcode). Use the `@Local` wrapper from `Sources/MacroSIPApp/Views/Components/Local.swift`; it is a drop-in for `@State`.
- Opus and OpenSSL are linked as static archives from Homebrew (Package.swift) so the .app has no /opt/homebrew dylib dependencies; never switch them back to `.linkedLibrary`.
- Debug builds accept `--mock-engine`, `--demo-state <name>`, `--data-dir <path>`, `--snapshot <prefix>`; all builds accept `--log-level 0-6` (or `MACROSIP_LOG_LEVEL`) for PJSIP verbosity; see `Sources/MacroSIPApp/Model/LaunchOptions.swift`. Demo launches use a temp data dir and never touch the real Keychain.
- Do not add dependencies without an ADR.
- Versions are `YY.MINOR.PATCH` (ADR 0011): the first release is `26.0.0`; tags carry the bare number. `make-app.sh` takes the version from `git describe`.

## Localization
- All UI text goes through `L` in `Sources/MacroSIPApp/Model/Strings.swift`; views never contain user-visible literals. `L.loc(key, "English default")` calls `String(localized:defaultValue:bundle: .module)`.
- Classic `Localizable.strings` / `.stringsdict`, not `.xcstrings`: `xcstringstool` ships only with Xcode, so SwiftPM under Command Line Tools cannot compile catalogs (ADR 0012). `Package.swift` has `defaultLocalization: "en"` and `resources: [.process("Resources")]` on `MacroSIPApp`; the build produces `MacroSIP_MacroSIPApp.bundle`, which `make-app.sh` copies to `Contents/Resources` (where `Bundle.module` finds it).
- **Add a string**: (1) add `static var`/`func` in `L` with a dotted key and an English default (interpolations become `%@` for text and `%lld` for integers; with two or more arguments use `%1$@`, `%2$@` in both files); (2) add the key to `Resources/en.lproj/Localizable.strings` and `Resources/ru.lproj/Localizable.strings`; (3) run `scripts/check-strings.sh` (keys in `L` equal keys in both languages, placeholders match, plural categories complete).
- **Counts** (contacts, calls, entries, participants) use `Localizable.stringsdict` in both languages instead: key with `NSStringLocalizedFormatKey` `%#@count@`, categories `one`/`other` for English, `one`/`few`/`many`/`other` for Russian. Do not add the same key to `.strings`.
- Not translated on purpose: product, codec and protocol names (SIP, SRTP, TLS, STUN, ICE, DTMF, REGISTER), the diagnostics report and log lines. The microphone prompt is in `packaging/InfoPlist/<lang>.lproj/InfoPlist.strings`, copied by `make-app.sh`.
- Check a language: `dist/MacroSIP.app/Contents/MacOS/MacroSIP --demo-state contacts -AppleLanguages "(ru)"` (add `--snapshot <prefix> --snapshot-after 3` for PNGs). Russian text is about 25% longer; look at the status bar, the call panel buttons and the account pop-up in a snapshot after adding text.

## Polish and release (milestone 6)
- **Log file**: `~/Library/Logs/MacroSIP/MacroSIP.log` (`Platform/AppLog.swift`). Engine `.log` events go to categories `engine` (messages prefixed "engine: ") and `pjsip`; app code uses `AppLog.app/.recording/.presence` (os_log plus file). Each line is one `write(2)` on an `O_APPEND` descriptor, so a crash loses nothing. Rotation at 2 MB, three files: `MacroSIP.log`, `.1.log`, `.2.log`. Line: `date [category] E|W|I|D text`. `--log-level` still sets PJSIP verbosity only. Demo launches write no file; `MACROSIP_LOG_DIR=<dir>` redirects it (also for demos). New app-side logging uses `AppLog`, not a bare `Logger`.
- **Diagnostics**: Settings › General › Troubleshooting. "Copy Diagnostics" puts versions, macOS, accounts (no passwords) and settings on the clipboard; "Open Log Folder" reveals the log in Finder.
- **Launch at login**: `SMAppService.mainApp` (`AppModel.applyLaunchAtLogin`). The toggle shows the real state when the pane opens and at start, shows macOS's error under the row if it refuses, and offers "Open Login Items…" when the status is `requiresApproval`. Limitation: it only works from a bundled app (`dist/MacroSIP.app` or `/Applications`), never from `swift run` or demo launches, and an ad-hoc signed app may need approval in System Settings › General › Login Items; if macOS reports the app as not found after it was moved, toggle off and on once from the new location.
- **Language**: Settings › General (System / English / Русский) writes `AppleLanguages` in the app's defaults (nil removes it) and offers a restart; after the restart `Bundle.module` and the system menus use that language.
- **About**: standard panel (`AboutPanel` in `Platform/AppInfo.swift`), reached from MacroSIP › About MacroSIP. Version is `Product.version`, build is `CFBundleVersion`; the copyright and credits are fixed strings.
- **App icon**: `swift scripts/make-icon.swift` draws the icon (source of truth: `packaging/AppIcon.svg`, a dial pad whose pressed keys trace an M on a green gradient) into `packaging/AppIcon.icns` and `AppIcon-1024.png`; run `swift scripts/make-icon.swift` after changing the artwork.
- **DMG**: `scripts/make-dmg.sh [release]` builds the app and writes `dist/MacroSIP-<version>.dmg` (volume "MacroSIP", Applications symlink, ad-hoc signed, no notarization).
- **CI**: `.github/workflows/ci.yml` (push and PR to main, macOS 15 arm64: Homebrew deps, cached `third_party/pjsip`, build, tests, selftest, release app as artifact). `release.yml` runs on tags `[0-9]*.[0-9]*.[0-9]*`.

## Releasing
1. Everything green locally: `swift build`, `scripts/test.sh`, `scripts/selftest-call.sh`, `scripts/make-dmg.sh`; mount the DMG and start the app.
2. `Product.version` equals the version being released (the release job fails if the app's version and the tag differ; `make-app.sh` takes the version from the nearest tag). Update `docs/ROADMAP.md`.
3. Tag and push: `git tag 26.0.0 && git push origin 26.0.0`. A release candidate is tagged `26.0.0-rc.1`; any tag with a `-` becomes a GitHub pre-release. Homebrew accepts such versions, so the cask for a candidate has `version "26.0.0-rc.1"` and installs `MacroSIP-26.0.0-rc.1.dmg`.
4. `release.yml` builds `dist/MacroSIP-<tag>.dmg`, creates the GitHub Release with generated notes, then runs `scripts/update-cask.sh <tag> <dmg>` against a clone of `HSMM/homebrew-tap` (needs the `TAP_TOKEN` secret, see README "Releasing") which commits `macrosip <tag>` to `Casks/macrosip.rb`. By hand: `scripts/update-cask.sh <version> dist/MacroSIP-<version>.dmg` writes `dist/macrosip.rb` and prints the git commands; with `TAP_DIR=<clone>` it commits and pushes.
5. Check: `brew tap hsmm/tap && brew install --cask hsmm/tap/macrosip`, then launch (right-click › Open the first time).
6. The cask template is `packaging/homebrew/macrosip.rb` (checked with `brew style --cask` inside a tap; keep `desc` free of the platform name and `depends_on` stanzas in that order).
7. Not covered: Developer ID signing and notarization (v2 candidates).
