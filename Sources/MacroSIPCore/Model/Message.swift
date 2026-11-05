import Foundation

public enum MessageDirection: String, Codable, Sendable { case incoming, outgoing }

/// `sent` means the SIP server or peer accepted the message (2xx), not that a phone received it.
public enum MessageState: String, Codable, Sendable { case sending, sent, failed }

public struct Conversation: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var accountID: AccountID
    /// What the UI shows and what a reply dials (user part, e.g. "+375291234567" or "102").
    public var remoteNumber: String
    /// Full URI of the peer as last seen.
    public var remoteURI: String
    /// The peer's host when it is part of who the peer is: an explicit host that is not the account's own domain, and the
    /// host of every non-numeric user. nil for numbers dialled through the account. Absent in older files.
    public var remoteHost: String?
    /// From display name of the last incoming message, if any. Absent in older files.
    public var remoteDisplayName: String?
    /// Resolved when the conversation is created, if a contact matches.
    public var contactID: UUID?
    public var lastActivityAt: Date
    /// Incoming messages not yet read. Absent in older files.
    public var unread: Int

    public init(
        id: UUID = UUID(),
        accountID: AccountID,
        remoteNumber: String,
        remoteURI: String = "",
        remoteHost: String? = nil,
        remoteDisplayName: String? = nil,
        contactID: UUID? = nil,
        lastActivityAt: Date = Date(),
        unread: Int = 0
    ) {
        self.id = id
        self.accountID = accountID
        self.remoteNumber = remoteNumber
        self.remoteURI = remoteURI
        self.remoteHost = remoteHost
        self.remoteDisplayName = remoteDisplayName
        self.contactID = contactID
        self.lastActivityAt = lastActivityAt
        self.unread = unread
    }

    private enum CodingKeys: String, CodingKey {
        case id, accountID, remoteNumber, remoteURI, remoteHost, remoteDisplayName, contactID, lastActivityAt, unread
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        accountID = try c.decode(AccountID.self, forKey: .accountID)
        remoteNumber = try c.decode(String.self, forKey: .remoteNumber)
        remoteURI = try c.decodeIfPresent(String.self, forKey: .remoteURI) ?? ""
        remoteHost = try c.decodeIfPresent(String.self, forKey: .remoteHost)
        remoteDisplayName = try c.decodeIfPresent(String.self, forKey: .remoteDisplayName)
        contactID = try c.decodeIfPresent(UUID.self, forKey: .contactID)
        lastActivityAt = try c.decode(Date.self, forKey: .lastActivityAt)
        unread = try c.decodeIfPresent(Int.self, forKey: .unread) ?? 0
    }
}

extension Conversation {
    /// What the UI shows when the peer has no name: the number, or `user@host` where the host tells peers apart.
    public var shownNumber: String { remoteHost.map { "\(remoteNumber)@\($0)" } ?? remoteNumber }

    /// Whether this conversation is with the peer `address` on `account`.
    public func matches(account: AccountID, address: ConversationAddress) -> Bool {
        accountID == account && address.matches(user: remoteNumber, host: remoteHost)
    }
}

/// Who a message is to or from, as a conversation tells peers apart: the user and, where it matters, the host.
/// - A number (digits, `+`, `*`, `#` and the usual separators) is compared by its digits: `+375 29 123-45-67` and
///   `375291234567` are one number, and a number with a country prefix meets the same number without it (one ends with
///   the other and the shorter has at least 7 digits); shorter numbers (extensions) must be equal. The host counts only when it is explicit and not
///   the account's own domain (an unknown domain: never).
/// - Any other user (`alice`, `bob.smith`) is compared as written, case-insensitively, together with its host, which
///   always counts.
public struct ConversationAddress: Equatable, Sendable {
    public var user: String
    public var host: String?

    /// Fewest digits for which one number may match another as its suffix.
    public static let minSuffixDigits = 7

    /// `raw` is a number, a `sip:`/`sips:`/`tel:` URI or `user@host`; `accountDomain` the account's domain.
    public init(_ raw: String, accountDomain: String = "") {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = s.lowercased()
        var user = s
        var host: String?
        if lower.hasPrefix("tel:") {
            user = String(s.dropFirst(4))
        } else if lower.hasPrefix("sip:") || lower.hasPrefix("sips:") || s.contains("@") {
            user = DialString.userPart(of: s)
            if let at = s.lastIndex(of: "@") {
                let h = Self.bareHost(String(s[s.index(after: at)...]))
                host = h.isEmpty ? nil : h
            }
        }
        self.init(user: user, host: host, accountDomain: accountDomain)
    }

    /// The user as written and the host found next to it (nil when none).
    init(user: String, host: String?, accountDomain: String) {
        var host = host
        if Self.isNumber(user) {
            self.user = DialString.normalizeNumber(user)
            // The host of a number counts only when it is explicit and differs from the account's domain (unknown: never).
            if let h = host, accountDomain.isEmpty || h == Self.bareHost(accountDomain) { host = nil }
        } else {
            self.user = user.lowercased()
        }
        self.host = host
    }

    /// The peer of a conversation: `number` is the user part, `uri` (may be empty) says where it lives.
    public init(number: String, uri: String, accountDomain: String) {
        let fromURI = ConversationAddress(uri, accountDomain: accountDomain)
        if number.isEmpty { self = fromURI; return }
        let plain = ConversationAddress(number, accountDomain: accountDomain)
        if plain.host != nil || uri.isEmpty { self = plain; return }
        // `number` is a bare user: the host is the URI's (and numbers drop it when it is the account's own).
        let host = uri.lastIndex(of: "@").map { Self.bareHost(String(uri[uri.index(after: $0)...])) }.flatMap { $0.isEmpty ? nil : $0 }
        self.init(user: number, host: host, accountDomain: accountDomain)
    }

    static func isNumber(_ user: String) -> Bool {
        !user.isEmpty && user.allSatisfy { "0123456789+*#-.() ".contains($0) } && user.contains(where: \.isNumber)
    }

    /// Host without port, parameters and header part, lower case.
    static func bareHost(_ s: String) -> String {
        String(s.prefix { !";?>:".contains($0) }).trimmingCharacters(in: .whitespaces).lowercased()
    }

    func matches(user other: String, host otherHost: String?) -> Bool {
        guard host == otherHost.map({ $0.lowercased() }) else { return false }
        if Self.isNumber(user) || Self.isNumber(other) {
            guard Self.isNumber(user), Self.isNumber(other) else { return false }
            return Self.sameNumber(user, DialString.normalizeNumber(other))
        }
        return user == other.lowercased()
    }

    /// Equal digits, or one number is the tail of the other and at least `minSuffixDigits` long (country prefix, trunk
    /// prefix). `*` and `#` codes are compared as written.
    static func sameNumber(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        let da = a.filter(\.isNumber), db = b.filter(\.isNumber)
        guard !da.isEmpty, !db.isEmpty, a.allSatisfy({ $0.isNumber || $0 == "+" }), b.allSatisfy({ $0.isNumber || $0 == "+" }) else { return false }
        if da == db { return true }
        let (short, long) = da.count <= db.count ? (da, db) : (db, da)
        return short.count >= minSuffixDigits && long.hasSuffix(short)
    }
}

public struct Message: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var conversationID: UUID
    public var direction: MessageDirection
    public var text: String
    /// Received, or when sending started.
    public var at: Date
    /// Incoming messages are always `.sent`.
    public var state: MessageState
    /// For `.failed`: the SIP code, or 0 for a local failure.
    public var failureCode: Int?
    public var failureReason: String?

    public init(
        id: UUID = UUID(),
        conversationID: UUID,
        direction: MessageDirection,
        text: String,
        at: Date = Date(),
        state: MessageState = .sent,
        failureCode: Int? = nil,
        failureReason: String? = nil
    ) {
        self.id = id
        self.conversationID = conversationID
        self.direction = direction
        self.text = text
        self.at = at
        self.state = state
        self.failureCode = failureCode
        self.failureReason = failureReason
    }
}
