# ADR 0009 — UI decisions from the mockup review

Date: 2026-10-10. Status: accepted.

## Context
The designer delivered mockups for all ten screens (`docs/design/mockups.html`) with open questions. The owner reviewed and approved them with the decisions below.

## Decisions
- Main window stays ~340×520 during a call. The active-call panel replaces the dialpad inside the Dialpad tab; "Keypad" swaps in a DTMF keypad. Other tabs remain usable during a call and show a compact call summary bar.
- Transport and SRTP are configured only per account. Settings › Network holds STUN server, local port, keep-alive and ICE. Echo cancellation lives in Settings › Audio.
- Settings has an Accounts pane: list with live status, add/remove/edit, last error with Retry. Account editor has an "Account name" label, a "Test" button that registers without saving, separate auth username and registration expiry; no voicemail number.
- Incoming call: floating always-on-top window only when the main window is not visible; otherwise shown inside the main window. Notification style: alert. While on a call, a second incoming offers "Hold & Answer" and "End Current & Answer". Decline sends 486.
- At most 4 simultaneous calls.
- Transfer popover: "Transfer Now" (blind) and "Call First" (attended), finishing with a "Complete Transfer" banner.
- Dial field: typed letters show contact suggestions in a dropdown; empty field + Call redials the last number.
- Call log keeps the last 1,000 entries. Contacts have an optional preferred account.
- Menu bar: native NSMenu. No timed DND. (Full: "My Status" submenu synced with DND.)
- Settings › General: launch at login, language, URL handler with "ask before calling", keep running in menu bar when window closed, show icon in Dock. Microphone permission is requested on the first call.
- Codecs pane shows only Opus, G.722, PCMU, PCMA.
- Not in v1: macOS Contacts import, MicroSIP .ini import, global hotkeys, volume controls in the call panel, first-run launch-at-login prompt.
- Deferred to a later release: recording play button in the log, Merge including held calls, recording notice.

## Consequences
`docs/design/SCREENS.md` is derived from the updated mockups and these decisions; UI code follows both.
