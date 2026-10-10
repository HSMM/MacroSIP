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
    /// TLS only: verify the server certificate against the macOS system roots and the
    /// server host name. Opt-out for servers with self-signed certificates (user's choice).
    public var verifyTLSCertificate: Bool

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
        publishPresence: Bool = false,
        verifyTLSCertificate: Bool = true
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
        self.verifyTLSCertificate = verifyTLSCertificate
    }

    /// "sip:1001@sip.example.com"
    public var uri: String {
        "sip:\(username.trimmingCharacters(in: .whitespaces))@\(domain.trimmingCharacters(in: .whitespaces))"
    }
    /// "sip:sip.example.com" or the explicit registrar, with transport param for TCP/TLS.
    /// The registrar is trimmed; empty means "use the domain"; "SIP:"/"SIPS:" is lower-cased.
    public var registrarURI: String {
        let explicit = registrar?.trimmingCharacters(in: .whitespaces) ?? ""
        let host = explicit.isEmpty ? domain.trimmingCharacters(in: .whitespaces) : explicit
        let base: String
        if host.lowercased().hasPrefix("sips:") {
            base = "sips:" + host.dropFirst(5)
        } else if host.lowercased().hasPrefix("sip:") {
            base = "sip:" + host.dropFirst(4)
        } else {
            base = "sip:\(host)"
        }
        return transport == .udp || base.lowercased().contains(";transport=")
            ? base : "\(base);transport=\(transport.rawValue)"
    }
}

extension AccountConfig {
    private enum CodingKeys: String, CodingKey {
        case id, displayName, username, domain, registrar, outboundProxy, authID, transport, srtp
        case enabled, isDefaultOutgoing, registrationInterval, publishPresence, verifyTLSCertificate
    }

    /// Decodes JSON written before `verifyTLSCertificate` existed (it defaults to true).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decode(AccountID.self, forKey: .id),
            displayName: try c.decode(String.self, forKey: .displayName),
            username: try c.decode(String.self, forKey: .username),
            domain: try c.decode(String.self, forKey: .domain),
            registrar: try c.decodeIfPresent(String.self, forKey: .registrar),
            outboundProxy: try c.decodeIfPresent(String.self, forKey: .outboundProxy),
            authID: try c.decodeIfPresent(String.self, forKey: .authID),
            transport: try c.decode(TransportKind.self, forKey: .transport),
            srtp: try c.decode(SRTPMode.self, forKey: .srtp),
            enabled: try c.decode(Bool.self, forKey: .enabled),
            isDefaultOutgoing: try c.decode(Bool.self, forKey: .isDefaultOutgoing),
            registrationInterval: try c.decode(Int.self, forKey: .registrationInterval),
            publishPresence: try c.decode(Bool.self, forKey: .publishPresence),
            verifyTLSCertificate: try c.decodeIfPresent(Bool.self, forKey: .verifyTLSCertificate) ?? true
        )
    }
}
