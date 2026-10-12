import Foundation

public struct Contact: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    /// Dial string as typed, e.g. "+7 495 123-45-67" or "sip:bob@host".
    public var number: String
    public var preferredAccountID: AccountID?
    /// Whether to watch this contact's presence.
    public var subscribePresence: Bool
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        number: String,
        preferredAccountID: AccountID? = nil,
        subscribePresence: Bool = false,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.number = number
        self.preferredAccountID = preferredAccountID
        self.subscribePresence = subscribePresence
        self.createdAt = createdAt
    }

    /// Key for matching call log entries: digits/"+"/"*"/"#" for numbers, lowercase user part for URIs.
    public var normalizedNumber: String { Contact.normalize(number) }

    public static func normalize(_ raw: String) -> String {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = s.lowercased()
        if lower.hasPrefix("sip:") || lower.hasPrefix("sips:") || s.contains("@") {
            return DialString.userPart(of: s).lowercased()
        }
        if lower.hasPrefix("tel:") { return DialString.normalizeNumber(String(s.dropFirst(4))) }
        let n = DialString.normalizeNumber(s)
        return n.isEmpty ? lower : n
    }
}
