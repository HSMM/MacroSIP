# ADR 0012 — Universal build; OpenSSL and Opus from pinned sources

Date: 2026-10-12. Status: accepted. Supersedes the dependency and architecture parts of ADR 0002;
extends ADR 0001 to Intel Macs.

## Context
The owner wants MacroSIP on Intel Macs too, as one download. ADR 0002 built PJSIP for arm64 only and
linked OpenSSL and Opus from Homebrew, which on an Apple Silicon Mac provides arm64 archives only,
built for the host macOS (the linker warned about the newer deployment target).

## Decision
One universal app (arm64 + x86_64) and one DMG, `MacroSIP-<version>.dmg`. `scripts/build-pjsip.sh`
builds OpenSSL 3.5 (LTS) and Opus from source tarballs with pinned SHA-256 for both architectures
(macOS 14.0 deployment target), then PJSIP 2.17 natively for arm64 and cross-compiled for x86_64
with the same `config_site.h`, and merges each archive with `lipo`. `Package.swift` links only these
archives; Homebrew is no longer a build dependency. Release builds of the app are universal
(`swift build --arch arm64 --arch x86_64`); debug builds stay native. The build host is an Apple
Silicon Mac; CI also runs the tests on an Intel runner and the self-test of the x86_64 slice under
Rosetta 2.

## Consequences
The first dependency build takes longer (OpenSSL twice); later runs skip every component whose
recipe is unchanged. Upgrading OpenSSL or Opus means changing a version and a checksum in the
script, like PJSIP. The app is about twice as large. Intel support ends when Apple's toolchain or
GitHub's Intel runners do; dropping it is a new ADR.
