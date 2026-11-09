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
  `AF_UNSPEC` and pj_getaddrinfo's hints), "as the system decides". That matches the order PJSIP
  tries when it resolves without its DNS resolver; with DNS SRV on PJSIP uses its own queries, and an
  account that does not register sends its INVITEs to the dialled host, so it is the system's order,
  not always PJSIP's. With DNS SRV in effect and no explicit port the name cannot be asked that way,
  so Auto starts with IPv4 there; a host name that does not resolve (offline) also gives IPv4. Lookups
  never block the engine: they run off its queue, one per host at a time, with a short cache; a new
  account's first REGISTER waits for its lookup (2 s at most), and a lookup that fails or is late
  never moves an existing account.
- **Auto falls back.** The system order is only the first attempt: a REGISTER that gets no answer at
  all (timeout, refused or broken connection, no address of the bound family) makes the account want
  the other family at once when the host has an address of it (or DNS SRV makes the other family the
  only chance), also when it happens during a network-change round (the move follows the round), and
  that family then stays until the next network change, through retries and unchanged updates. A server that answers
  (401, 403, its own 503) is not a reason to switch. Without this, a dual-stack name whose server
  does not answer over the first family (Asterisk listening on 0.0.0.0 only, an IPv6 firewall)
  would retry forever where 26.3.0 registered over IPv4.
- **Decided again** at every network change, when IPv6 comes or goes, and when a lookup answers
  (not after a fallback). **One reconciler does every move**: the triggers only
  record a desired family for the account's current settings (a generation number), and the
  reconciler moves the account when nothing can be hurt by it: no network-change round running,
  **no call on the account in any state** (the call's dialog would keep a peer of the old family on a
  transport of the new one), no REGISTER of it in flight. A move un-REGISTERs the old binding (as
  PJSIP knows it, not as the UI shows it) and waits for the answer (5 s at most: a lingering Contact
  forks calls or makes a `max_contacts=1` server refuse the new one with 403), then moves the account
  to the other transport, makes its subscriptions anew there and registers; the account shows
  "registering" throughout. A call that starts meanwhile, or a failed step, leaves the account
  registered where it is; a family without a transport is refused, not wanted. Moving from several places at once had raced with rounds,
  REGISTERs in flight and late answers.
- **IPv6 address changes** count only for accounts that use IPv6. A new temporary address while the
  old one is still assigned is a non-primary change (it waits for a ringing outgoing call); losing
  the address is primary. Without IPv6 accounts IPv6 coming, going or rotating starts no round, so
  IPv4 calls are not disturbed.
- **Contradictions are refused.** IPv4 only with an IPv6 literal server, or IPv6 only with an IPv4
  literal, can never work: the editor says so and keeps Save off, and the engine throws
  `invalidArgument`.
- **Media follows the account.** IPv6 accounts offer IPv6 only (`PJSUA_IPV6_ENABLED_USE_IPV6_ONLY`,
  because pjsua's IPv6 preference falls back to IPv4 without a global IPv6 address); IPv4 accounts
  keep pjsua's default. Every offer is answered in its own family.
- **No STUN over IPv6.** IPv6 accounts use neither SIP nor media STUN, and the SDP takes the address
  the registrar saw (`allow_sdp_nat_rewrite`), as for private IPv4 servers since 26.2.
- **ICE over IPv6, with our first PJSIP patch.** PJSIP 2.17 binds the IPv6 ICE component to the
  string "0", which macOS `getaddrinfo` turns into `::ffff:0.0.0.0`; that socket cannot be bound, the
  offer carried IPv4 candidates only and a call failed on an IPv6 answer. Instead of turning ICE off
  for IPv6 accounts, `scripts/build-pjsip.sh` applies `scripts/pjsip-patches/0001-ipv6-ice-bind-any.patch`:
  pjsua_media.c binds the IPv6 components like the IPv4 ones (the account's IPv6 bound address,
  else "::") and keeps the candidate of a component bound to loopback on purpose. This amends ADR 0002/0012: pjproject is no longer built
  from the pristine tarball alone. Patches live in `scripts/pjsip-patches/`, one problem per file
  with a header saying why, applied in name order with `patch -p1 --forward`; a patch that does not
  apply stops the build; their hashes are part of the build stamp and of CI's cache key; every
  pjproject upgrade reviews them (drop when fixed upstream).
- **Out of scope:** NAT64 and 464XLAT for IPv4 servers on IPv6-only networks, STUN and TURN over
  IPv6, servers on link-local addresses (`fe80::…%en0`).

## Consequences
An account at `[2001:db8::1]` or at an AAAA-only host name registers and calls over IPv6, with
`c=IN IP6` and IPv6 RTP. Accounts whose server is an IPv4 address, and accounts set to IPv4 only,
behave as before. An Auto account whose server is a host name with A and AAAA records may move to
IPv6 after the update when macOS orders the IPv6 address first (as `localhost` does); if the server
does not answer over IPv6 it falls back to IPv4 at once, and "IPv4 only" keeps the old behaviour
outright. IPv4 accounts' calls are never touched by IPv6 address changes. The engine opens four more
listening sockets, which fills pjsua's fixed table of eight transports. With a host name whose order
changes between networks, an Auto account may change family at a network change, but only when it
has no call. We now carry a PJSIP patch, which every pjproject
upgrade has to re-check.
Everything is verified on loopback only (`[::1]` with in-process stubs); behaviour on a real IPv6
PBX and network is left to users and listed as not verified (docs/ENGINE.md "IPv6").
