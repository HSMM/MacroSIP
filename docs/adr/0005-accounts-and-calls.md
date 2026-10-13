# ADR 0005 — Simultaneous accounts, in-window calls, floating incoming window

Date: 2026-10-10. Status: accepted.

## Context
MicroSIP registers one account at a time. macOS users expect background apps to keep receiving calls.

## Decision
All enabled accounts register at once; one is the default for outgoing calls and a picker next to the dial field overrides it per call. Active calls are shown as a panel inside the main window; several calls are listed with one active and the rest held. An incoming call opens a small floating always-on-top window and posts a macOS notification with Answer/Decline. Closing the main window hides it; the app keeps running from the menu bar. Missed calls set the Dock badge. The app registers for `sip:`, `sips:` and `tel:` URLs. Network defaults for internet providers behind NAT: UDP, STUN on, rport, keep-alive 15 s.

## Consequences
The engine must route incoming calls by account and keep per-call state. A corporate LAN server may need STUN turned off in Network settings.
