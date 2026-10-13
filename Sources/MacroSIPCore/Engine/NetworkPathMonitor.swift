import Darwin
import Foundation
import Network

/// One evaluation of the network path (`NWPathMonitor`), reduced to the primary route: the
/// first available interface (the one the system routes through), the local IPv4 address
/// the default route uses and the default gateway. Secondary interfaces (bridge100 of
/// Internet Sharing, a split-tunnel utun, a second Wi-Fi/Ethernet) coming and going do not
/// change it; a full-tunnel VPN that takes the default route does.
struct NetworkPath: Sendable, Equatable {
    /// `NWPath.status == .satisfied`.
    var satisfied: Bool
    /// Primary interface name ("en0"), "" when none.
    var interface: String
    /// Source address of the default route (what pjsua's sockets use towards the PBX), "" when
    /// there is no route.
    var address: String
    /// Default gateway, "" when unknown.
    var gateway: String
    /// Short text for the log.
    var summary: String

    init(satisfied: Bool, interface: String, address: String, gateway: String, summary: String? = nil) {
        self.satisfied = satisfied
        self.interface = interface
        self.address = address
        self.gateway = gateway
        self.summary = summary ?? NetworkPath.describe(interface: interface, address: address, gateway: gateway)
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
        let gateway = path.gateways.first.map { "\($0)" } ?? ""
        self.init(satisfied: path.status == .satisfied, interface: name, address: address, gateway: gateway,
                  summary: NetworkPath.describe(interface: name.isEmpty ? "" : "\(name)/\(type)",
                                                address: address, gateway: gateway))
    }

    /// The local address or interface changed: sockets, Contact and RTP addresses are stale.
    func primaryDiffers(from other: NetworkPath) -> Bool {
        interface != other.interface || address != other.address
    }

    /// Anything of the primary route changed (a gateway-only change keeps the address but may
    /// mean another network behind the same address, i.e. another NAT binding).
    func routeDiffers(from other: NetworkPath) -> Bool {
        primaryDiffers(from: other) || gateway != other.gateway
    }

    static func describe(interface: String, address: String, gateway: String) -> String {
        (interface.isEmpty ? "no interface" : interface)
            + (address.isEmpty ? "" : " " + address)
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
