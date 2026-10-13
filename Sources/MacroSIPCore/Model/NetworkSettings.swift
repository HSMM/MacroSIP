import Foundation

/// Engine-wide network settings (settings.json `network`). Fields added in a release decode with
/// their defaults from files written before it.
///
/// What `Engine.applyNetworkSettings` changes while running and what needs a restart: see
/// `needsRestart(from:)`.
public struct NetworkSettings: Codable, Equatable, Sendable {
    public var stunServer: String?          // nil = STUN off
    public var localPort: UInt16            // 0 = random
    public var keepAliveSeconds: Int
    public var useICE: Bool
    public var echoCancellation: Bool
    /// RTP/RTCP ports of calls: `rtpPortCount` ports from `rtpPortStart` (26.2). The engine picks
    /// pairs (RTP even, RTCP = RTP + 1) at random inside the window. Valid: see `isValidRTPRange`;
    /// the engine clamps an invalid window (`effectiveRTPRange`).
    public var rtpPortStart: Int
    public var rtpPortCount: Int
    /// Ask for `rport` in Via (RFC 3581), so replies come back to the port requests left from (26.2).
    public var useRport: Bool
    /// Resolve registrar and outbound proxy hosts without an explicit port through DNS SRV
    /// (`_sip._udp`, `_sip._tcp`, `_sips._tcp`; RFC 3263) instead of plain A/AAAA (26.2).
    public var dnsSRV: Bool
    /// DNS servers for `dnsSRV`: "10.0.0.1", "10.0.0.1:5353", "[2001:db8::1]:53", several separated
    /// by commas or spaces (up to 4). nil or empty = the system's resolvers.
    public var nameserver: String?

    public static let rtpPortBounds = 1024...65535
    public static let defaultRTPPortStart = 4000
    public static let defaultRTPPortCount = 1000
    /// Four calls (each needs an RTP/RTCP pair); the Network pane uses the same bound.
    public static let minRTPPortCount = 8

    public init(
        stunServer: String? = "stun.l.google.com:19302",
        localPort: UInt16 = 0,
        keepAliveSeconds: Int = 15,
        useICE: Bool = false,
        echoCancellation: Bool = true,
        rtpPortStart: Int = NetworkSettings.defaultRTPPortStart,
        rtpPortCount: Int = NetworkSettings.defaultRTPPortCount,
        useRport: Bool = true,
        dnsSRV: Bool = false,
        nameserver: String? = nil
    ) {
        self.stunServer = stunServer
        self.localPort = localPort
        self.keepAliveSeconds = keepAliveSeconds
        self.useICE = useICE
        self.echoCancellation = echoCancellation
        self.rtpPortStart = rtpPortStart
        self.rtpPortCount = rtpPortCount
        self.useRport = useRport
        self.dnsSRV = dnsSRV
        self.nameserver = nameserver
    }

    public static let `default` = NetworkSettings()

    private enum CodingKeys: String, CodingKey {
        case stunServer, localPort, keepAliveSeconds, useICE, echoCancellation
        case rtpPortStart, rtpPortCount, useRport, dnsSRV, nameserver
    }

    /// Missing keys take the defaults (settings written before a field existed).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = NetworkSettings.default
        stunServer = try c.decodeIfPresent(String.self, forKey: .stunServer)
        localPort = try c.decodeIfPresent(UInt16.self, forKey: .localPort) ?? d.localPort
        keepAliveSeconds = try c.decodeIfPresent(Int.self, forKey: .keepAliveSeconds) ?? d.keepAliveSeconds
        useICE = try c.decodeIfPresent(Bool.self, forKey: .useICE) ?? d.useICE
        echoCancellation = try c.decodeIfPresent(Bool.self, forKey: .echoCancellation) ?? d.echoCancellation
        rtpPortStart = (try? c.decodeIfPresent(Int.self, forKey: .rtpPortStart)) ?? d.rtpPortStart
        rtpPortCount = (try? c.decodeIfPresent(Int.self, forKey: .rtpPortCount)) ?? d.rtpPortCount
        useRport = (try? c.decodeIfPresent(Bool.self, forKey: .useRport)) ?? d.useRport
        dnsSRV = (try? c.decodeIfPresent(Bool.self, forKey: .dnsSRV)) ?? d.dnsSRV
        nameserver = (try? c.decodeIfPresent(String.self, forKey: .nameserver)) ?? nil
    }

    /// `start` within 1024...65535, `count` ≥ `minRTPPortCount` and the last port (`start + count - 1`) ≤ 65535.
    public static func isValidRTPRange(start: Int, count: Int) -> Bool {
        rtpPortBounds.contains(start) && count >= minRTPPortCount && start + count - 1 <= rtpPortBounds.upperBound
    }

    public var isValidRTPRange: Bool { NetworkSettings.isValidRTPRange(start: rtpPortStart, count: rtpPortCount) }

    /// The window the engine uses: the configured one when valid; otherwise the start is clamped
    /// into 1024...65534 and the count into what fits above it (at least 2).
    public var effectiveRTPRange: (start: Int, count: Int) {
        if isValidRTPRange { return (rtpPortStart, rtpPortCount) }
        let bounds = NetworkSettings.rtpPortBounds
        let start = min(max(rtpPortStart, bounds.lowerBound), bounds.upperBound - NetworkSettings.minRTPPortCount + 1)
        let count = min(max(rtpPortCount, NetworkSettings.minRTPPortCount), bounds.upperBound - start + 1)
        return (start, count)
    }

    /// Whether going from `running` (what the engine was started with) to `self` needs the
    /// engine to be stopped and started again. Live: `useRport`, `keepAliveSeconds`, `useICE`.
    /// Restart: the RTP window, `dnsSRV`, `nameserver`, `localPort`, `stunServer`, `echoCancellation`.
    public func needsRestart(from running: NetworkSettings) -> Bool {
        effectiveRTPRange != running.effectiveRTPRange
            || dnsSRV != running.dnsSRV
            || (dnsSRV && NetworkSettings.trimmed(nameserver) != NetworkSettings.trimmed(running.nameserver))
            || localPort != running.localPort
            || NetworkSettings.trimmed(stunServer) != NetworkSettings.trimmed(running.stunServer)
            || echoCancellation != running.echoCancellation
    }

    private static func trimmed(_ s: String?) -> String {
        s?.trimmingCharacters(in: .whitespaces) ?? ""
    }
}

/// What `Engine.applyNetworkSettings` did.
public enum NetworkApplyResult: Equatable, Sendable {
    /// Everything that changed is in effect.
    case applied
    /// Some change (RTP window, DNS, SIP port, STUN, echo cancellation) takes effect only after
    /// `stop` and `start` with the new settings; the live parts were applied already.
    case needsRestart
}
