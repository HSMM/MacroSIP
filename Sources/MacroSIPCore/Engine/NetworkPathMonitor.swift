import Darwin
import Foundation
import Network

/// One evaluation of the network path (`NWPathMonitor`), reduced to the primary route: the
/// first available interface (the one the system routes through), the local IPv4 and IPv6
/// addresses the default routes use and the default gateway. Secondary interfaces (bridge100 of
/// Internet Sharing, a split-tunnel utun, a second Wi-Fi/Ethernet) coming and going do not
/// change it; a full-tunnel VPN that takes the default route does, and so does a new IPv6
/// source address on the same interface (a new temporary address).
struct NetworkPath: Sendable, Equatable {
    /// `NWPath.status == .satisfied`.
    var satisfied: Bool
    /// Primary interface name ("en0"), "" when none.
    var interface: String
    /// Source address of the default route (what pjsua's sockets use towards the PBX), "" when
    /// there is no route.
    var address: String
    /// Source address of the default IPv6 route (a global address: link-local and loopback do not
    /// count), "" when there is none.
    var address6: String
    /// Default gateway, "" when unknown.
    var gateway: String
    /// Short text for the log.
    var summary: String

    init(satisfied: Bool, interface: String, address: String, address6: String = "", gateway: String,
         summary: String? = nil) {
        self.satisfied = satisfied
        self.interface = interface
        self.address = address
        self.address6 = address6
        self.gateway = gateway
        self.summary = summary ?? NetworkPath.describe(interface: interface, address: address, address6: address6,
                                                       gateway: gateway)
    }

    init(_ path: NWPath) {
        let primary = path.availableInterfaces.first
        let type: String
        switch primary?.type {
        case .wifi?: type = "wifi"
        case .wiredEthernet?: type = "ethernet"
        case .cellular?: type = "cellular"
        case .loopback?: type = "loopback"
        default: type = "other"
        }
        let name = primary?.name ?? ""
        let address = path.status == .satisfied ? (NetworkPath.defaultRouteSource() ?? "") : ""
        let address6 = path.status == .satisfied ? (NetworkPath.defaultRouteSource6() ?? "") : ""
        let gateway = path.gateways.first.map { "\($0)" } ?? ""
        self.init(satisfied: path.status == .satisfied, interface: name, address: address, address6: address6,
                  gateway: gateway,
                  summary: NetworkPath.describe(interface: name.isEmpty ? "" : "\(name)/\(type)",
                                                address: address, address6: address6, gateway: gateway))
    }

    /// A local address or the interface changed: sockets, Contact and RTP addresses are stale.
    /// `ipv6: false` leaves the IPv6 address out (no account uses IPv6, so a new temporary address
    /// changes nothing for the calls and registrations).
    func primaryDiffers(from other: NetworkPath, ipv6: Bool = true) -> Bool {
        interface != other.interface || address != other.address || (ipv6 && address6 != other.address6)
    }

    /// Anything of the primary route changed (a gateway-only change keeps the address but may
    /// mean another network behind the same address, i.e. another NAT binding).
    func routeDiffers(from other: NetworkPath, ipv6: Bool = true) -> Bool {
        primaryDiffers(from: other, ipv6: ipv6) || gateway != other.gateway
    }

    static func describe(interface: String, address: String, address6: String = "", gateway: String) -> String {
        (interface.isEmpty ? "no interface" : interface)
            + (address.isEmpty ? "" : " " + address)
            + (address6.isEmpty ? "" : " " + address6)
            + (gateway.isEmpty ? "" : " via " + gateway)
    }

    /// The source address the kernel picks for the default route: a UDP socket "connected"
    /// to a TEST-NET address (no packet is sent) and read back with getsockname.
    static func defaultRouteSource() -> String? {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var dest = sockaddr_in()
        dest.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        dest.sin_family = sa_family_t(AF_INET)
        dest.sin_port = in_port_t(UInt16(9).bigEndian)
        dest.sin_addr.s_addr = inet_addr("192.0.2.1")
        let connected = withUnsafePointer(to: &dest) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
        guard connected else { return nil }
        var local = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &local) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) == 0 }
        }
        guard named else { return nil }
        var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &local.sin_addr, &buf, socklen_t(buf.count)) != nil else { return nil }
        let text = String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return text == "0.0.0.0" ? nil : text
    }

    /// The same for IPv6: a UDP socket "connected" to 2001:db8::1 (documentation prefix, nothing is
    /// sent). nil without a default IPv6 route or when the kernel would only use a link-local or
    /// loopback source (no global IPv6 on this network). With temporary addresses (RFC 8981) this is
    /// the preferred temporary address, the one new sockets use.
    static func defaultRouteSource6() -> String? {
        let fd = socket(AF_INET6, SOCK_DGRAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var dest = sockaddr_in6()
        dest.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        dest.sin6_family = sa_family_t(AF_INET6)
        dest.sin6_port = in_port_t(UInt16(9).bigEndian)
        guard inet_pton(AF_INET6, "2001:db8::1", &dest.sin6_addr) == 1 else { return nil }
        let connected = withUnsafePointer(to: &dest) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) == 0
            }
        }
        guard connected else { return nil }
        var local = sockaddr_in6()
        var len = socklen_t(MemoryLayout<sockaddr_in6>.size)
        let named = withUnsafeMutablePointer(to: &local) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) == 0 }
        }
        guard named else { return nil }
        var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard inet_ntop(AF_INET6, &local.sin6_addr, &buf, socklen_t(buf.count)) != nil else { return nil }
        let text = String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return isUsableIPv6Source(text) ? text : nil
    }

    /// The IPv6 address is assigned to an interface of this Mac (getifaddrs). A deprecated temporary
    /// address stays assigned for days after a new one takes over.
    static func isAssignedLocally(_ text: String) -> Bool {
        var wanted = in6_addr()
        guard inet_pton(AF_INET6, text, &wanted) == 1 else { return false }
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return false }
        defer { freeifaddrs(list) }
        var entry = list
        while let e = entry {
            if let sa = e.pointee.ifa_addr, sa.pointee.sa_family == sa_family_t(AF_INET6) {
                let found = sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { a -> Bool in
                    var addr = a.pointee.sin6_addr
                    return withUnsafeBytes(of: &addr) { x in withUnsafeBytes(of: &wanted) { y in x.elementsEqual(y) } }
                }
                if found { return true }
            }
            entry = e.pointee.ifa_next
        }
        return false
    }

    /// A global IPv6 address: not unspecified, loopback or link-local (fe80::/10).
    static func isUsableIPv6Source(_ text: String) -> Bool {
        var a = in6_addr()
        guard inet_pton(AF_INET6, text, &a) == 1 else { return false }
        let b = withUnsafeBytes(of: &a) { Array($0) }
        if b.allSatisfy({ $0 == 0 }) { return false }                                  // ::
        if b[0..<15].allSatisfy({ $0 == 0 }) && b[15] == 1 { return false }             // ::1
        if b[0] == 0xfe && b[1] & 0xc0 == 0x80 { return false }                         // fe80::/10
        return true
    }
}

/// `NWPathMonitor` on its own queue. Updates are delivered in order through `paths` (one
/// consumer), so an unsatisfied/satisfied pair at wake can never be applied reversed.
/// `cancel()` ends the stream (a cancelled monitor cannot be restarted; the engine creates
/// a new one for a fresh evaluation after wake).
final class NetworkPathMonitor: @unchecked Sendable {
    // NWPathMonitor is thread-safe; it is only started and cancelled here. nil: injected
    // paths only (Engine(monitorNetwork: false)).
    private let monitor: NWPathMonitor?
    private let queue = DispatchQueue(label: "macrosip.network", qos: .utility)
    let paths: AsyncStream<NetworkPath>
    private let continuation: AsyncStream<NetworkPath>.Continuation

    init(live: Bool = true) {
        (paths, continuation) = AsyncStream.makeStream(of: NetworkPath.self, bufferingPolicy: .unbounded)
        let continuation = self.continuation
        monitor = live ? NWPathMonitor() : nil
        monitor?.pathUpdateHandler = { path in continuation.yield(NetworkPath(path)) }
        monitor?.start(queue: queue)
    }

    /// Tests: an update as if NWPathMonitor reported it (same ordered stream).
    func inject(_ path: NetworkPath) {
        queue.async { [continuation] in continuation.yield(path) }
    }

    func cancel() {
        monitor?.cancel()
        continuation.finish()
    }
}
