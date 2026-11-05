import Foundation

/// messages.json as stored: conversations and their messages in one file.
struct MessageFile: Codable, Sendable {
    var conversations: [Conversation] = []
    var messages: [Message] = []

    init(conversations: [Conversation] = [], messages: [Message] = []) {
        self.conversations = conversations
        self.messages = messages
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        conversations = try c.decodeIfPresent([Conversation].self, forKey: .conversations) ?? []
        messages = try c.decodeIfPresent([Message].self, forKey: .messages) ?? []
    }
}

public final class MessageStore: Sendable {
    private let store: JSONStore<MessageFile>
    private let contacts: ContactStore?
    private let limit: @Sendable () -> Int

    /// `contacts`: used to resolve `contactID` when a conversation is created. `limit`: max messages kept overall
    /// (default 5000); the oldest are dropped and conversations left without messages are pruned.
    public init(directory: URL, contacts: ContactStore? = nil, limit: @escaping @Sendable () -> Int = { 5000 }) {
        store = JSONStore(directory: directory, name: "messages", default: MessageFile())
        self.contacts = contacts
        self.limit = limit
    }

    /// Newest activity first.
    public func conversations() -> [Conversation] {
        store.load().conversations.sorted { $0.lastActivityAt > $1.lastActivityAt }
    }

    /// Oldest first; messages with equal dates keep their insertion order.
    public func messages(in conversation: UUID) -> [Message] {
        Self.ordered(store.load().messages.filter { $0.conversationID == conversation })
    }

    public func allMessages() -> [Message] { Self.ordered(store.load().messages) }

    public var unreadTotal: Int { store.load().conversations.reduce(0) { $0 + $1.unread } }

    private static func ordered(_ list: [Message]) -> [Message] {
        list.enumerated().sorted { ($0.element.at, $0.offset) < ($1.element.at, $1.offset) }.map(\.element)
    }

    /// Finds the conversation of (account, normalized number) or creates it. A non-empty `remoteURI` or
    /// `displayName` replaces the stored one.
    @discardableResult
    public func conversation(account: AccountID, remoteNumber: String, remoteURI: String, displayName: String?) throws -> Conversation {
        let key = Contact.normalize(remoteNumber)
        let contactID = contacts?.findUnique(byNumber: remoteNumber)?.id
        var result: Conversation?
        try store.update { file in
            if let i = file.conversations.firstIndex(where: { $0.accountID == account && Contact.normalize($0.remoteNumber) == key }) {
                if !remoteURI.isEmpty { file.conversations[i].remoteURI = remoteURI }
                if let name = displayName, !name.isEmpty { file.conversations[i].remoteDisplayName = name }
                if file.conversations[i].contactID == nil { file.conversations[i].contactID = contactID }
                result = file.conversations[i]
            } else {
                let c = Conversation(
                    accountID: account, remoteNumber: remoteNumber, remoteURI: remoteURI,
                    remoteDisplayName: (displayName?.isEmpty ?? true) ? nil : displayName,
                    contactID: contactID, lastActivityAt: Date(), unread: 0)
                file.conversations.append(c)
                result = c
            }
        }
        return result!
    }

    /// Adds the message, bumps the conversation's activity and, for an incoming one, its unread count.
    @discardableResult
    public func append(_ message: Message) throws -> Message {
        let max = Swift.max(1, limit())
        try store.update { file in
            file.messages.append(message)
            if let i = file.conversations.firstIndex(where: { $0.id == message.conversationID }) {
                if message.at > file.conversations[i].lastActivityAt { file.conversations[i].lastActivityAt = message.at }
                if message.direction == .incoming { file.conversations[i].unread += 1 }
            }
            Self.prune(&file, max: max)
        }
        return message
    }

    private static func prune(_ file: inout MessageFile, max: Int) {
        guard file.messages.count > max else { return }
        let drop = file.messages.enumerated()
            .sorted { ($0.element.at, $0.offset) < ($1.element.at, $1.offset) }
            .prefix(file.messages.count - max).map(\.offset)
        let dropSet = Set(drop)
        file.messages = file.messages.enumerated().filter { !dropSet.contains($0.offset) }.map(\.element)
        let alive = Set(file.messages.map(\.conversationID))
        file.conversations.removeAll { !alive.contains($0.id) }
    }

    /// Changes one message (state transitions). A message that is gone is ignored.
    public func update(_ id: UUID, _ change: (inout Message) -> Void) throws {
        try store.update { file in
            if let i = file.messages.firstIndex(where: { $0.id == id }) { change(&file.messages[i]) }
        }
    }

    public func markRead(_ conversation: UUID) throws {
        try store.update { file in
            if let i = file.conversations.firstIndex(where: { $0.id == conversation }) { file.conversations[i].unread = 0 }
        }
    }

    public func remove(message id: UUID) throws {
        try store.update { file in file.messages.removeAll { $0.id == id } }
    }

    public func remove(conversation id: UUID) throws {
        try store.update { file in
            file.conversations.removeAll { $0.id == id }
            file.messages.removeAll { $0.conversationID == id }
        }
    }

    public func clear() throws { try store.save(MessageFile()) }

    /// At launch: every message still `.sending` becomes `.failed(0, "interrupted")` so the UI can offer Retry.
    public func failInterruptedSends() throws {
        try store.update { file in
            for i in file.messages.indices where file.messages[i].state == .sending {
                file.messages[i].state = .failed
                file.messages[i].failureCode = 0
                file.messages[i].failureReason = "interrupted"
            }
        }
    }
}
