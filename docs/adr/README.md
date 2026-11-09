# Architecture decision records

One file per decision, numbered, never edited after acceptance except to add a
"Superseded by" line. Format: Context, Decision, Consequences.

| ADR | Decision |
|---|---|
| [0001](0001-platform-and-ui-stack.md) | macOS 14+, Swift/SwiftUI, SwiftPM without Xcode |
| [0002](0002-pjsip-build.md) | PJSIP 2.17 built statically by a script |
| [0003](0003-product-scope.md) | Product scope |
| [0004](0004-storage.md) | JSON files plus Keychain, no MicroSIP import in v1 |
| [0005](0005-accounts-and-calls.md) | Simultaneous accounts, in-window calls, floating incoming window |
| [0006](0006-quality-and-testing.md) | Tests, verification and the pjsua second phone |
| [0007](0007-license-and-distribution.md) | GPLv2+, public repository, ad-hoc signing |
| [0008](0008-development-workflow.md) | Development workflow |
| [0009](0009-ui-decisions.md) | UI decisions from the mockup review |
| [0010](0010-versioning.md) | Version numbers |
| [0011](0011-localization-files.md) | Localization with .strings files |
| [0012](0012-universal-build.md) | Universal build; OpenSSL and Opus from pinned sources |
| [0013](0013-in-app-updates-sparkle.md) | In-app updates with Sparkle |
| [0014](0014-ipv6-dual-stack.md) | IPv6 dual stack: IPv6 twins of every transport, per-account IP protocol |
