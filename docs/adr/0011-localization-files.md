# ADR 0011 — Localization with .strings files

Date: 2026-10-12. Status: accepted. Refines ADR 0001 ("String Catalogs from day one").

## Context
The project builds with SwiftPM and Command Line Tools only. `.xcstrings` catalogs need `xcstringstool`, which is part of Xcode (`xcrun --find xcstringstool` fails here), so SwiftPM cannot compile them.

## Decision
UI strings live in classic `Localizable.strings` plus `Localizable.stringsdict` (plural forms) under `Sources/MacroSIPApp/Resources/<lang>.lproj` (en, ru, be, uk, pl, de, fr, it, es, hi, zh-Hans), processed by SwiftPM (`defaultLocalization: "en"`, `resources: [.process("Resources")]`). All lookups go through `L` in `Strings.swift` with `bundle: .module`. `scripts/check-strings.sh` keeps code and every language in sync. Moving to a catalog later means importing these files; keys stay the same.

## Consequences
Strings are not auto-extracted: a new string needs its key in `L` and in every `.strings` file. The language follows `AppleLanguages`, which Settings › General writes.
