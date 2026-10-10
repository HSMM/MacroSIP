# ADR 0001 — macOS 14+, Swift/SwiftUI, SwiftPM without Xcode

Date: 2026-10-10. Status: accepted.

## Context
MicroSIP is C++/MFC and cannot be ported. The machine has only Command Line Tools, no Xcode. The owner wants a native-feeling macOS app for Apple Silicon.

## Decision
Swift 6 with SwiftUI and AppKit where SwiftUI falls short (menu bar item, floating incoming window). Build with SwiftPM only; `scripts/make-app.sh` turns the executable into an `.app` bundle with Info.plist, entitlements and an ad-hoc signature. Minimum macOS 14 for mature SwiftUI and `@Observable`. Base language English, Russian localization through String Catalogs from day one.

## Consequences
No Xcode project to maintain; no Interface Builder. Debugging UI is done by running the bundle. If Xcode is installed later, `swift package generate-xcodeproj` is not needed; Xcode opens `Package.swift` directly.
