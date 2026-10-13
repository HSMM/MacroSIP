internal import CPJSUA
import Foundation

// Release 26.2 network options (docs/ENGINE.md "Network options"): RTP port window, rport,
// DNS SRV, and which network settings apply while running.

extension Engine {
    /// Applies what can change while running and reports whether the rest needs a restart
    /// (`NetworkSettings.needsRestart(from:)`):
    /// - live: `useRport` (the next request's Via), `keepAliveSeconds` and `useICE` (every
    ///   account is modified in place, without re-registering; ICE applies to the next call);
    /// - restart: the RTP window, `dnsSRV`/`nameserver`, `localPort`, `stunServer`,
    ///   `echoCancellation` (`.needsRestart`; the engine keeps running with the old values
    ///   until `stop` and `start(network:)` with the new settings).
    /// Before `start`: nothing to apply, `.applied` (`start` takes its own settings).
    public func applyNetworkSettings(_ settings: NetworkSettings) throws -> NetworkApplyResult {
        guard isStarted else { return .applied }
        try requireStarted()
        let restart = settings.needsRestart(from: network)
        var live = network
        live.useRport = settings.useRport
        live.keepAliveSeconds = settings.keepAliveSeconds
        live.useICE = settings.useICE
        let previous = network
        network = live
        if live.useRport != previous.useRport {
            pjsip_cfg().pointee.endpt.disable_rport = live.useRport ? 0 : 1
            emit(.log(level: 3, "engine: rport \(live.useRport ? "on" : "off")"))
        }
        if live.keepAliveSeconds != previous.keepAliveSeconds || live.useICE != previous.useICE {
            for (id, entry) in accounts {
                do {
                    let s = try accountSettings(entry.config, password: entry.password)
                    try AccountMapping.withPJConfig(s) { p in
                        p.pointee.disable_reg_on_modify = 1
                        try PJ.check(pjsua_acc_modify(entry.index, p), "pjsua_acc_modify")
                    }
                } catch {
                    PJ.warn(error, "network settings for account \(id.raw)")
                }
            }
        }
        if restart {
            emit(.log(level: 3, "engine: network settings changed; RTP ports, DNS, SIP port, STUN or echo cancellation apply after a restart"))
        }
        return restart ? .needsRestart : .applied
    }

    /// Points the SIP resolver at `servers` with their ports (pjsua_config only knows 53).
    func applyNameservers(_ servers: [DNSServer]) {
        guard !servers.isEmpty else { return }
        let hosts = servers.map { strdup($0.host) }
        defer { hosts.forEach { free($0) } }
        let ports = servers.map(\.port)
        let status = hosts.map { UnsafePointer($0) }.withUnsafeBufferPointer { h in
            ports.withUnsafeBufferPointer { p in
                cpjsua_set_nameservers(h.baseAddress, p.baseAddress, UInt32(servers.count))
            }
        }
        PJ.warn(status, "DNS servers \(servers.map(\.description).joined(separator: ", "))")
    }

    /// After a network change: with SRV on and no configured server, the system's resolvers
    /// may be others now (another Wi-Fi, a VPN); the resolver follows them.
    func refreshSystemNameservers() {
        guard isStarted, network.dnsSRV, DNSServers.parse(network.nameserver).isEmpty,
              cpjsua_has_resolver() != 0 else { return }
        let servers = DNSServers.system()
        guard !servers.isEmpty, servers != dnsServers else { return }
        dnsServers = servers
        applyNameservers(servers)
        emit(.log(level: 3, "engine: DNS SRV via \(servers.map(\.description).joined(separator: ", ")) (system resolvers changed)"))
    }

    // MARK: test hooks

    /// Local RTP port of a call's audio stream, 0 if it has none (tests, diagnostics).
    public func localRTPPort(of id: CallID) -> Int {
        guard let slot = try? liveSlot(id) else { return 0 }
        return Int(cpjsua_call_local_rtp_port(slot))
    }

    /// Whether SIP host names go through the DNS resolver (SRV), and its servers (tests).
    func resolverState() -> (enabled: Bool, servers: [DNSServer]) {
        guard isStarted, PJ.registerThread() else { return (false, []) }
        return (cpjsua_has_resolver() != 0, dnsServers)
    }

    /// pjsip's rport setting as in effect (tests).
    func rportEnabled() -> Bool {
        pjsip_cfg().pointee.endpt.disable_rport == 0
    }
}
