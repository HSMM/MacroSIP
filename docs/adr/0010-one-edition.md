# ADR 0010 — One edition

Date: 2026-10-12. Status: accepted. Supersedes ADR 0003.

## Context
ADR 0003 split the product into Lite and Full builds from one codebase, with the owner's rule that Full-only work waits for a Lite release. On 2026-10-12, after the first successful real call, the owner decided: "lite больше не будет" — there is no Lite edition.

## Decision
MacroSIP is one product and one build: `MacroSIP.app`, bundle id `com.hsmm.macrosip`, product name "MacroSIP". The `FULL` compile flag, the `Edition` type, the `lite|full` arguments of `make-app.sh` and `test.sh`, and the second test run are removed. Presence, recording, auto-answer and conference are ordinary features (milestone 5). `[Full]` markers in `docs/design/SCREENS.md` are kept as historical labels for those features; `[v2]` markers still mean "not now".

Storage is unaffected: the Keychain service was already `com.hsmm.macrosip` and the JSON directory is `MacroSIP` regardless of bundle id, so accounts entered in the Lite test build carry over.

## Consequences
Simpler scripts and tests; no feature gating in UI code. The Lite bundle id `com.hsmm.macrosip.lite` is retired; anyone who ran the Lite build should delete the old `.app` (settings and accounts survive).
