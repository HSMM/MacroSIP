# ADR 0013 — In-app updates with Sparkle

Date: 2026-10-12. Status: accepted.

## Context
The app needs in-app updates. Without them a user learns about a release from GitHub or `brew upgrade` and
reinstalls the DMG by hand. The app is signed ad hoc and not notarized (ADR 0007), it is built with
SwiftPM and the Command Line Tools only (ADR 0001), and releases come from `release.yml` on a tag
(ADR 0010), with release candidates tagged `-rc.N`.

## Decision
- **Sparkle 2**, pinned exactly (`2.7.3`) in `Package.swift` for `MacroSIPApp`. Sparkle's SwiftPM
  package is a prebuilt, ad hoc signed XCFramework (arm64 + x86_64), so it builds with the Command
  Line Tools and in the universal release build. Sparkle is MIT-licensed (GPL-compatible).
  Upgrading Sparkle means changing the pin and checking an update from the previous release.
- **Bundle**: `make-app.sh` copies `Sparkle.framework` into `Contents/Frameworks` (the binary's rpath
  `@executable_path/../Frameworks` comes from `Package.swift`; the build-directory rpath is removed)
  and signs inside out: Sparkle's XPC services, `Autoupdate`, `Updater.app`, the framework, then the
  app. `codesign --verify --deep --strict` must pass.
- **Hardened runtime with library validation off, until a Developer ID**: the hardened runtime's
  library validation loads only libraries signed with the app's Team ID, and an ad hoc signature has
  none, so dyld refuses the embedded framework ("different Team IDs"). The app and Sparkle's parts keep
  the hardened runtime (`--options runtime`), and the app's entitlements add
  `com.apple.security.cs.disable-library-validation`. Signing without the runtime was considered and
  rejected: it would also allow `DYLD_INSERT_LIBRARIES` into a process that holds the microphone
  permission. Follow-up: when the app is signed with a Developer ID, remove the entitlement; app and
  framework then share a Team ID.
- **Feed**: one `appcast.xml`, kept on the `gh-pages` branch and read from
  `https://raw.githubusercontent.com/HSMM/MacroSIP/gh-pages/appcast.xml` (`SUFeedURL`; no GitHub
  Pages setup needed), and attached to every GitHub Release. `release.yml` builds it with Sparkle's
  `generate_appcast` through `scripts/make-appcast.sh` and `scripts/publish-appcast.sh`: the new item
  points at the release's DMG, embeds the release body rendered to HTML as its notes, and keeps every
  earlier item. Releases running at the same time queue on `gh-pages` (the push is retried after a
  fresh fetch) instead of a workflow concurrency group, which would cancel pending tag runs. The
  workflow runs only in `HSMM/MacroSIP`.
- **Signing updates**: every item carries an EdDSA (ed25519) signature of the DMG. The public key is
  `SUPublicEDKey` in Info.plist (`make-app.sh`); the private key is never in the repository: it is the
  Actions secret `SPARKLE_PRIVATE_KEY` and, for the owner, the login keychain item
  "MacroSIP Sparkle private key" (and Sparkle's own item, account `macrosip`, used by
  `generate_keys`/`sign_update`).
- **Versions**: tags are `N.N.N` or `N.N.N-rc.N` only; `release.yml` and `make-appcast.sh` refuse any
  other suffix. Sparkle orders items by `CFBundleVersion`, the commit count (ADR 0010). A release must
  therefore be tagged on a later commit than the previous one; the workflow checks the build number
  against the feed before it creates the GitHub Release.
- **Channels**: a tag with a suffix (`-rc.N`) becomes an item on the `beta` channel. The app allows that channel only
  when Settings › General › Updates › "Include release candidates" is on (default: on when the running
  build is itself a release candidate). Final releases have no channel and reach everyone.
- **In the app** (`Platform/Updater.swift`): `SPUStandardUpdaterController`, started in
  `applicationDidFinishLaunching`, not for `--mock-engine`, demo launches or a binary outside an .app.
  Automatic checks are on, once a day (`SUEnableAutomaticChecks`, `SUScheduledCheckInterval` 86400);
  Sparkle asks before installing. "Check for Updates…" in the MacroSIP menu; the Updates group in
  Settings › General has "Check automatically", "Include release candidates", "Check Now" and the last
  check date. Sparkle's own windows are localized by Sparkle (English and Russian included).
- **Calls first**: a scheduled update found during a call is held back (Sparkle's gentle reminders) and
  shown when the last call ends; "Install and Relaunch" during a call waits for the calls to end
  (`shouldPostponeRelaunchForUpdate`). Quitting with a call in progress asks first.
- **Homebrew**: the cask declares `auto_updates true`, so `brew upgrade` leaves an app that updates
  itself alone.

## Consequences
Gatekeeper on the first install is unchanged (right-click › Open, ADR 0007); updates installed by
Sparkle are trusted through the EdDSA signature and launch without that dialog. Losing the private
key means installed copies can only be updated by a manual download of a release signed with a new
key; leaking it lets anyone who can also serve the feed push code to users, so it lives only in the
two places above. A release whose appcast step fails is visible but not offered in the app until the
job is re-run. Library validation stays off until a Developer ID exists. With an ad hoc signature
macOS ties the microphone permission to the exact build, so it asks again after each update; the
release notes and the README say so. The app grows by about 3 MB.
