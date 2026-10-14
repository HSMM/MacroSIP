<p align="center"><img src="packaging/AppIcon-1024.png" width="128" alt="MacroSIP icon"></p>

# MacroSIP

**English** · [Русский](README.ru.md)

[![CI](https://github.com/HSMM/MacroSIP/actions/workflows/ci.yml/badge.svg)](https://github.com/HSMM/MacroSIP/actions/workflows/ci.yml)
[![License: GPL v2](https://img.shields.io/badge/license-GPLv2%2B-blue.svg)](LICENSE)
![macOS 14+](https://img.shields.io/badge/macOS-14%2B-lightgrey)
![Universal: Apple Silicon and Intel](https://img.shields.io/badge/arch-universal-lightgrey)
![PJSIP 2.17](https://img.shields.io/badge/PJSIP-2.17-green)
![Release 26.0.0 in preparation](https://img.shields.io/badge/release-26.0.0_in_preparation-orange)

A MicroSIP-style SIP softphone for macOS on Apple Silicon and Intel. Native Swift and
SwiftUI interface, [PJSIP](https://github.com/pjsip/pjproject) 2.17 engine,
no Electron, no Qt. One small window, a menu bar icon, and everything a desk
phone does.

## Features

- Several SIP accounts registered at the same time; UDP, TCP and TLS with certificate verification; SRTP; STUN and ICE; outgoing-only accounts; per-account on/off in the account pop-up.
- Up to four calls: answer, hold, mute, DTMF (RFC 2833, SIP INFO or in-band), blind and attended transfer, local conference (merge includes held calls); call-quality indicator with a poor-connection notice; speaker, microphone and ringtone volume.
- Call recording to M4A (AAC), mono or stereo with you on the left channel and the caller on the right; playback from the call log.
- Auto-answer (off, all calls, contacts only, with a delay); single-call mode or call waiting; deny rules for incoming calls (everyone, numbers not in Contacts, anonymous callers); Do Not Disturb, also on a timer.
- Contact card with a photo, organization, several numbers with labels, email and notes; favorites; presence for watched contacts and your own published status.
- Directory of users: LDAP, a URL (CSV or JSON), Google Contacts or the macOS Contacts app; suggestions in the number field, incoming callers looked up by number, search only or import into Contacts.
- Quick keys: up to 12 speed-dial keys with BLF beside or under the main window; Call, DTMF, transfer and conference types; pickup on a ringing key.
- Call history; `sip:`, `sips:` and `tel:` links open in the app.
- Menu bar icon with registration state, quick dial, recent calls and Do Not Disturb; the app keeps working with the window closed.
- Reconnects after a network drop, an IP change or sleep; calls survive the switch. Network pane: RTP port range, rport, DNS SRV with a custom nameserver.
- Codecs: Opus (with FEC and DTX), G.722, G.711 and, off by default, G.722.1, GSM, iLBC and Speex. Echo cancellation and noise suppression.
- Interface in English, Russian, Belarusian, Ukrainian, Polish, German, French, Italian, Spanish, Hindi and Simplified Chinese, light and dark themes, launch at login, log file, in-app updates.
- Hold music for the caller (built-in or your own file), a recording notice tone, voicemail indicator (MWI) with a one-click call to voicemail, USB headset buttons, sound events and an audio test.
- Universal app for Apple Silicon and Intel.

## Screenshots

<p align="center">
  <picture><source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/dark/dialpad-calls.png?v=1"><img src="docs/screenshots/light/dialpad-calls.png?v=1" width="260" alt="Several calls"></picture>
  <picture><source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/dark/contacts-presence.png?v=1"><img src="docs/screenshots/light/contacts-presence.png?v=1" width="260" alt="Contacts with presence"></picture>
  <picture><source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/dark/call-recording.png?v=1"><img src="docs/screenshots/light/call-recording.png?v=1" width="260" alt="Active call with recording"></picture>
</p>

The app follows the macOS appearance. Light theme on the left, dark theme on the right:

<p align="center">
  <img src="docs/screenshots/light/account-popup.png?v=1" width="260" alt="Account pop-up, light theme">
  <img src="docs/screenshots/dark/account-popup.png?v=1" width="260" alt="Account pop-up, dark theme">
</p>

More screenshots, in English and Russian, light and dark: [docs/screenshots](docs/screenshots).

Status: the first release, 26.0.0, is being prepared; until then build from source (below). What comes next: [docs/ROADMAP.md](docs/ROADMAP.md).

## Installing

Requires macOS 14 or newer on Apple Silicon or Intel. The app and the DMG are universal
(one download for both architectures). Both ways below become available with 26.0.0.

### With Homebrew

```sh
brew tap hsmm/tap
brew install --cask hsmm/tap/macrosip
```

### From the DMG

1. Download `MacroSIP-<version>.dmg` from the
   [latest release](https://github.com/HSMM/MacroSIP/releases/latest).
2. Open it and drag MacroSIP onto the Applications folder.
3. First launch: the app is signed ad hoc (not notarized), so macOS refuses to open it
   at first. Right-click MacroSIP in Applications and choose Open, then confirm, or run
   `xattr -dr com.apple.quarantine /Applications/MacroSIP.app` once.

### Updates

MacroSIP checks for updates once a day and asks before installing one; MacroSIP › Check for
Updates… checks right away. Settings › General › Updates turns the daily check off or also offers
release candidates. Updates are signed and verified before they are installed, and the updated app
opens without the first-launch prompt. A Homebrew install updates itself the same way. Because the
app is signed ad hoc, macOS asks for microphone access again after each update; allow it once more.

Logs are written to `~/Library/Logs/MacroSIP/MacroSIP.log`; Settings › General has
"Open Log Folder" and "Copy Diagnostics" for bug reports.

## Building

Requirements: macOS 14 or newer on an Apple Silicon Mac and the Xcode Command Line Tools.
A full Xcode and Homebrew packages are not needed: OpenSSL and Opus are built from pinned
sources together with PJSIP. The Intel (x86_64) half of the universal build is
cross-compiled on the same Mac.

```sh
git clone https://github.com/HSMM/MacroSIP.git
cd MacroSIP
scripts/build-pjsip.sh      # builds OpenSSL, Opus and PJSIP 2.17 for arm64 and x86_64 once (about 5 minutes)
swift build -c release      # builds the Swift packages (native architecture)
scripts/make-app.sh         # bundles a universal dist/MacroSIP.app (ad-hoc signed)
open dist/MacroSIP.app
scripts/make-dmg.sh         # optional: dist/MacroSIP-<version>.dmg
```

Builds are signed ad hoc, so on first launch macOS asks to confirm opening an
app from an unidentified developer.

### Tests

```sh
scripts/test.sh             # Swift Testing suites (unit tests and engine tests over loopback)
scripts/selftest-call.sh    # end-to-end call against a local pjsua: RTP both ways, hold,
                            # DTMF, recording and M4A conversion, presence, two-leg conference
```

### Debugging

```sh
open dist/MacroSIP.app --args --log-level 5
log show --last 10m --predicate 'subsystem == "com.hsmm.macrosip"' --info
```

`--log-level` (0–6) sets the PJSIP verbosity; the app logs to the unified log
under the subsystem `com.hsmm.macrosip`.

## Releasing

Owner's checklist; the details are in [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md#releasing).

1. Tag `26.0.0` (release candidates: `26.0.0-rc.1`) and push the tag; the app takes its version from the tag. For a final release also bump `Product.fallbackVersion`.
2. `.github/workflows/release.yml` builds the DMG, creates the GitHub Release and adds it to the
   update feed (`appcast.xml` on the `gh-pages` branch, signed with the Actions secret
   `SPARKLE_PRIVATE_KEY`; ADR 0013). Tag each release on a new commit, a final release after its
   candidate too.
3. The same workflow updates the Homebrew cask in `HSMM/homebrew-tap`. One-time setup for that:
   create the public repository `HSMM/homebrew-tap`, then create a fine-grained personal access
   token with Contents read and write on that repository only and store it as the Actions secret
   `TAP_TOKEN` of `HSMM/MacroSIP`. Without the secret the step is skipped.

## Project layout

| Path | What |
|---|---|
| `Sources/CPJSUA` | C shim over pjsua, the only place that includes PJSIP headers |
| `Sources/MacroSIPCore` | Engine (accounts, calls, conference, recording, presence), models, storage |
| `Sources/MacroSIPApp` | SwiftUI/AppKit application |
| `Sources/macrosip-cli` | Command-line phone used by the self-test and for debugging against a PBX |
| `docs/` | Roadmap, design docs, ADRs, UI spec and mockups |
| `scripts/` | PJSIP build, app bundling, DMG, icon, cask update, tests |
| `packaging/` | Entitlements, app icon, Homebrew cask template |
| `.github/workflows/` | CI and release workflows |

Design documents: [ROADMAP](docs/ROADMAP.md), [engine design](docs/ENGINE.md),
[UI spec](docs/design/SCREENS.md), [decisions](docs/adr/).

## License

GPLv2 or later, because PJSIP is GPLv2+. See [LICENSE](LICENSE).
