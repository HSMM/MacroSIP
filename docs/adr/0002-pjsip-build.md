# ADR 0002 — PJSIP 2.17 built statically by a script

Date: 2026-10-10. Status: accepted.

## Context
PJSIP is the engine MicroSIP uses and the only mature open SIP stack with a C API usable from Swift. The repository must stay light and reproducible.

## Decision
`scripts/build-pjsip.sh` downloads the 2.17 tarball, verifies a pinned SHA-256, applies `third_party/pjsip/config_site.h` and builds static arm64 libraries with: OpenSSL 3 from Homebrew (TLS, SRTP via bundled libsrtp), Opus from Homebrew, built-in G.711 and G.722, WebRTC AEC, CoreAudio backend, video disabled. The `pjsua` CLI is built too and used as a second phone in tests. Build outputs are git-ignored. Swift reaches PJSIP only through the `CPJSUA` target.

## Consequences
First build takes minutes; later builds are cached. Upgrading PJSIP means changing the version and hash in one script. Video is a v2 decision that will need a new ADR.

Superseded in part by ADR 0012 (universal build; OpenSSL and Opus from pinned sources).
