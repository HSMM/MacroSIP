internal import CPJSUA
import Foundation

/// The pjsua_acc_config fields MacroSIP sets, as plain Swift values.
/// `AccountMapping.settings` builds it from an AccountConfig; `withPJConfig` writes it into a
/// real pjsua_acc_config; `readBack` reads one back (tests compare both directions).
struct PJAccountSettings: Equatable, Sendable {
    var idURI: String
    var regURI: String
    var authRealm: String
    var authScheme: String
    var authUsername: String
    var password: String
    var regTimeout: Int
    var proxies: [String]
    var srtp: SRTPMode
    var srtpSecureSignaling: Int
    /// The account's transport, of the account's family (`IPFamilyPolicy`); PJSUA_INVALID_ID for a
    /// UDP account of a private IPv4 server while STUN is on, so its Contact and Via do not carry the
    /// STUN address (`settings`).
    var transportID: Int32
    var allowContactRewrite: Bool
    var allowViaRewrite: Bool
    var keepAliveSeconds: Int
    var iceEnabled: Bool
    /// STUN for the account's signalling and media (`sip_stun_use`, `media_stun_use`): false
    /// for a server in a private network (`PrivateServer`) and for every IPv6 account (STUN and
    /// TURN over IPv6 are out of scope); true keeps pjsua's defaults.
    var sipSTUN: Bool = true
    var mediaSTUN: Bool = true
    /// `allow_sdp_nat_rewrite`: without STUN pjsua offers the default route's address in SDP,
    /// which over a split-tunnel VPN is not the one the server sees; with it the SDP takes the
    /// address the registrar reported in Via (received), as Contact does. On for private servers.
    var sdpNATRewrite: Bool = false
    /// `ipv6_media_use = PJSUA_IPV6_ENABLED_USE_IPV6_ONLY` (IPv6 accounts): the offer is IPv6 even
    /// when only a link-local or loopback IPv6 address exists, which pjsua's PREFER_IPV6 would skip
    /// for IPv4. false keeps pjsua's default (PREFER_IPV4; an `IN IP6` offer is still answered with
    /// IPv6). Either way an offer is answered in its own family.
    var mediaIPv6Only: Bool = false
    /// RTP base port and range (NetworkSettings.rtpPortStart/rtpPortCount); the first port is
    /// picked at random inside the range so two PJSIP phones on one host (or a restarted
    /// engine) do not fight over 4000, 4002, ...
    var rtpPort: Int
    var rtpPortRange: Int
    var randomizeRTPPort: Bool
    /// Bind RTP to and advertise this address (nil = all interfaces, default route address). Only
    /// an address of the account's family.
    var bindAddress: String?
    /// PUBLISH our presence (PIDF/RPID) to the registrar's domain (AccountConfig.publishPresence).
    var publishEnabled: Bool
    /// Queue a status change while a PUBLISH is in flight instead of failing it.
    var publishQueueRequest: Bool
    /// SUBSCRIBE to message-summary (voicemail indicator) once registered (AccountConfig.mwi).
    var mwiEnabled: Bool = true
    /// pjsua's own retry after a failed REGISTER: 0 = off, the engine retries with backoff
    /// (docs/ENGINE.md "Network resilience").
    var regRetryInterval: Int = 0
    var dropCallsOnRegFail: Bool = false
    /// pjsua_handle_ip_change per account: calls are kept and re-INVITEd with these flags.
    var ipChangeHangupCalls: Bool = false
    var ipChangeReinviteFlags: UInt32 = 0
}

/// SIP transports created at engine start, per family (docs/ENGINE.md "IPv6"). TLS exists twice:
/// a listener that verifies the server certificate (default) and one that does not (accounts with
/// `verifyTLSCertificate == false`). PJSIP never reuses a connection across listeners. Accounts are
/// bound to the transport of their family; nil = that transport could not be created (or the bind
/// address is of the other family).
struct TransportIDs: Equatable, Sendable {
    var udp: Int32?
    var tcp: Int32?
    var tls: Int32?
    var tlsNoVerify: Int32?
    var udp6: Int32?
    var tcp6: Int32?
    var tls6: Int32?
    var tls6NoVerify: Int32?

    func id(for account: AccountConfig, family: IPFamily = .ipv4) -> Int32? {
        switch (account.transport, family) {
        case (.udp, .ipv4): return udp
        case (.tcp, .ipv4): return tcp
        case (.tls, .ipv4): return account.verifyTLSCertificate ? tls : tlsNoVerify
        case (.udp, .ipv6): return udp6
        case (.tcp, .ipv6): return tcp6
        case (.tls, .ipv6): return account.verifyTLSCertificate ? tls6 : tls6NoVerify
        }
    }

    func id(for kind: TransportKind, family: IPFamily = .ipv4) -> Int32? {
        switch (kind, family) {
        case (.udp, .ipv4): return udp
        case (.tcp, .ipv4): return tcp
        case (.tls, .ipv4): return tls
        case (.udp, .ipv6): return udp6
        case (.tcp, .ipv6): return tcp6
        case (.tls, .ipv6): return tls6
        }
    }

    /// Families that have the account's transport.
    func families(for account: AccountConfig) -> Set<IPFamily> {
        Set(IPFamily.allCases.filter { id(for: account, family: $0) != nil })
    }
}

/// STUN learns the address a NAT gives us towards the internet, which is what a server on the
/// internet must see in Contact, Via and SDP. A server addressed by a private or local IP is
/// reached inside the same network or through a VPN, where that public address is wrong: PJSIP
/// learns the real one only from the first answer and registers again, and a server that does
/// not rewrite Contact would send incoming calls to the public address. Host names are not
/// resolved here (the answer may change with the network); they keep STUN. This is about IPv4
/// accounts: an IPv6 account (`IPFamilyPolicy`) uses no STUN at all.
enum PrivateServer {
    /// Every signalling hop of the account is a private or local IP literal: the registrar and
    /// the outbound proxy when one is set, otherwise the domain (INVITE, SUBSCRIBE and PUBLISH
    /// go there directly). One public address or host name among them keeps STUN.
    static func allHopsPrivate(_ account: AccountConfig) -> Bool {
        hops(account).allSatisfy(isPrivate(uri:))
    }

    private static func hops(_ account: AccountConfig) -> [String] {
        let proxy = account.outboundProxy?.trimmingCharacters(in: .whitespaces) ?? ""
        return [account.registrarURI, proxy.isEmpty ? account.domain : proxy]
    }

    /// The host of "10.0.0.1", "10.0.0.1:5080", "sip:pbx@192.168.1.10;transport=tcp",
    /// "[fd00::1]:5060" or "fe80::1" is a private or local IP literal.
    static func isPrivate(uri: String) -> Bool {
        guard let host = SignallingSource.proxy(uri, transport: .udp)?.address else { return false }
        return isPrivate(address: host)
    }

    /// RFC 1918 (10/8, 172.16/12, 192.168/16), shared address space 100.64/10 (RFC 6598: carrier
    /// NAT, Tailscale; never routed on the internet), loopback 127/8 and link-local 169.254/16;
    /// for IPv6 ::1, unique local fc00::/7, link-local fe80::/10 and IPv4-mapped forms of the
    /// above. Anything that is not an IP literal is not private.
    static func isPrivate(address raw: String) -> Bool {
        let a = raw.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
        var v4 = in_addr()
        if inet_pton(AF_INET, a, &v4) == 1 {
            return isPrivate(ipv4: UInt32(bigEndian: v4.s_addr))
        }
        var v6 = in6_addr()
        guard inet_pton(AF_INET6, a, &v6) == 1 else { return false }
        let b = withUnsafeBytes(of: &v6) { Array($0) }
        if b[0..<15].allSatisfy({ $0 == 0 }) && b[15] == 1 { return true }                 // ::1
        if b[0] & 0xfe == 0xfc { return true }                                              // fc00::/7
        if b[0] == 0xfe && b[1] & 0xc0 == 0x80 { return true }                              // fe80::/10
        if b[0..<10].allSatisfy({ $0 == 0 }) && b[10] == 0xff && b[11] == 0xff {            // ::ffff:a.b.c.d
            return isPrivate(ipv4: UInt32(b[12]) << 24 | UInt32(b[13]) << 16 | UInt32(b[14]) << 8 | UInt32(b[15]))
        }
        return false
    }

    private static func isPrivate(ipv4 a: UInt32) -> Bool {
        a >> 24 == 10 || a >> 20 == 0xac1 || a >> 16 == 0xc0a8 || a >> 22 == 0x191 || a >> 24 == 127
            || a >> 16 == 0xa9fe
    }
}

enum AccountMapping {
    /// `family` is the account's IP family as `IPFamilyPolicy` decided it: the account is bound to
    /// that family's transport (pjsua_init_tpselector: a TRANSPORT selector for UDP, a LISTENER one
    /// for TCP/TLS, so the family is fixed by the binding; `ipv6_sip_use` only matters unbound).
    static func settings(
        for account: AccountConfig,
        password: String,
        network: NetworkSettings,
        transports: TransportIDs,
        bindAddress: String? = nil,
        family: IPFamily = .ipv4
    ) throws -> PJAccountSettings {
        guard let transportID = transports.id(for: account, family: family) else {
            throw EngineError.transportUnavailable(account.transport, ipv6: family == .ipv6)
        }
        let proxy = account.outboundProxy?.trimmingCharacters(in: .whitespaces) ?? ""
        // IPv6: no STUN (pjsua maps IPv4 only; an IPv6 address needs no mapping without NAT66),
        // so the SDP takes the address the registrar reported, as for private servers.
        let stun = family == .ipv4 && !PrivateServer.allHopsPrivate(account)
        // sip_stun_use alone does not change Contact and Via: for an account bound to its UDP
        // transport pjsua takes them from the transport's published address, which STUN made
        // the public one (pjsip_tpmgr_find_local_addr2 ignores local_if under a transport
        // selector). Unbound, pjsua takes the local address of the route to the server
        // (get_net_interface) with the transport's port; requests still leave through the one
        // UDP transport, and large ones stay on UDP (disable_tcp_switch). TCP and TLS listeners
        // are never published with a STUN address, and without a STUN server there is nothing
        // to undo: those accounts stay bound. IPv6 accounts stay bound to their IPv6 transport:
        // only the IPv4 UDP transport is published with a STUN address.
        let stunServer = network.stunServer?.trimmingCharacters(in: .whitespaces) ?? ""
        let unbound = !stun && !stunServer.isEmpty && account.transport == .udp && family == .ipv4
        // RTP binds to the engine's bind address only when it is of the account's family (pjsua
        // would fail to bind an IPv6 address to an IPv4 socket and the other way round). A bind
        // address that is not a literal counts as IPv4, as for the transports.
        let rtpBind = bindAddress.flatMap { (IPFamilyPolicy.literalFamily($0) ?? .ipv4) == family ? $0 : nil }
        return PJAccountSettings(
            idURI: account.uri,
            regURI: account.registrarURI,
            authRealm: "*",
            authScheme: "digest",
            authUsername: (account.authID?.isEmpty == false ? account.authID : nil) ?? account.username,
            password: password,
            regTimeout: max(0, account.registrationInterval),
            proxies: proxy.isEmpty ? [] : [proxyURI(proxy, transport: account.transport)],
            srtp: account.srtp,
            // Mandatory SRTP over TLS also requires secure signalling (sips); otherwise
            // SRTP is allowed over plain UDP/TCP signalling.
            srtpSecureSignaling: (account.srtp == .mandatory && account.transport == .tls) ? 1 : 0,
            transportID: unbound ? PJ.invalidID : transportID,
            allowContactRewrite: true,
            allowViaRewrite: true,
            keepAliveSeconds: max(0, network.keepAliveSeconds),
            // Not over IPv6: pjsua binds the IPv6 ICE component to "0", which macOS getaddrinfo turns
            // into ::ffff:0.0.0.0, so that socket fails (EADDRNOTAVAIL) and the offer would carry IPv4
            // candidates only, then fail on an IPv6 answer (PJ_EAFNOTSUP). Plain RTP works over IPv6.
            iceEnabled: network.useICE && family == .ipv4,
            sipSTUN: stun,
            mediaSTUN: stun,
            sdpNATRewrite: !stun,
            mediaIPv6Only: family == .ipv6,
            rtpPort: network.effectiveRTPRange.start,
            rtpPortRange: rtpPortRange(count: network.effectiveRTPRange.count),
            randomizeRTPPort: true,
            bindAddress: rtpBind,
            publishEnabled: account.publishPresence,
            publishQueueRequest: true,
            mwiEnabled: account.mwi,
            regRetryInterval: 0,
            dropCallsOnRegFail: false,
            ipChangeHangupCalls: false,
            ipChangeReinviteFlags: cpjsua_ip_change_reinvite_flags()
        )
    }

    /// pjsua's port_range for a window of `count` ports: RTP ports are port...port+range (even
    /// offsets), RTCP is RTP + 1, so the last RTP port is start + count - 2. Range 0 would mean
    /// "no upper bound", so a two-port window gets 1 (RTP only on the start port).
    static func rtpPortRange(count: Int) -> Int {
        max(1, count - 2)
    }

    /// "proxy.example.com" -> "sip:proxy.example.com;lr" (+ ";transport=tcp|tls" for TCP/TLS
    /// accounts). Loose routing is required, otherwise PJSIP treats the proxy as a strict router.
    static func proxyURI(_ raw: String, transport: TransportKind) -> String {
        let lower = raw.lowercased()
        var uri = (lower.hasPrefix("sip:") || lower.hasPrefix("sips:")) ? raw : "sip:\(raw)"
        let params = uri.lowercased().split(separator: ";").dropFirst()
        if transport != .udp && !params.contains(where: { $0.hasPrefix("transport=") }) {
            uri += ";transport=\(transport.rawValue)"
        }
        if !params.contains(where: { $0 == "lr" || $0.hasPrefix("lr=") }) {
            uri += ";lr"
        }
        return uri
    }

    static func srtpUse(_ mode: SRTPMode) -> pjmedia_srtp_use {
        switch mode {
        case .disabled: return PJMEDIA_SRTP_DISABLED
        case .optional: return PJMEDIA_SRTP_OPTIONAL
        case .mandatory: return PJMEDIA_SRTP_MANDATORY
        }
    }

    static func srtpMode(_ use: pjmedia_srtp_use) -> SRTPMode {
        switch use {
        case PJMEDIA_SRTP_MANDATORY: return .mandatory
        case PJMEDIA_SRTP_OPTIONAL: return .optional
        default: return .disabled
        }
    }

    /// Fills a heap-allocated pjsua_acc_config (it contains self-referencing list heads,
    /// so it must not be copied) and passes it to `body`. Strings live until `body` returns.
    static func withPJConfig<R>(
        _ s: PJAccountSettings,
        _ body: (UnsafeMutablePointer<pjsua_acc_config>) throws -> R
    ) rethrows -> R {
        let arena = CStringArena()
        let cfg = UnsafeMutablePointer<pjsua_acc_config>.allocate(capacity: 1)
        cfg.initialize(to: pjsua_acc_config())
        defer {
            cfg.deinitialize(count: 1)
            cfg.deallocate()
        }
        pjsua_acc_config_default(cfg)

        cfg.pointee.id = arena.pj(s.idURI)
        cfg.pointee.reg_uri = arena.pj(s.regURI)
        cfg.pointee.reg_timeout = UInt32(s.regTimeout)

        cfg.pointee.cred_count = 1
        cfg.pointee.cred_info.0.realm = arena.pj(s.authRealm)
        cfg.pointee.cred_info.0.scheme = arena.pj(s.authScheme)
        cfg.pointee.cred_info.0.username = arena.pj(s.authUsername)
        cfg.pointee.cred_info.0.data_type = Int32(PJSIP_CRED_DATA_PLAIN_PASSWD.rawValue)
        cfg.pointee.cred_info.0.data = arena.pj(s.password)

        cfg.pointee.proxy_cnt = 0
        if let first = s.proxies.first {
            cfg.pointee.proxy_cnt = 1
            cfg.pointee.proxy.0 = arena.pj(first)
        }

        cfg.pointee.use_srtp = srtpUse(s.srtp)
        cfg.pointee.srtp_secure_signaling = Int32(s.srtpSecureSignaling)
        cfg.pointee.transport_id = s.transportID

        cfg.pointee.allow_contact_rewrite = s.allowContactRewrite ? 1 : 0
        cfg.pointee.allow_via_rewrite = s.allowViaRewrite ? 1 : 0
        cfg.pointee.ka_interval = UInt32(s.keepAliveSeconds)

        cfg.pointee.ice_cfg_use = PJSUA_ICE_CONFIG_USE_CUSTOM
        cfg.pointee.ice_cfg.enable_ice = s.iceEnabled ? 1 : 0
        if !s.sipSTUN { cfg.pointee.sip_stun_use = PJSUA_STUN_USE_DISABLED }
        if !s.mediaSTUN { cfg.pointee.media_stun_use = PJSUA_STUN_USE_DISABLED }
        cfg.pointee.allow_sdp_nat_rewrite = s.sdpNATRewrite ? 1 : 0
        if s.mediaIPv6Only { cfg.pointee.ipv6_media_use = PJSUA_IPV6_ENABLED_USE_IPV6_ONLY }

        cfg.pointee.rtp_cfg.port = UInt32(s.rtpPort)
        cfg.pointee.rtp_cfg.port_range = UInt32(s.rtpPortRange)
        cfg.pointee.rtp_cfg.randomize_port = s.randomizeRTPPort ? 1 : 0
        if let addr = s.bindAddress, !addr.isEmpty {
            cfg.pointee.rtp_cfg.bound_addr = arena.pj(addr)
            cfg.pointee.rtp_cfg.public_addr = arena.pj(addr)
        }

        cfg.pointee.publish_enabled = s.publishEnabled ? 1 : 0
        cfg.pointee.publish_opt.queue_request = s.publishQueueRequest ? 1 : 0
        cfg.pointee.mwi_enabled = s.mwiEnabled ? 1 : 0

        cfg.pointee.reg_retry_interval = UInt32(max(0, s.regRetryInterval))
        cfg.pointee.drop_calls_on_reg_fail = s.dropCallsOnRegFail ? 1 : 0
        cfg.pointee.ip_change_cfg.shutdown_tp = 1
        cfg.pointee.ip_change_cfg.hangup_calls = s.ipChangeHangupCalls ? 1 : 0
        cfg.pointee.ip_change_cfg.reinvite_flags = s.ipChangeReinviteFlags

        return try withExtendedLifetime(arena) { try body(cfg) }
    }

    /// Reads the MacroSIP-relevant fields back out of a pjsua_acc_config.
    static func readBack(_ cfg: UnsafePointer<pjsua_acc_config>) -> PJAccountSettings {
        let c = cfg.pointee
        let cred = c.cred_info.0
        var proxies: [String] = []
        if c.proxy_cnt > 0 { proxies.append(PJ.string(c.proxy.0)) }
        return PJAccountSettings(
            idURI: PJ.string(c.id),
            regURI: PJ.string(c.reg_uri),
            authRealm: c.cred_count > 0 ? PJ.string(cred.realm) : "",
            authScheme: c.cred_count > 0 ? PJ.string(cred.scheme) : "",
            authUsername: c.cred_count > 0 ? PJ.string(cred.username) : "",
            password: c.cred_count > 0 && cred.data_type == Int32(PJSIP_CRED_DATA_PLAIN_PASSWD.rawValue)
                ? PJ.string(cred.data) : "",
            regTimeout: Int(c.reg_timeout),
            proxies: proxies,
            srtp: srtpMode(c.use_srtp),
            srtpSecureSignaling: Int(c.srtp_secure_signaling),
            transportID: c.transport_id,
            allowContactRewrite: c.allow_contact_rewrite != 0,
            allowViaRewrite: c.allow_via_rewrite != 0,
            keepAliveSeconds: Int(c.ka_interval),
            iceEnabled: c.ice_cfg_use == PJSUA_ICE_CONFIG_USE_CUSTOM && c.ice_cfg.enable_ice != 0,
            sipSTUN: c.sip_stun_use != PJSUA_STUN_USE_DISABLED,
            mediaSTUN: c.media_stun_use != PJSUA_STUN_USE_DISABLED,
            sdpNATRewrite: c.allow_sdp_nat_rewrite != 0,
            mediaIPv6Only: c.ipv6_media_use == PJSUA_IPV6_ENABLED_USE_IPV6_ONLY,
            rtpPort: Int(c.rtp_cfg.port),
            rtpPortRange: Int(c.rtp_cfg.port_range),
            randomizeRTPPort: c.rtp_cfg.randomize_port != 0,
            bindAddress: c.rtp_cfg.bound_addr.slen > 0 ? PJ.string(c.rtp_cfg.bound_addr) : nil,
            publishEnabled: c.publish_enabled != 0,
            publishQueueRequest: c.publish_opt.queue_request != 0,
            mwiEnabled: c.mwi_enabled != 0,
            regRetryInterval: Int(c.reg_retry_interval),
            dropCallsOnRegFail: c.drop_calls_on_reg_fail != 0,
            ipChangeHangupCalls: c.ip_change_cfg.hangup_calls != 0,
            ipChangeReinviteFlags: c.ip_change_cfg.reinvite_flags
        )
    }
}

enum CodecMapping {
    /// One entry per id. G.722.1 registers one codec per bitrate (16 kHz: 24 and 32 kbit/s;
    /// 32 kHz: 24, 32 and 48 kbit/s) under the same id; a priority set by id applies to all of
    /// them and the SDP offers each with its `bitrate` fmtp, so the list shows the id once
    /// (with the highest priority among them).
    static func unique(_ list: [CodecInfo]) -> [CodecInfo] {
        var out: [CodecInfo] = []
        for c in list {
            if let i = out.firstIndex(where: { $0.id == c.id }) {
                out[i].priority = max(out[i].priority, c.priority)
            } else {
                out.append(c)
            }
        }
        return out
    }

    /// `codecs()` order: by priority (highest first); codecs of equal priority (the disabled
    /// ones) in the order of `defaultCodecOrder` then `optionalCodecs` (G.711 before the 26.2
    /// additions), anything else after them by name.
    static func displayOrder(_ list: [CodecInfo]) -> [CodecInfo] {
        let known = (Engine.defaultCodecOrder + Engine.optionalCodecs).map { $0.lowercased() }
        func rank(_ id: String) -> Int { known.firstIndex(of: id.lowercased()) ?? known.count }
        return list.sorted { a, b in
            if a.priority != b.priority { return a.priority > b.priority }
            let ra = rank(a.id), rb = rank(b.id)
            return ra != rb ? ra < rb : a.id.lowercased() < b.id.lowercased()
        }
    }

    /// Priorities to apply: requested codecs that exist get 254, 253, ... in order (first =
    /// highest); every other available codec gets 0 (disabled). 255 is avoided on purpose:
    /// PJSIP treats PJMEDIA_CODEC_PRIO_HIGHEST as "move to top" and demotes it to 254,
    /// which would tie with the second codec. Matching is case-insensitive
    /// on the full id ("opus/48000/2") or on an id prefix ("opus" or "G722/16000").
    static func plan(requested: [String], available: [String]) -> [(id: String, priority: UInt8)] {
        var ordered: [String] = []
        for name in requested {
            let n = name.trimmingCharacters(in: .whitespaces).lowercased()
            guard !n.isEmpty else { continue }
            let match = available.first { $0.lowercased() == n }
                ?? available.first { $0.lowercased().hasPrefix(n + "/") }
            if let match, !ordered.contains(match) { ordered.append(match) }
        }
        var plan: [(id: String, priority: UInt8)] = []
        for (i, id) in ordered.enumerated() {
            plan.append((id, UInt8(max(1, 254 - i))))
        }
        for id in available where !ordered.contains(id) {
            plan.append((id, 0))
        }
        return plan
    }
}
