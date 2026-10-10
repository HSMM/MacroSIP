import Foundation

public struct NetworkSettings: Codable, Equatable, Sendable {
    public var stunServer: String?          // nil = STUN off
    public var localPort: UInt16            // 0 = random
    public var keepAliveSeconds: Int
    public var useICE: Bool
    public var echoCancellation: Bool

    public init(
        stunServer: String? = "stun.l.google.com:19302",
        localPort: UInt16 = 0,
        keepAliveSeconds: Int = 15,
        useICE: Bool = false,
        echoCancellation: Bool = true
    ) {
        self.stunServer = stunServer
        self.localPort = localPort
        self.keepAliveSeconds = keepAliveSeconds
        self.useICE = useICE
        self.echoCancellation = echoCancellation
    }

    public static let `default` = NetworkSettings()
}
