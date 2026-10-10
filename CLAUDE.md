# MacroSIP — notes for Claude Code

MicroSIP-style SIP softphone for macOS 14+ on Apple Silicon. Swift 6, SwiftUI/AppKit,
SwiftPM only (no Xcode project), PJSIP 2.17 linked statically through the `CPJSUA` C target.

## Read first
- `docs/ROADMAP.md` — milestones and their done criteria. Work on the current milestone only.
- `docs/AGENTS.md` — who does what: roles, models, effort levels. Delegate by this table.
- `docs/GLOSSARY.md` — shared vocabulary. Use these terms in code and docs.
- `docs/adr/` — settled decisions. Do not reopen them silently; add a new ADR to change one.
- `docs/design/mockups.html` — approved UI mockups; `docs/design/SCREENS.md` — their text spec (elements, states, strings). UI code follows both.

## Layout
- `Sources/CPJSUA` — C shim and umbrella header over pjsua. The only place that includes PJSIP headers.
- `Sources/MacroSIPCore` — Swift engine: accounts, calls, presence, recording, storage. No UI imports.
- `Sources/MacroSIPApp` — SwiftUI/AppKit app. Edition features are gated with `#if FULL`.
- `Tests/` — Swift Testing (`import Testing`) for Core; XCTest is unavailable with Command Line Tools only.
- `scripts/` — `build-pjsip.sh`, `make-app.sh`. `third_party/` holds the PJSIP build (git-ignored except `pjsip/config_site.h`).

## Rules
- Two editions, one codebase: Lite is the default build; Full adds `-D FULL`. Never fork UI files per edition.
- Owner's rule (2026-10-10): no Full-only code is written until Lite is released and tagged `v0.1-lite`. Until then `#if FULL` blocks may exist only as empty stubs needed to compile.
- PJSIP callbacks arrive on PJSIP worker threads. Hop to the main actor before touching app state; never block a PJSIP thread on the main actor.
- Every `pjsua_*` call that can fail returns `pj_status_t`; check it and surface the error text via `pj_strerror`.
- Passwords live only in Keychain. Everything else is JSON in `~/Library/Application Support/MacroSIP/`.
- Strings go through String Catalogs; English is the base, Russian is maintained alongside.
- Run tests with `scripts/test.sh` and `scripts/test.sh full`, never bare `swift test` (it cannot find the Testing macro plugin under Command Line Tools). A milestone is done only after: `swift build` clean, both test runs green, and a real call verified (pjsua CLI as the second phone, or the owner's SIP account).
- Commit after each working milestone and push to `main`. Commit messages end with the Co-Authored-By line required by the session.
- SwiftUI `@State` does not compile under Command Line Tools (its macro plugin ships only with Xcode). Use the `@Local` wrapper from `Sources/MacroSIPApp/Views/Components/Local.swift`; it is a drop-in for `@State`.
- Opus and OpenSSL are linked as static archives from Homebrew (Package.swift) so the .app has no /opt/homebrew dylib dependencies; never switch them back to `.linkedLibrary`.
- Debug builds accept `--mock-engine`, `--demo-state <name>`, `--data-dir <path>`, `--snapshot <prefix>`; see `Sources/MacroSIPApp/Model/LaunchOptions.swift`. Demo launches use a temp data dir and never touch the real Keychain.
- Do not add dependencies without an ADR.
