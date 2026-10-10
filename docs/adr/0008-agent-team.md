# ADR 0008 — Agent team structure

Date: 2026-10-10. Status: accepted.

## Context
The project spans many sessions and mixes toolchain work, concurrency-heavy engine code, UI and docs. The owner asked for an explicit mapping of roles to models and effort levels.

## Decision
The table in `docs/AGENTS.md` is authoritative: Fable orchestrates; Opus at high or extra-high effort takes the PJSIP build, the engine, design and review; Sonnet takes UI, data, tests, research and verification; Haiku writes docs. UI code starts only after the owner approves the designer's mockups.

## Consequences
Briefs must be self-contained because sub-agents see only the brief. Reviews are done by an agent that did not write the code.
