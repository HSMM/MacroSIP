# Roadmap

Versions are `YY.MINOR.PATCH` (see [ADR 0011](adr/0011-versioning.md)); the current line is 26.0.

## 26.0 (release candidate out, final after real-PBX checks)

Shipped in `26.0.0-rc.1`:

- Accounts: several at once, UDP/TCP/TLS with certificate verification, SRTP, STUN, ICE, outgoing-only accounts, per-account on/off in the account pop-up.
- Calls: up to four, hold, mute, DTMF (RFC 2833 with SIP INFO fallback), blind and attended transfer, local conference, call recording to M4A (mono, or stereo with you on the left and the caller on the right), auto-answer with `Call-Info: answer-after` from your own PBX.
- Presence: watch contacts (Asterisk "on the phone" shown as busy) and publish your own status; Do Not Disturb.
- Contacts, call history, `sip:`/`sips:`/`tel:` links, menu bar icon, incoming-call window and notifications.
- English and Russian interface, launch at login, log file with rotation, diagnostics export.
- Distribution: DMG on GitHub Releases, Homebrew cask (`brew install --cask hsmm/tap/macrosip`), CI on every push.

Before `26.0.0` final:

- Verification on a production Asterisk/FreePBX: incoming calls, transfers, recording, conference, presence (needs hints and PUBLISH enabled on the server), auto-answer.
- Fixes from that round.

## 26.1 (next)

- Developer ID signing and notarization, so the first launch needs no workaround.
- In-app updates (Sparkle) and update notices from the Homebrew cask.
- Recording playback from the call log.
- Merge that includes held calls; recording notice tone.
- Conference and transfer polish from user feedback; keyboard shortcuts audit.
- Timed Do Not Disturb.

## Later

- Video calls.
- SIP MESSAGE chat.
- Global hotkeys (answer, hang up, mute).
- Import from MicroSIP (`MicroSIP.ini`, `Contacts.xml`) and from macOS Contacts.
- Bluetooth headset buttons (answer/hang up).
- Localizations beyond English and Russian (contributions welcome).

Issues and feature requests: https://github.com/HSMM/MacroSIP/issues
