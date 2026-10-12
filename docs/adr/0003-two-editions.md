# ADR 0003 — Lite and Full editions from one codebase

Date: 2026-10-10. Status: superseded by ADR 0010 (2026-10-12).

## Context
MicroSIP ships Lite and full builds. The owner wants the same split. MacroSIP has no video, so the line is drawn by feature weight instead.

## Decision
Lite: accounts with simultaneous registration, calls, DTMF, mute, hold, blind and attended transfer, history, contacts, menu bar, audio and network settings. Full adds presence (subscribe and publish), recording (WAV then M4A), auto-answer (off/all/contacts, delay, Call-Info), local conference. Full-only code is compiled under `#if FULL`; `make-app.sh lite|full` produces "MacroSIP Lite.app" and "MacroSIP.app" with distinct bundle identifiers and icons. UI files are never duplicated per edition. Lite ships first (milestone 4), Full after milestone 6.

## Consequences
Every Full feature must degrade cleanly to "absent" in Lite, including settings panes and menu items. Tests run for both flag states.
