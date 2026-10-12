# Agent team

MacroSIP is built by an orchestrator and a set of specialised sub-agents. The owner
approved this table on 2026-10-10. Change it with a new ADR.

| Role | Model | Effort | Owns | Why this model |
|---|---|---|---|---|
| Orchestrator and architect | Fable 5.1 (main session) | session default | Milestone plans, module boundaries, pjsua bridge design, briefs for every other role, integration, final acceptance, commits and pushes | Holds the full decision context; one place for the expensive context |
| PJSIP build engineer | Opus | high | `scripts/build-pjsip.sh`, `config_site.h`, linking against OpenSSL/Opus, `CPJSUA` module and shim, `make-app.sh` and ad-hoc signing | Toolchain work with opaque link errors needs a strong model |
| SIP engine engineer | Opus | xhigh | `MacroSIPCore`: accounts, calls, transfer, conference, presence, recording, auto-answer; thread-safety of PJSIP callbacks | Highest-risk code: foreign-thread C callbacks, object lifetimes, leaks |
| UI designer | Opus | high | HTML mockups of every screen as a published Artifact, light and dark; iterates until the owner approves | Visual judgement; the owner reviews before any UI code |
| UI engineer | Sonnet | high | SwiftUI/AppKit views: main window, call panel, incoming window, menu bar, settings, account sheet; wiring to the engine; String Catalog entries | Well-specified from mockups; large volume of regular code |
| Data and tests engineer | Sonnet | medium | Models, JSON store, Keychain wrapper, dial-string/URI parsing, auto-answer rules, Swift Testing suites | Clear contracts; cost-effective |
| Researcher | Sonnet | low | PJSIP API lookups, function signatures, build-error archaeology in pjproject issues | Short factual tasks |
| Technical writer | Haiku | low | README, docs upkeep, ADR formatting from orchestrator notes, code comments | Reformatting existing content |
| Reviewer | Opus | high | Independent review of each milestone (`/code-review`): bugs, races, leaks, Keychain and TLS handling. Receives the code, not the orchestrator's conclusions | An unanchored second opinion |
| Verifier | Sonnet | low | `swift build`, `swift test`, launching `pjsua` as the second phone, placing the test call, collecting logs | Mechanical checks |

## Working agreement per milestone
1. Orchestrator writes a brief: goal, boundaries, files, done criteria, facts already known.
2. Independent tasks run in parallel (for example PJSIP build and data models).
3. Verifier checks the result, then Reviewer reviews. Fixes go back to the original engineer through a follow-up message so context is kept.
4. Orchestrator accepts, commits, pushes.

## Decision rights
- Product decisions belong to the owner. Agents ask through the orchestrator instead of assuming.
- Facts (APIs, paths, versions) are looked up by agents, never asked of the owner.
