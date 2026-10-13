# ADR 0003 — Product scope

Date: 2026-10-10. Status: accepted.

## Context
MicroSIP sets the expectation for what a small desk-phone replacement should do. MacroSIP has no video, so the line between "in" and "later" is drawn by how much a feature adds to day-to-day calling on a PBX.

## Decision
One product, one build. The first release ships: accounts with simultaneous registration, calls with DTMF, mute, hold, blind and attended transfer, local conference, call recording (M4A, mono or stereo), auto-answer, presence (subscribe and publish), call history, contacts, the menu bar item, audio and network settings, `sip:`/`sips:`/`tel:` links, English and Russian. Video, SIP MESSAGE chat, global hotkeys and MicroSIP import are later releases (see `docs/ROADMAP.md`).

## Consequences
Every feature in the list above must work against a real PBX before the release is tagged. Anything outside the list is an issue for the roadmap, not a build flag.
