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
    /// Short explanation shown in the row, e.g. "Rejected: call limit". Absent in older files.
    public var note: String?
    /// The saved recording of this call (M4A), when there is one. Absent in older files.
    public var recordingURL: URL?

    public init(
        id: UUID = UUID(),
        direction: CallDirection,
        remoteNumber: String,
        remoteDisplayName: String? = nil,
        accountID: AccountID,
        startedAt: Date = Date(),
        duration: TimeInterval = 0,
        contactID: UUID? = nil,
        note: String? = nil,
        recordingURL: URL? = nil
    ) {
        self.id = id
        self.direction = direction
        self.remoteNumber = remoteNumber
        self.remoteDisplayName = remoteDisplayName
        self.accountID = accountID
        self.startedAt = startedAt
        self.duration = duration
        self.contactID = contactID
        self.note = note
        self.recordingURL = recordingURL
    }
}
