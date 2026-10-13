# Building PJSIP for MacroSIP

`scripts/build-pjsip.sh` builds OpenSSL 3, Opus and pjproject 2.17 as static libraries for
arm64 and x86_64 and merges them into universal archives, which `Package.swift` links through
the `CPJSUA` target. Decision record: `docs/adr/0012-universal-build.md`.

## Prerequisites

- Apple Silicon Mac, macOS 14+, Xcode Command Line Tools (`xcode-select --install`). Full Xcode
  is not needed. The x86_64 half is cross-compiled on the same Mac.
- No Homebrew packages: OpenSSL and Opus are built from pinned source tarballs.
- Network access to github.com and downloads.xiph.org for the first run (tarballs are cached).
- Optional, to run the x86_64 slice on Apple Silicon: Rosetta 2
  (`softwareupdate --install-rosetta --agree-to-license`).

## Run

```sh
scripts/build-pjsip.sh          # first run ~5 min on an 8-core M-series Mac; afterwards seconds
scripts/build-pjsip.sh --clean  # remove all outputs (not the downloads) and rebuild
swift build -c release
.build/release/pjsip-smoke      # prints version, codecs, audio devices; exits 0
scripts/make-app.sh             # universal dist/MacroSIP.app (swift build --arch arm64 --arch x86_64)
SELFTEST_ARCH=x86_64 scripts/selftest-call.sh   # end-to-end call with the x86_64 slice under Rosetta 2
```

Pinned sources (version, URL and SHA-256 at the top of the script):

| Component | Version | Notes |
|---|---|---|
| pjproject | 2.17 | `config_site.h` from `third_party/pjsip/`, same for both architectures |
| OpenSSL | 3.5.9 (LTS) | `no-shared no-module no-tests`, only `build_libs` + `install_dev` |
| Opus | 1.6.1 | `--disable-shared --disable-doc --disable-extra-programs` |

Every slice is built with `-arch <arch> -mmacosx-version-min=14.0`, and the script checks the
architecture and the `minos` of every archive and of `pjsua`. arm64 is a native build; x86_64
passes `--host=x86_64-apple-darwin` to Opus and pjproject and the `darwin64-x86_64-cc` target to
OpenSSL.

## Layout

All outputs are git-ignored except `third_party/pjsip/config_site.h`.

| Path | Contents |
|---|---|
| `third_party/downloads/` | verified tarballs (kept by `--clean`) |
| `third_party/deps/<arch>/{include,lib}` | OpenSSL and Opus for one architecture |
| `third_party/deps/universal/{include,lib}` | `libssl.a`, `libcrypto.a`, `libopus.a` (arm64 + x86_64); linked by `Package.swift` |
| `third_party/pjsip/arch/<arch>/` | PJSIP headers, libraries and `pjsua` for one architecture |
| `third_party/pjsip/include/` | PJ headers (incl. generated `config_site.h`, `os_auto.h`); `pj/compat/m_auto.h` and `os_auto.h` carry one `#if` branch per architecture because configure writes the machine name into them |
| `third_party/pjsip/lib/` | universal static libs without the host-triple suffix (`libpj.a`, `libpjsua.a`, ...) |
| `third_party/pjsip/bin/pjsua` | universal pjsua CLI, used as the second phone in tests |
| `third_party/pjsip/LINKFLAGS` | linker flags to link an executable against the universal libs |
| `third_party/pjsip/CFLAGS` | compiler flags consumers must use (`-DPJ_AUTOCONF=1`, ...) |
| `third_party/build/` | source trees while building; removed afterwards unless `KEEP_BUILD=1` |
| `third_party/build-logs/<arch>/` | full configure / make logs |

## Rebuild and caching

Each component (OpenSSL, Opus, PJSIP per architecture, then the universal merge) writes a stamp
holding its recipe: versions, checksums, flags, the SHA-256 of `config_site.h` and the stamps of
what it was built against. A run skips every component whose stamp matches and rebuilds the rest
from a freshly extracted source tree. So after changing `config_site.h` just rerun the script:
it rebuilds PJSIP for both architectures (~2 min) and keeps OpenSSL and Opus. Then run
`swift build` (SwiftPM does not track the prebuilt libs; use `rm -rf .build` if a change seems not
to take effect).

To upgrade a component: change its version and checksum in the script, rerun. Take the checksum
from upstream (`openssl-<v>.tar.gz.sha256` on the OpenSSL release, `SHA256SUMS.txt` on
downloads.xiph.org) and compare it with `shasum -a 256` of the download.

CI caches `third_party/pjsip` and `third_party/deps` with a key over the script and
`config_site.h`; on a hit the script finds all stamps current and does nothing.

## Pitfalls

- **Darwin SSL wins by default.** pjproject's configure autodetects Apple
  SecureTransport and selects it over OpenSSL even with `--with-ssl`. The script
  passes `--disable-darwin-ssl` so TLS uses OpenSSL 3 (SecureTransport is
  deprecated, and DTLS needs OpenSSL anyway).
- **OpenSSL's default certificate paths are not used.** The app hands PJSIP a PEM bundle of the
  macOS system roots (`TLSRoots.swift`, `ca_list_file`), so `OPENSSLDIR` (set to `/private/etc/ssl`)
  does not matter.
- **Library names contain the host triple** (`libpj-aarch64-apple-darwin27.2.0.a`,
  `libpj-x86_64-apple-darwin.a`), which changes with every macOS update. The script installs
  them without it, so both architectures have the same names and can be merged with `lipo`.
- **Per-architecture headers.** configure records the machine (`PJ_M_NAME`, `PJ_OS_NAME`) in
  `pj/compat/m_auto.h` and `os_auto.h`; the universal include tree merges differing headers with
  `#if defined(__aarch64__)` / `#elif defined(__x86_64__)`. Any other difference between the
  architectures (different files, link libraries or consumer CFLAGS) stops the script.
- **Homebrew stays out.** Configure sees only `third_party/deps/<arch>` (`--with-ssl`,
  `--with-opus`, `PKG_CONFIG_LIBDIR`), and the script fails if `pjsua` links a `/opt/homebrew`
  dylib. Homebrew's archives would be arm64-only and built for the host macOS.
- **Consumers need `-DPJ_AUTOCONF=1`**, otherwise `pj/config.h` ignores the
  configure results. `CPJSUA.h` defines it before including `pjsua.h`.
- **libwebrtc (AEC) contains C++**, so the final link needs `-lc++`. It uses NEON on arm64 and
  SSE2 on x86_64.
- **Swift sees PJSIP headers only via `-Xcc -I`**: each Swift target that imports
  `CPJSUA` needs `swiftSettings: pjsipSwiftSettings` in `Package.swift`.
- **Universal Swift builds** (`--arch arm64 --arch x86_64`) put their products in
  `.build/out/Products/<Config>`, not `.build/<config>`; use `swift build ... --show-bin-path`.
- **Rosetta start-up.** An x86_64 `pjsua` under Rosetta 2 needs a few seconds before its telnet
  CLI answers; `selftest-call.sh` polls for up to ~15 s.
- `PJSUA_INVALID_ID` is a C enum constant; in Swift use `PJSUA_INVALID_ID.rawValue`.
