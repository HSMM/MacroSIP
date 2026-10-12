# MacroSIP

A MicroSIP-style SIP softphone for macOS on Apple Silicon. Native Swift/SwiftUI
interface, [PJSIP](https://github.com/pjsip/pjproject) 2.17 engine, no Electron,
no Qt.

Features:

- Multiple accounts with simultaneous registration; UDP, TCP, TLS; SRTP; STUN; ICE.
- Calls, DTMF, mute, hold, blind and attended transfer, up to four simultaneous calls.
- Call history and contacts; `sip:`, `sips:` and `tel:` links.
- Menu bar icon with quick dial, recent calls and Do Not Disturb.
- Contact presence (subscribe and publish), call recording (M4A), auto-answer, local conference.
- Codecs: Opus, G.722, G.711.

Status: in development. See [docs/ROADMAP.md](docs/ROADMAP.md).

## Building

Requirements: macOS 14+, Apple Silicon, Xcode Command Line Tools, Homebrew with
`openssl@3`, `opus` and `pkgconf`.

```sh
scripts/build-pjsip.sh      # downloads and builds PJSIP 2.17 (once, several minutes)
swift build -c release      # builds the Swift packages
scripts/test.sh             # Swift Testing suites
scripts/selftest-call.sh    # real call against a local pjsua: two-way RTP, hold, DTMF
scripts/make-app.sh         # bundles "MacroSIP.app" into dist/
```

Debugging: `open dist/MacroSIP.app --args --log-level 5` raises the PJSIP log level; read it with
`log show --last 10m --predicate 'subsystem == "com.hsmm.macrosip"' --info`.

```sh
```

Builds are signed ad hoc. On first launch macOS will ask to confirm opening an
app from an unidentified developer.

## License

GPLv2 or later, because PJSIP is GPLv2+. See [LICENSE](LICENSE).
