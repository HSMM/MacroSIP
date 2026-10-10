# Roadmap

Milestones 1–4 produce **MacroSIP Lite**. Milestones 5–6 produce **MacroSIP** (Full).
Owner's rule: work on milestones 5–6 starts only after Lite is released (`v0.1-lite` tagged).
A milestone is done only when every item in its "Done when" list holds.

## 1. Skeleton, PJSIP, mockups
- Repo, license, docs (this file, AGENTS, GLOSSARY, ADRs, CLAUDE.md).
- `scripts/build-pjsip.sh`: PJSIP 2.17 static arm64 with OpenSSL, Opus, SRTP, WebRTC AEC, no video. Also the `pjsua` CLI for tests.
- `CPJSUA` target and `pjsip-smoke` executable prove Swift links and runs pjsua.
- `MacroSIPCore` and `MacroSIPApp` targets exist; `scripts/make-app.sh lite|full` bundles a signed empty window into `dist/`.
- UI mockups for all screens published and approved by the owner.
- `docs/design/SCREENS.md`: text spec derived from the approved mockups — per screen: elements, states (empty, loading, error, Lite/Full), control behaviour, shortcuts, and every UI string for localization. Written by the technical writer; it is the UI engineer's primary input.
- Done when: `swift build` passes, smoke test prints codecs and devices, both `.app` bundles launch, mockups approved, SCREENS.md matches them, pushed to `main`.

## 2. Engine: registration and a call
- `Engine` actor owns the pjsua instance; thread-safe event stream to the UI.
- Account model, Keychain-backed credentials, simultaneous registration of enabled accounts.
- Outgoing and incoming calls, answer, hang up, mute, hold, DTMF. Audio device selection.
- Done when: a call between the app and `pjsua` CLI over UDP on localhost has two-way audio, and tests for models, storage and dial-string parsing are green.

## 3. Call and account UI, menu bar
- Main window per mockups: dial field with account picker, Dialpad tab, active-call panel, multiple-call rows.
- Incoming-call floating window and notification with Answer/Decline. Dock badge for missed calls.
- Account editor sheet; status bar with registration state per account; first-launch empty state.
- Menu bar item: state icon, per-account status, quick dial, last 5 calls, DND, Show, Quit. Closing the window keeps the app running.
- `sip:`/`sips:`/`tel:` URL handler.
- Done when: owner completes a real call on their own SIP account from the UI only.

## 4. History and contacts — Lite complete
- Call log with direction, time, duration, filter, clear; redial from a row.
- Contacts: search, add, edit, delete, call; call log resolves numbers to contact names.
- Blind and attended transfer.
- Settings window: General, Audio (three devices, ringtone, AEC), Network (transport, STUN, SRTP, port, keep-alive), Codecs (reorderable).
- Russian localization of everything so far.
- Done when: Lite `.app` passes a manual checklist on the owner's account; tagged `v0.1-lite`.

## 5. Full features: presence, conference, auto-answer, recording
- Presence subscribe per contact (dot in list) and publish own status; DND publishes `dnd`.
- Conference: Merge button mixes connected calls locally; split/hang up individually.
- Auto-answer modes and delay; `Call-Info answer-after` honoured.
- Recording: button and auto-record setting; WAV via PJSIP, converted to M4A with AVFoundation, WAV removed on success.
- Done when: each feature verified against the owner's server (presence may need server support; document if unsupported); tests for auto-answer rules green.

## 6. Full polish and release
- Settings panes Recording and Auto-answer; Full tags in UI where edition differs.
- Launch at login, language switch, crash-safe log file, About window with GPL notice.
- Russian localization complete; both editions bundled by `make-app.sh`; README install guide.
- Done when: tagged `v0.1`; both `.app` bundles built from a clean clone by following README only.

## Later (v2 candidates)
Video calls, SIP MESSAGE chat, global hotkeys, MicroSIP.ini / Contacts.xml import, notarized builds, Sparkle updates.
