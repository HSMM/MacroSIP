# Glossary

Shared vocabulary for MacroSIP. Code identifiers follow these names.

- **Account** — one SIP identity (user, domain, registrar, credentials, transport). Several accounts may be enabled and registered at once. One account is the **default outgoing account**.
- **Registration** — the account's REGISTER state with the server: `unregistered`, `registering`, `registered`, `failed(reason)`.
- **Transport** — how SIP signalling travels: UDP, TCP or TLS. **SRTP** encrypts media and is independent of the signalling transport; modes are `disabled`, `optional`, `mandatory`.
- **Call** — one SIP dialog with a remote party. States: `incoming`, `outgoing` (ringing on the far end), `early`, `connected`, `held`, `disconnected`. Exactly one connected call is **active** (sending and receiving audio); others are held.
- **Remote party** — the display name and SIP URI of the other side of a call.
- **Dial string** — what the user typed; it is resolved to a SIP URI using the outgoing account's domain.
- **DTMF** — keypad tones sent during a call (RFC 2833 preferred, SIP INFO fallback).
- **Blind transfer** — REFER the current call to a new target without talking to the target first.
- **Attended transfer** — call the target first, then REFER with Replaces so the two remote parties are joined.
- **Conference** — local mixing of two or more connected calls on this machine through the PJSIP conference bridge. Not a server-side conference.
- **Presence** — SIP SIMPLE status. **Subscribe** watches a contact's status; **publish** sends our own status (`available`, `away`, `dnd`).
- **DND (Do Not Disturb)** — incoming calls are rejected with 486 Busy; in Full, presence publishes `dnd`.
- **Auto-answer** — incoming call is answered automatically after a delay. Modes: `off`, `all`, `contactsOnly`. A server `Call-Info; answer-after=N` header is honoured when enabled.
- **Recording** — capture of an active call to WAV by PJSIP, converted to M4A afterwards.
- **Contact** — a saved name and number with optional presence subscription flag.
- **Call log entry** — one historical call: direction (`incoming`, `outgoing`, `missed`), remote party, account, start time, duration.
- **Product** — one build, `MacroSIP`, bundle id `com.hsmm.macrosip` (the Lite/Full split was dropped on 2026-10-12, ADR 0010).
- **Engine** — the Swift layer in `MacroSIPCore` that owns the single pjsua instance and exposes accounts, calls and events to the UI.
