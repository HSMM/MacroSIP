# Roadmap

One product, **MacroSIP** (ADR 0010; the Lite/Full split was dropped on 2026-10-12).
Milestones 4 and 5 run in parallel; 6 is the release. A milestone is done only when every item in its "Done when" list holds.

## 1. Skeleton, PJSIP, mockups — DONE 2026-10-10
- Repo, license, docs (this file, GLOSSARY, ADRs, DEVELOPMENT.md).
- `scripts/build-pjsip.sh`: PJSIP 2.17 static arm64 with OpenSSL, Opus, SRTP, WebRTC AEC, no video. Also the `pjsua` CLI for tests.
- `CPJSUA` target and `pjsip-smoke` executable prove Swift links and runs pjsua.
- `MacroSIPCore` and `MacroSIPApp` targets exist; `scripts/make-app.sh lite|full` bundles a signed empty window into `dist/`.
- UI mockups for all screens published and approved by the owner.
- `docs/design/SCREENS.md`: text spec derived from the approved mockups — per screen: elements, states (empty, loading, error, Lite/Full), control behaviour, shortcuts, and every UI string for localization. It is the primary input for UI work.
- Done when: `swift build` passes, smoke test prints codecs and devices, both `.app` bundles launch, mockups approved, SCREENS.md matches them, pushed to `main`.

## 2. Engine: registration and a call — DONE 2026-10-10 (reviewed, 36 tests, selftest call)
- `Engine` actor owns the pjsua instance; thread-safe event stream to the UI.
- Account model, Keychain-backed credentials, simultaneous registration of enabled accounts.
- Outgoing and incoming calls, answer, hang up, mute, hold, DTMF. Audio device selection.
- Done when: a call between the app and `pjsua` CLI over UDP on localhost has two-way audio, and tests for models, storage and dial-string parsing are green.

## 3. Call and account UI, menu bar — DONE 2026-10-11 (owner's real call: registration 200 OK, 41 s outgoing call, Opus, hold/resume)
- Main window per mockups: dial field with account picker, Dialpad tab, active-call panel, multiple-call rows.
- Incoming-call floating window and notification with Answer/Decline. Dock badge for missed calls.
- Account editor sheet; status bar with registration state per account; first-launch empty state.
- Menu bar item: state icon, per-account status, quick dial, last 5 calls, DND, Show, Quit. Closing the window keeps the app running.
- `sip:`/`sips:`/`tel:` URL handler.
- Done when: owner completes a real call on their own SIP account from the UI only.
- Diagnostic closed 2026-10-12: the "Unsuitable transport selected (PJSIP_ETPNOTSUITABLE), will try next server" line before every INVITE was PJSIP's RFC 3261 §18.1.1 switch of requests ≥ 1300 bytes (any INVITE with a digest Authorization header) to TCP, which cannot succeed on an account pinned to UDP. Fixed by disabling the TCP switch (`disable_tcp_switch`); reproduced and covered by self-test step 25. Details in docs/ENGINE.md.

## 4. History, contacts, settings, localization — IN PROGRESS
- Call log with direction, time, duration, filter, clear; redial from a row.
- Contacts: search, add, edit, delete, call; call log resolves numbers to contact names.
- Blind and attended transfer.
- Settings window: General, Audio (three devices, ringtone, AEC), Network (transport, STUN, SRTP, port, keep-alive), Codecs (reorderable).
- Russian localization of everything so far: done 2026-10-12 (`Localizable.strings` and `.stringsdict` per language in `Sources/MacroSIPApp/Resources`; `scripts/check-strings.sh`; ADR 0012).
- Follow-ups from the engine review: switch the UI to the name-based audio device API (`setAudioDevices(inputName:outputName:)`, `setRingtoneDevice(name:)`), add the "Verify server certificate" toggle (`verifyTLSCertificate`) to the account editor, write the "Rejected: call limit" log note for an auto-rejected fifth call.
- Self-test (2026-10-12) covers incoming call, 486 reject, blind and attended transfer, DTMF over SIP INFO, and the ≥1300-byte INVITE regression against a local registrar stub.
- Owner's checklist on the real account: incoming call (floating window, ringtone, answer), DTMF to an IVR, blind and attended transfer.
- Done when: the `.app` passes the manual checklist on the owner's account.

## 5. Presence, conference, auto-answer, recording — CODE DONE 2026-10-12 (reviewed, 65 tests, selftest incl. recording/M4A, presence, two-leg conference); awaiting the owner's server check
Engine (`MacroSIPCore`, replaces the `.unsupported` stubs):
- Presence: `subscribePresence(uri:)` / `unsubscribePresence(uri:)` over pjsua buddies, `.buddyPresence` events; `publishPresence(_:for:)` via PUBLISH (RPID) for accounts with `publishPresence`; DND publishes `dnd`.
- Conference: `merge(_:)` connects every listed call's conference port pairwise plus mic/speaker, `split(_:)` takes one call out; `CallInfo.inConference` reflects it; hold/mute keep working per leg.
- Recording: `startRecording(_:to:)` / `stopRecording(_:)` with `pjsua_recorder` on the call's conference port (both directions); `CallInfo.isRecording`. `RecordingConverter` (AVFoundation) turns the WAV into M4A/AAC and deletes the WAV on success.
- Auto-answer rules: pure `AutoAnswerPolicy.decide(call:isContact:settings:onAnotherCall:dnd:) -> delay?`; `Call-Info: answer-after=N` parsed from the INVITE into `CallInfo.answerAfter`.
UI (`MacroSIPApp`, per SCREENS.md `[Full]` rows): presence dot/text and "Watch presence" (contacts), Record button and REC chip, Merge/Split and the conference screen 5.4, auto-answer strip 6.5 with countdown and Cancel, My Status submenu 7.4, Settings panes Recording 8.6 and Auto-answer 8.7, "Publish my presence" in the account editor, recordings sentence in the clear-log alert. Settings model: `AppSettings.recording`, `AppSettings.autoAnswer`.
- Security rule from the review: `Call-Info: answer-after` is honoured only when the INVITE comes from the address that answered the account's REGISTER (same transport and IP; same port over UDP); anything else is logged and ignored.
- Done when: `scripts/selftest-call.sh` also covers recording (WAV produced, M4A conversion) and presence against `pjsua`; conference verified with two `pjsua` legs; auto-answer policy tests green (all true since 2026-10-12); each feature then checked on the owner's server (presence may need server support; document if unsupported).

## 6. Polish and release
Release order (owner, 2026-10-12): tag `26.0.0-rc.1` as soon as localization, CI and the Homebrew tap are in place; the owner's checks on the real PBX run on the RC and feed the `26.0.0` final.
- Launch at login (SMAppService, real status shown): done 2026-10-12. Language switch (AppleLanguages, restart prompt): done. Crash-safe log file `~/Library/Logs/MacroSIP/MacroSIP.log` with rotation, Open Log Folder, Copy Diagnostics: done. About panel with GPL notice: done.
- App icon (`scripts/make-icon.swift` -> `packaging/AppIcon.icns`): done. DMG (`scripts/make-dmg.sh`): done. CI and release workflows, Homebrew cask in `HSMM/homebrew-tap` (`scripts/update-cask.sh`): written, not yet run on GitHub (needs the tap repository and the `TAP_TOKEN` secret, see README "Releasing").
- Russian localization: done 2026-10-12 (all UI strings, plural forms, microphone prompt; language switch verified with a relaunch). Owner to proofread the wording. README install guide (Homebrew, DMG): done.
- Done when: tagged `26.0.0`; `MacroSIP.app` built from a clean clone by following README only.

## Later (v2 candidates)
Video calls, SIP MESSAGE chat, global hotkeys, MicroSIP.ini / Contacts.xml import, notarized builds, Sparkle updates.
