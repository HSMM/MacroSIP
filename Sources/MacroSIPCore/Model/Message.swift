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
        remoteDisplayName: String? = nil,
        contactID: UUID? = nil,
        lastActivityAt: Date = Date(),
        unread: Int = 0
    ) {
        self.id = id
        self.accountID = accountID
        self.remoteNumber = remoteNumber
        self.remoteURI = remoteURI
        self.remoteDisplayName = remoteDisplayName
        self.contactID = contactID
        self.lastActivityAt = lastActivityAt
        self.unread = unread
    }

    private enum CodingKeys: String, CodingKey {
        case id, accountID, remoteNumber, remoteURI, remoteDisplayName, contactID, lastActivityAt, unread
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        accountID = try c.decode(AccountID.self, forKey: .accountID)
        remoteNumber = try c.decode(String.self, forKey: .remoteNumber)
        remoteURI = try c.decodeIfPresent(String.self, forKey: .remoteURI) ?? ""
        remoteDisplayName = try c.decodeIfPresent(String.self, forKey: .remoteDisplayName)
        contactID = try c.decodeIfPresent(UUID.self, forKey: .contactID)
        lastActivityAt = try c.decode(Date.self, forKey: .lastActivityAt)
        unread = try c.decodeIfPresent(Int.self, forKey: .unread) ?? 0
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
