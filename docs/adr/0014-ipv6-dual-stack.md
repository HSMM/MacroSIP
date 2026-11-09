# ADR 0014 — IPv6 dual stack

Date: 2026-11-09. Status: accepted. Issue [#11](https://github.com/HSMM/MacroSIP/issues/11), release 26.3.1.

## Context
PJSIP is built with `PJ_HAS_IPV6 1` (ADR 0002), but up to 26.3.0 the engine created IPv4 transports
only and bound every account to one of them (`transport_id`). An account whose registrar or proxy is
an IPv6 literal could therefore never register and was retried forever, a host name with only an AAAA
record could not be reached, and media was IPv4 only. Users want servers reachable over IPv6: a PBX
by IPv6 literal, a host name with AAAA records, a dual-stack server on an IPv6-capable network.

Binding fixes the family: `pjsua_init_tpselector` turns `transport_id` into a TRANSPORT selector
(UDP) or a LISTENER selector (TCP/TLS), and pjsua's own IP version preference (`ipv6_sip_use`) only
applies to unbound accounts. Unbinding is not an option: it changes Contact and Via under STUN and
loses the choice between the verifying and the non-verifying TLS listener (milestone 2.1, 26.2).

## Decision
- **Full dual stack.** Every SIP transport gets an IPv6 twin (UDP6, TCP6, TLS6 verifying and
  non-verifying) on the same configured port (pjlib sets `IPV6_V6ONLY`, so both families can hold
  it). Each account is bound to the transport of its family. IPv6 transports are never fatal: a Mac
  may have no IPv6; accounts that need a missing transport are refused with `transportUnavailable`.
  A bind address of one family creates only that family's transports.
- **Per-account setting** "IP protocol" in the account editor's Advanced group: Auto (default),
  IPv4 only, IPv6 only (`AccountConfig.ipProtocol`; older files decode as Auto).
- **Auto** looks at the first hop (outbound proxy, else registrar): an IP literal picks its own
  family; a host name follows the first address the system resolver returns (`getaddrinfo` with
  `AF_UNSPEC`, the call PJSIP itself makes when it sends), "as the system decides". With DNS SRV in
  effect and no explicit port the name cannot be asked that way, so Auto uses IPv4 there; a host
  name that does not resolve (offline) also gives IPv4. The decision is made again at every network
  change and before every REGISTER retry, and an account whose family changed is moved to the other
  transport before it registers. The lookup runs synchronously on the engine queue, as PJSIP's own
  lookup does when it sends without its DNS resolver.
- **Contradictions are refused.** IPv4 only with an IPv6 literal server, or IPv6 only with an IPv4
  literal, can never work: the editor says so and keeps Save off, and the engine throws
  `invalidArgument`.
- **Media follows the account.** IPv6 accounts offer IPv6 only (`PJSUA_IPV6_ENABLED_USE_IPV6_ONLY`,
  because pjsua's IPv6 preference falls back to IPv4 without a global IPv6 address); IPv4 accounts
  keep pjsua's default. Every offer is answered in its own family.
- **No STUN over IPv6.** IPv6 accounts use neither SIP nor media STUN, and the SDP takes the address
  the registrar saw (`allow_sdp_nat_rewrite`), as for private IPv4 servers since 26.2.
- **No ICE over IPv6, for now.** The plan was IPv6 ICE candidates. PJSIP 2.17 binds the IPv6 ICE
  component to the string "0", which macOS `getaddrinfo` turns into `::ffff:0.0.0.0`; that socket
  cannot be bound, the offer carries IPv4 candidates only and a call fails on an IPv6 answer. IPv6
  accounts therefore have ICE off and use plain RTP. Enabling it needs a PJSIP patch (bind "::"),
  which is a separate decision because it means patching and rebuilding PJSIP.
- **Out of scope:** NAT64 and 464XLAT for IPv4 servers on IPv6-only networks, STUN and TURN over
  IPv6, servers on link-local addresses (`fe80::…%en0`).

## Consequences
An account at `[2001:db8::1]` or at an AAAA-only host name registers and calls over IPv6, with
`c=IN IP6` and IPv6 RTP; existing IPv4 accounts behave as before. A host name with A and AAAA records
may move to IPv6 after the update when macOS orders the IPv6 address first (as `localhost` does);
"IPv4 only" keeps the old behaviour. The engine opens four more listening sockets. With a host name
whose order changes between networks, the account may change family at a network change; a call in
progress on the old family may not survive that. IPv6 accounts lose ICE until PJSIP is patched.
Everything is verified on loopback only (`[::1]` with in-process stubs); behaviour on a real IPv6
PBX and network is left to users and listed as not verified (docs/ENGINE.md "IPv6").
