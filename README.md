# MacroSIP

A MicroSIP-style SIP softphone for macOS on Apple Silicon. Native Swift/SwiftUI
interface, [PJSIP](https://github.com/pjsip/pjproject) 2.17 engine, no Electron,
no Qt.

MacroSIP ships in two editions built from one codebase:

| | MacroSIP Lite | MacroSIP |
|---|---|---|
| Multiple accounts, simultaneous registration | ✓ | ✓ |
| Calls, DTMF, mute, hold, blind and attended transfer | ✓ | ✓ |
| Call history, contacts | ✓ | ✓ |
| Menu bar icon with quick dial and DND | ✓ | ✓ |
| TLS, SRTP, STUN, Opus, G.722, G.711 | ✓ | ✓ |
| Contact presence (subscribe and publish) | | ✓ |
| Call recording (M4A) | | ✓ |
| Auto-answer | | ✓ |
| Local conference | | ✓ |

Status: in development. See [docs/ROADMAP.md](docs/ROADMAP.md).

## Building

Requirements: macOS 14+, Apple Silicon, Xcode Command Line Tools, Homebrew with
`openssl@3`, `opus` and `pkgconf`.

```sh
scripts/build-pjsip.sh      # downloads and builds PJSIP 2.17 (once, several minutes)
swift build -c release      # builds the Swift packages
scripts/make-app.sh lite    # bundles "MacroSIP Lite.app" into dist/
scripts/make-app.sh full    # bundles "MacroSIP.app" into dist/
```

Builds are signed ad hoc. On first launch macOS will ask to confirm opening an
app from an unidentified developer.

## License

GPLv2 or later, because PJSIP is GPLv2+. See [LICENSE](LICENSE).
