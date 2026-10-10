# Building PJSIP for MacroSIP

`scripts/build-pjsip.sh` produces a static arm64 build of pjproject 2.17 in
`third_party/pjsip/`, which `Package.swift` links through the `CPJSUA` target.

## Prerequisites

- Apple Silicon Mac, macOS 14+, Xcode Command Line Tools (`xcode-select --install`). Full Xcode is not needed.
- Homebrew packages: `brew install openssl@3 opus pkgconf`
- Network access to github.com for the first run (tarball is cached afterwards).

## Run

```sh
scripts/build-pjsip.sh          # ~1.5 min on an 8-core M-series Mac
swift build -c release
.build/release/pjsip-smoke      # prints version, codecs, audio devices; exits 0
```

Outputs (all git-ignored):

| Path | Contents |
|---|---|
| `third_party/pjsip/include/` | all PJ headers (incl. generated `config_site.h`, `os_auto.h`) |
| `third_party/pjsip/lib/` | static libs without the host-triple suffix (`libpj.a`, `libpjsua.a`, ...) |
| `third_party/pjsip/bin/pjsua` | pjsua CLI, used as the second phone in tests |
| `third_party/pjsip/LINKFLAGS` | linker flags to link an executable against the libs |
| `third_party/pjsip/CFLAGS` | compiler flags consumers must use (`-DPJ_AUTOCONF=1`, ...) |
| `third_party/build-logs/` | full configure / make logs |

## Rebuild

Just run the script again. It re-verifies the SHA-256 of the cached tarball,
re-extracts a fresh `third_party/pjproject-2.17/`, re-applies
`third_party/pjsip/config_site.h` and rebuilds from scratch. After changing
`config_site.h`, rerun the script and then `swift build` (SwiftPM does not track
the prebuilt libs; use `rm -rf .build` if a change seems not to take effect).

To upgrade PJSIP: change `PJ_VERSION` and `PJ_SHA256` in the script, delete the
old tarball, rerun.

## Pitfalls

- **Darwin SSL wins by default.** pjproject's configure autodetects Apple
  SecureTransport and selects it over OpenSSL even with `--with-ssl`. The script
  passes `--disable-darwin-ssl` so TLS uses OpenSSL 3 (SecureTransport is
  deprecated, and DTLS needs OpenSSL anyway).
- **Library names contain the host triple** (`libpj-aarch64-apple-darwin27.2.0.a`),
  which changes with every macOS update. The script installs them without it.
- **Consumers need `-DPJ_AUTOCONF=1`**, otherwise `pj/config.h` ignores the
  configure results. `CPJSUA.h` defines it before including `pjsua.h`.
- **libwebrtc (AEC) contains C++**, so the final link needs `-lc++`.
- **Homebrew dylibs target the host macOS.** OpenSSL and Opus are linked
  dynamically from `/opt/homebrew`, and the linker warns
  `building for macOS-14.0, but linking with dylib ... built for newer version`.
  Harmless for development; for a distributable `.app` they must be bundled
  (or built from source for 14.0) — see the packaging milestone.
- **Swift sees PJSIP headers only via `-Xcc -I`**: each Swift target that imports
  `CPJSUA` needs `swiftSettings: pjsipSwiftSettings` in `Package.swift`.
- `PJSUA_INVALID_ID` is a C enum constant; in Swift use `PJSUA_INVALID_ID.rawValue`.
