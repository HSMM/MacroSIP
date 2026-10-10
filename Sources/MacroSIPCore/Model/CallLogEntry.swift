import Foundation

public enum CallDirection: String, Codable, Sendable, CaseIterable {
    case incoming, outgoing, missed
}

public struct CallLogEntry: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var direction: CallDirection
    public var remoteNumber: String
    public var remoteDisplayName: String?
    public var accountID: AccountID
    public var startedAt: Date
    /// Seconds; 0 for missed/unanswered.
    public var duration: TimeInterval
    /// Resolved at insert time if a contact matches.
    public var contactID: UUID?

    public init(
        id: UUID = UUID(),
        direction: CallDirection,
        remoteNumber: String,
        remoteDisplayName: String? = nil,
        accountID: AccountID,
        startedAt: Date = Date(),
        duration: TimeInterval = 0,
        contactID: UUID? = nil
    ) {
        self.id = id
        self.direction = direction
        self.remoteNumber = remoteNumber
        self.remoteDisplayName = remoteDisplayName
        self.accountID = accountID
        self.startedAt = startedAt
        self.duration = duration
        self.contactID = contactID
    }
}
