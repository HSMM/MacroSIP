# ADR 0010 — Version numbers

Date: 2026-10-12. Status: accepted.

## Context
The owner wants release numbers that read like macOS releases rather than a `0.x` series.

## Decision
Versions are `YY.MINOR.PATCH`: `YY` is the two-digit year of the release line (26 for 2026), `MINOR` grows with feature releases within the year, `PATCH` with fixes. The first release is `26.0.0`. Git tags carry the bare number (`26.0.0`), `make-app.sh` derives `CFBundleShortVersionString` from `git describe`, and `Product.version` holds the same number for the SIP `User-Agent` header.

## Consequences
`v0.1`-style references are gone. A release in 2027 starts the `27.0.0` line even if it would otherwise be a minor bump.
