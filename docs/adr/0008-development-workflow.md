# ADR 0008 — Development workflow

Date: 2026-10-10. Status: accepted.

## Context
The project spans toolchain work, concurrency-heavy engine code, UI and documentation, and is developed in milestones by a small team.

## Decision
Work is organised by the milestones in `docs/ROADMAP.md`. Each task starts from a written brief: goal, boundaries, files, done criteria and the facts already known. Independent tasks run in parallel. Every milestone gets an independent review (bugs, races, leaks, Keychain and TLS handling) by someone who did not write the code, followed by verification: build, tests, the loopback self-test call and a call on the owner's SIP account. UI code starts only after the owner approves the mockups.

## Consequences
Briefs must be self-contained. Review findings go back to the original author; coordinating fixes, acceptance and commits is the maintainer's job.
