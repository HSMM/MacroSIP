import Foundation

public struct AccountID: Hashable, Codable, Sendable {
    public let raw: UUID
    public init(raw: UUID = UUID()) { self.raw = raw }
}

public enum TransportKind: String, Codable, Sendable, CaseIterable {
    case udp, tcp, tls
}

public enum SRTPMode: String, Codable, Sendable, CaseIterable {
    case disabled, optional, mandatory
}

/// Everything about a SIP account except the password, which lives in Keychain under `id`.
public struct AccountConfig: Codable, Identifiable, Equatable, Sendable {
    public var id: AccountID
    public var displayName: String          // "Office"
    public var username: String             // "1001"
    public var domain: String               // "sip.example.com"
    public var registrar: String?           // nil = domain
    public var outboundProxy: String?       // "sip:proxy.example.com:5061;transport=tls"
    public var authID: String?              // nil = username
    public var transport: TransportKind
    public var srtp: SRTPMode
    public var enabled: Bool                // register on start
    public var isDefaultOutgoing: Bool
    public var registrationInterval: Int    // seconds
    public var publishPresence: Bool        // FULL only; ignored in Lite

    public init(
        id: AccountID = AccountID(),
        displayName: String,
        username: String,
        domain: String,
        registrar: String? = nil,
        outboundProxy: String? = nil,
        authID: String? = nil,
        transport: TransportKind = .udp,
        srtp: SRTPMode = .disabled,
        enabled: Bool = true,
        isDefaultOutgoing: Bool = false,
        registrationInterval: Int = 300,
        publishPresence: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.username = username
        self.domain = domain
        self.registrar = registrar
        self.outboundProxy = outboundProxy
        self.authID = authID
        self.transport = transport
        self.srtp = srtp
        self.enabled = enabled
        self.isDefaultOutgoing = isDefaultOutgoing
        self.registrationInterval = registrationInterval
        self.publishPresence = publishPresence
    }

    /// "sip:1001@sip.example.com"
    public var uri: String { "sip:\(username)@\(domain)" }
    /// "sip:sip.example.com" or the explicit registrar, with transport param for TCP/TLS.
    public var registrarURI: String {
        let host = registrar ?? domain
        let base = host.hasPrefix("sip:") || host.hasPrefix("sips:") ? host : "sip:\(host)"
        return transport == .udp ? base : "\(base);transport=\(transport.rawValue)"
    }
}
