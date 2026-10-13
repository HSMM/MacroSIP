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
- **Quick key** — one of up to 12 configurable buttons in the quick-keys panel. A key has a name, a number, a type (Call, DTMF, Blind transfer, Attended transfer, Add to conference, or a smart variant) and an optional BLF dot.
- **BLF (busy lamp field)** — the line-state dot of a watched number: available, on the phone, ringing, no information. It uses the same presence subscription as a contact with "Watch presence".
- **Directory source** — a place to look up people by name from the number field: LDAP, a URL (CSV or JSON), Google Contacts or macOS Contacts. Each source is either search only or imported into Contacts.
- **Favorite** — a contact marked with the star; favorites form the first section of the Contacts list and also stay in their letter section.
- **Smart key** — a quick key that calls when there is no call and performs a transfer or conference action on the active call when there is one (Call / Blind transfer, Call / Attended transfer, Call / Conference).
- **Pickup code** — the feature code (default `*8`) dialled together with a ringing key's number to answer that line's call, for example `*8101`.
- **Call quality (MOS)** — the real-time estimate of a call's audio quality from RTCP statistics (loss, jitter, round-trip time); MOS is the mean opinion score, 1 to 5. A low value shows the "poor connection" notice.
- **Headset follow** — the automatic switch of the audio devices to a headset when it is connected, and back when it is removed.
- **Reconnecting** — the state of an account or call while the app restores registration after a network drop, an IP change or sleep. Accounts show "retry in N s"; calls keep their timer and show "Reconnecting… N s".
- **Advanced (account editor)** — the collapsible section of the account editor with the rarely changed fields: display name, auth username, domain, proxy, transport, SRTP, registration expiry, certificate verification and the register, default and presence switches.
- **Product** — one build, `MacroSIP`, bundle id `com.hsmm.macrosip` (ADR 0003).
- **Engine** — the Swift layer in `MacroSIPCore` that owns the single pjsua instance and exposes accounts, calls and events to the UI.
