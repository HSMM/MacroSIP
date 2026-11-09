import Darwin
import Foundation
import os

/// IP family of an account's signalling and media (docs/ENGINE.md "IPv6", ADR 0014).
public enum IPFamily: String, Sendable, CaseIterable, CustomStringConvertible {
    case ipv4, ipv6

    public var description: String { self == .ipv4 ? "IPv4" : "IPv6" }
}

/// Host and port of one SIP hop as the account spells it: "pbx.example.com", "10.0.0.1:5080",
/// "sip:[2001:db8::1]:5070;lr", "<sips:edge@192.0.2.7;transport=tls>". IPv6 hosts without brackets.
struct SIPHop: Equatable, Sendable {
    var host: String
    var port: Int?

    static func parse(_ raw: String) -> SIPHop? {
        var s = raw.trimmingCharacters(in: .whitespaces)
        if let lt = s.firstIndex(of: "<"), let gt = s[lt...].firstIndex(of: ">") {
            s = String(s[s.index(after: lt)..<gt])
        }
        for scheme in ["sips:", "sip:"] where s.lowercased().hasPrefix(scheme) {
            s.removeFirst(scheme.count)
            break
        }
        if let cut = s.firstIndex(where: { $0 == ";" || $0 == "?" }) { s = String(s[..<cut]) }
        if let at = s.lastIndex(of: "@") { s = String(s[s.index(after: at)...]) }
        var host = s
        var port: Int?
        if s.hasPrefix("[") {
            guard let close = s.firstIndex(of: "]") else { return nil }
            host = String(s[s.index(after: s.startIndex)..<close])
            let rest = s[s.index(after: close)...]
            if rest.hasPrefix(":") { port = Int(rest.dropFirst()) }
        } else if s.filter({ $0 == ":" }).count == 1, let colon = s.firstIndex(of: ":") {
            host = String(s[..<colon])
            port = Int(s[s.index(after: colon)...])
        }
        host = host.trimmingCharacters(in: .whitespaces)
        return host.isEmpty ? nil : SIPHop(host: host, port: port)
    }
}

/// Which family an account uses (docs/ENGINE.md "IPv6"):
/// - a server given as an IPv4 or IPv6 literal uses its own family;
/// - IPv4 only / IPv6 only with a host name use that family;
/// - Auto with a host name: when only one family has a transport for the account, that one, without a
///   lookup; with DNS SRV in effect and no explicit port, IPv4 (getaddrinfo cannot follow SRV records);
///   otherwise the first family the system resolver returns (getaddrinfo, AF_UNSPEC, the call PJSIP itself
///   makes when it sends) that has a transport; IPv4 when nothing resolves (offline), decided again later.
/// The server is the first hop: the outbound proxy when one is set, otherwise the registrar (or the domain).
public enum IPFamilyPolicy {
    /// The family of an IP literal ("192.0.2.1", "2001:db8::1", "[::1]", "fe80::1%en0"); nil for a host name.
    public static func literalFamily(_ host: String) -> IPFamily? {
        var a = host.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
        if let zone = a.firstIndex(of: "%") { a = String(a[..<zone]) }
        var v4 = in_addr()
        if inet_pton(AF_INET, a, &v4) == 1 { return .ipv4 }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, a, &v6) == 1 { return .ipv6 }
        return nil
    }

    /// Where the account's requests go first: the outbound proxy when set, else the registrar URI's host.
    static func firstHop(of account: AccountConfig) -> SIPHop {
        let proxy = account.outboundProxy?.trimmingCharacters(in: .whitespaces) ?? ""
        return SIPHop.parse(proxy.isEmpty ? account.registrarURI : proxy) ?? SIPHop(host: "", port: nil)
    }

    /// The family of the server's IP literal when it contradicts the account's IP protocol (IPv4 only with
    /// "[2001:db8::1]", IPv6 only with "192.0.2.1"); nil when there is nothing to contradict. Such an
    /// account cannot work: the editor says so and the engine refuses it (`EngineError.invalidArgument`).
    public static func conflict(in account: AccountConfig) -> IPFamily? {
        let wanted: IPFamily
        switch account.ipProtocol {
        case .auto: return nil
        case .ipv4: wanted = .ipv4
        case .ipv6: wanted = .ipv6
        }
        guard let literal = literalFamily(firstHop(of: account).host), literal != wanted else { return nil }
        return literal
    }

    /// The family for `account` (assumes no `conflict`). `available`: families with a transport for the
    /// account's transport kind; `srv`: DNS SRV is in effect; `resolve`: the families of a host name in the
    /// system resolver's order.
    static func decide(_ account: AccountConfig, available: Set<IPFamily>, srv: Bool,
                       resolve: (String) -> [IPFamily]) -> IPFamily {
        let hop = firstHop(of: account)
        if let literal = literalFamily(hop.host) { return literal }
        switch account.ipProtocol {
        case .ipv4: return .ipv4
        case .ipv6: return .ipv6
        case .auto: break
        }
        if available.count == 1, let only = available.first { return only }
        if srv && hop.port == nil { return .ipv4 }
        guard !hop.host.isEmpty else { return .ipv4 }
        return resolve(hop.host).first { available.isEmpty || available.contains($0) } ?? .ipv4
    }

    /// The decision depends on the resolver's answer, so it may change with the network: Auto, a host
    /// name, and not the SRV case.
    static func followsResolver(_ account: AccountConfig, srv: Bool) -> Bool {
        let hop = firstHop(of: account)
        return account.ipProtocol == .auto && !hop.host.isEmpty && literalFamily(hop.host) == nil
            && !(srv && hop.port == nil)
    }
}

/// The system resolver's view of a host name.
enum IPFamilyResolver {
    /// The address families getaddrinfo returns for `host`, in its order, each once. The hints are
    /// pj_getaddrinfo's (AF_UNSPEC, no socket type, no flags), so the first entry is the one PJSIP sends to
    /// first. Synchronous, like PJSIP's own lookup without its DNS resolver (sip_resolve.c); [] on failure.
    static func system(_ host: String) -> [IPFamily] {
        let name = host.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
        guard !name.isEmpty else { return [] }
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(name, nil, &hints, &result) == 0 else { return [] }
        defer { freeaddrinfo(result) }
        var families: [IPFamily] = []
        var entry = result
        while let e = entry {
            let family: IPFamily? = e.pointee.ai_family == AF_INET6 ? .ipv6 : e.pointee.ai_family == AF_INET ? .ipv4 : nil
            if let family, !families.contains(family) { families.append(family) }
            entry = e.pointee.ai_next
        }
        return families
    }
}

/// Address-family lookups of host names, off the engine queue: at most one in flight per host (later
/// requests for it wait for that one), answers cached for `ttl` (failures are not cached). After
/// `invalidate()` (a network change) the cache is empty and lookups started before are dropped.
final class FamilyLookups: Sendable {
    private struct State {
        var cache: [String: (families: [IPFamily], at: ContinuousClock.Instant)] = [:]
        var inFlight: Set<String> = []
        var epoch: UInt64 = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    let ttl: Duration

    init(ttl: Duration = .seconds(30)) {
        self.ttl = ttl
    }

    func cached(_ host: String) -> [IPFamily]? {
        state.withLock { st in
            guard let entry = st.cache[host], ContinuousClock.now - entry.at < ttl else { return nil }
            return entry.families
        }
    }

    func invalidate() {
        state.withLock { st in
            st.cache = [:]
            st.inFlight = []
            st.epoch &+= 1
        }
    }

    /// Starts a lookup of `host` on a global queue unless one is running; `done` gets its answer ([]
    /// when it failed), unless an `invalidate()` came in between.
    func start(_ host: String, resolve: @escaping @Sendable (String) -> [IPFamily],
               done: @escaping @Sendable (String, [IPFamily]) -> Void) {
        let epoch: UInt64? = state.withLock { st in
            guard !host.isEmpty, !st.inFlight.contains(host) else { return nil }
            st.inFlight.insert(host)
            return st.epoch
        }
        guard let epoch else { return }
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let families = resolve(host)
            let current = state.withLock { st -> Bool in
                guard st.epoch == epoch else { return false }
                st.inFlight.remove(host)
                if !families.isEmpty { st.cache[host] = (families, .now) }
                return true
            }
            if current { done(host, families) }
        }
    }
}
