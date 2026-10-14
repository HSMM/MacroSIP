# Roadmap

Versions are `YY.MINOR.PATCH` (see [ADR 0010](adr/0010-versioning.md)); the first release is 26.0.0.

## 26.0 (released 2026-10-14)

Shipped in `26.0.0`:

Accounts and network:

- Accounts: several at once, UDP/TCP/TLS with certificate verification, SRTP, STUN, ICE, outgoing-only accounts, per-account on/off in the account pop-up; search and a status summary for many accounts.
- Account editor: only name, server, username, password and Enabled visible; everything else under a collapsed Advanced group.
- Network pane: RTP port range, rport, DNS SRV with a custom nameserver.
- Network resilience: immediate re-registration on network change, wake and reconnect with backoff; calls survive an IP change through a re-INVITE; "No network" and "Reconnecting…" states in the status bar and the call panel.

Calls:

- Up to four calls, hold (with music for the caller: built-in melody, your own file, or off), mute, DTMF (RFC 2833 with SIP INFO fallback), blind and attended transfer, local conference; merge that includes held calls.
- Call recording to M4A (mono, or stereo with you on the left and the caller on the right); playback from the call log; an optional notice tone every N seconds that both sides hear.
- Auto-answer with `Call-Info: answer-after` from your own PBX.
- Call options: single-call mode (a second incoming call gets 486 Busy while you are on a call), or call waiting with a short tone in the earpiece, or the window only (one three-way setting).
- DTMF method: automatic (RFC 2833, then SIP INFO), RFC 2833 only, SIP INFO only, in-band.
- Bring the main window to the front on an incoming call (switch).
- Deny incoming: everyone, callers not in Contacts, anonymous callers.
- Do Not Disturb, also timed (30 min, 1 h, until tomorrow 9:00).

Audio and codecs:

- Call-quality indicator from RTCP (loss, jitter, RTT, MOS estimate) with a "poor connection" notice.
- Speaker and microphone volume per call; ringtone volume.
- Opus packet-loss correction (FEC) and silence suppression (DTX) switches.
- Automatic switch to a headset when it is connected, and back when it is removed; USB headset buttons (answer, hang up, mute, redial) with indicator lights.
- Audio test (tone on the chosen speaker, microphone meter); sound events for connected and ended calls, dial pad keys, new voicemail and errors.
- System voice processing (noise suppression, automatic gain) through VoiceProcessingIO with the default devices; a chosen non-default device uses the built-in echo canceller.
- Codecs: Opus, G.722, G.711 and, off until turned on, G.722.1, GSM, iLBC, Speex. No G.729.

Contacts, presence and the directory:

- Contact card: photo, favorite, first and last name, organization, several numbers with labels and a default, email, notes; Favorites section first in Contacts; sort by first or last name; call log matches any number; macOS Contacts import fills the card.
- Presence: watch contacts (Asterisk "on the phone" shown as busy) and publish your own status.
- Directory of users: LDAP, a URL (CSV/JSON), Google Contacts (OAuth sign-in; the build needs the owner's Google Cloud client id) and the macOS Contacts app; suggestions in the number field after 2 characters; incoming callers looked up by number (1 s limit); search-only or import into Contacts per source.
- Quick keys: up to 12 speed-dial/BLF keys in a side panel (right) or docked at the bottom, off by default; types Call, DTMF, Blind transfer, Attended transfer, Add to conference and the smart Call/… variants; BLF dots from the presence subscription; a click on a ringing key dials the pickup code plus the number; ⌘1–⌘9; configured in Settings › Quick keys.
- Call log, `sip:`/`sips:`/`tel:` links, menu bar icon, incoming-call window and notifications.
- Voicemail indicator (MWI) per account with a badge in the status bar and a one-click call to the voicemail number.

App:

- Interface in English and Russian, launch at login, log file with rotation, diagnostics export.
- In-app updates (Sparkle 2, EdDSA-signed appcast on the `gh-pages` branch; release candidates on the beta channel).
- Universal build: one app and one DMG for Apple Silicon and Intel Macs; PJSIP, OpenSSL and Opus built for both architectures from pinned sources.
- Distribution: DMG on GitHub Releases, Homebrew cask (`brew install --cask hsmm/tap/macrosip`), CI on every push.

`26.0.1` (2026-10-14): the interface ships in English and Russian only; the other localizations of 26.0.0 are removed.

## Later

- Developer ID signing and notarization, so the first launch needs no workaround (when the signing identity is available).
- Video calls.
- SIP MESSAGE chat.
- Global hotkeys (answer, hang up, mute).
- Import from MicroSIP (`MicroSIP.ini`, `Contacts.xml`).

Issues and feature requests: https://github.com/HSMM/MacroSIP/issues
