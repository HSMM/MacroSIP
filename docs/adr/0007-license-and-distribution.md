# ADR 0007 — GPLv2+, public repository, ad-hoc signing

Date: 2026-10-10. Status: accepted.

## Context
PJSIP is GPLv2 or later. The owner created the public repository github.com/HSMM/MacroSIP and has no Apple Developer account.

## Decision
MacroSIP is licensed GPLv2 or later. Builds are signed ad hoc; users build from source or remove the quarantine attribute from a downloaded bundle. Work is committed after each milestone and pushed to `main`. Notarization is a v2 option.

## Consequences
First launch shows the unidentified-developer dialog. Any bundled third-party code must be GPL-compatible.
