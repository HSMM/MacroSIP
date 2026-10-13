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
    /// Master switch. Off: the account is not in the engine at all (no registration, no
    /// outgoing or incoming calls); it keeps its settings and Keychain item.
    public var enabled: Bool
    /// Off keeps an enabled account for outgoing calls only (no REGISTER).
    public var registerWithServer: Bool
    public var isDefaultOutgoing: Bool
    public var registrationInterval: Int    // seconds
    public var publishPresence: Bool        // publish our own presence status
    /// TLS only: verify the server certificate against the macOS system roots and the
    /// server host name. Opt-out for servers with self-signed certificates (user's choice).
    public var verifyTLSCertificate: Bool
    /// Subscribe to the voicemail indicator (RFC 3842 message-summary); `.voicemail` events.
    public var mwi: Bool
    /// Number (or SIP URI) the app dials to listen to voicemail; nil = not configured.
    public var voicemailNumber: String?

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
        registerWithServer: Bool = true,
        isDefaultOutgoing: Bool = false,
        registrationInterval: Int = 300,
        publishPresence: Bool = false,
        verifyTLSCertificate: Bool = true,
        mwi: Bool = true,
        voicemailNumber: String? = nil
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
        self.registerWithServer = registerWithServer
        self.isDefaultOutgoing = isDefaultOutgoing
        self.registrationInterval = registrationInterval
        self.publishPresence = publishPresence
        self.verifyTLSCertificate = verifyTLSCertificate
        self.mwi = mwi
        self.voicemailNumber = voicemailNumber
    }

    /// The engine sends REGISTER for this account.
    public var registers: Bool { enabled && registerWithServer }

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
        case enabled, registerWithServer, isDefaultOutgoing, registrationInterval, publishPresence, verifyTLSCertificate
        case mwi, voicemailNumber
    }

    /// Decodes JSON written before `verifyTLSCertificate`, `registerWithServer`, `mwi` and
    /// `voicemailNumber` existed (missing: verify on, MWI on, no voicemail number).
    /// Before `registerWithServer`, `enabled == false` meant "do not register"; that becomes an
    /// enabled, outgoing-only account so nothing silently turns into a disabled one.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        var enabled = try c.decode(Bool.self, forKey: .enabled)
        var register = try c.decodeIfPresent(Bool.self, forKey: .registerWithServer)
        if register == nil { register = enabled; enabled = true }
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
            enabled: enabled,
            registerWithServer: register ?? true,
            isDefaultOutgoing: try c.decode(Bool.self, forKey: .isDefaultOutgoing),
            registrationInterval: try c.decode(Int.self, forKey: .registrationInterval),
            publishPresence: try c.decode(Bool.self, forKey: .publishPresence),
            verifyTLSCertificate: try c.decodeIfPresent(Bool.self, forKey: .verifyTLSCertificate) ?? true,
            mwi: (try? c.decodeIfPresent(Bool.self, forKey: .mwi)) ?? true,
            voicemailNumber: try? c.decodeIfPresent(String.self, forKey: .voicemailNumber)
        )
    }
}
