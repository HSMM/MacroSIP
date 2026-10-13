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
    var transportID: Int32
    var allowContactRewrite: Bool
    var allowViaRewrite: Bool
    var keepAliveSeconds: Int
    var iceEnabled: Bool
    /// RTP base port and range (NetworkSettings.rtpPortStart/rtpPortCount); the first port is
    /// picked at random inside the range so two PJSIP phones on one host (or a restarted
    /// engine) do not fight over 4000, 4002, ...
    var rtpPort: Int
    var rtpPortRange: Int
    var randomizeRTPPort: Bool
    /// Bind RTP to and advertise this address (nil = all interfaces, default route address).
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

/// SIP transports created at engine start. TLS exists twice: a listener that verifies the
/// server certificate (default) and one that does not (accounts with
/// `verifyTLSCertificate == false`). PJSIP never reuses a connection across listeners.
struct TransportIDs: Equatable, Sendable {
    var udp: Int32?
    var tcp: Int32?
    var tls: Int32?
    var tlsNoVerify: Int32?

    func id(for account: AccountConfig) -> Int32? {
        switch account.transport {
        case .udp: return udp
        case .tcp: return tcp
        case .tls: return account.verifyTLSCertificate ? tls : tlsNoVerify
        }
    }

    func id(for kind: TransportKind) -> Int32? {
        switch kind {
        case .udp: return udp
        case .tcp: return tcp
        case .tls: return tls
        }
    }
}

enum AccountMapping {
    static func settings(
        for account: AccountConfig,
        password: String,
        network: NetworkSettings,
        transports: TransportIDs,
        bindAddress: String? = nil
    ) throws -> PJAccountSettings {
        guard let transportID = transports.id(for: account) else {
            throw EngineError.transportUnavailable(account.transport)
        }
        let proxy = account.outboundProxy?.trimmingCharacters(in: .whitespaces) ?? ""
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
            transportID: transportID,
            allowContactRewrite: true,
            allowViaRewrite: true,
            keepAliveSeconds: max(0, network.keepAliveSeconds),
            iceEnabled: network.useICE,
            rtpPort: network.effectiveRTPRange.start,
            rtpPortRange: rtpPortRange(count: network.effectiveRTPRange.count),
            randomizeRTPPort: true,
            bindAddress: bindAddress,
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
