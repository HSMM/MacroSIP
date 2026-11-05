import Foundation
import os

/// messages.json as stored: conversations and their messages in one file. Each array is read element by element: a
/// record that cannot be decoded is skipped and counted, the rest stays (as `ContactList` does for contacts).
struct MessageFile: Codable, Sendable {
    var conversations: [Conversation] = []
    var messages: [Message] = []
    /// Records the decoder could not read (only set by decoding).
    var skipped = 0

    init(conversations: [Conversation] = [], messages: [Message] = []) {
        self.conversations = conversations
        self.messages = messages
    }

    private enum CodingKeys: String, CodingKey { case conversations, messages }
    private struct Skip: Decodable {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func elements<T: Decodable>(_ key: CodingKeys, _ type: T.Type) throws -> ([T], Int) {
            guard c.contains(key) else { return ([], 0) }
            var list = try c.nestedUnkeyedContainer(forKey: key)
            var out: [T] = [], bad = 0
            while !list.isAtEnd {
                if let item = try? list.decode(T.self) { out.append(item) }
                else { _ = try? list.decode(Skip.self); bad += 1 }
            }
            return (out, bad)
        }
        let (conversations, badConversations) = try elements(.conversations, Conversation.self)
        let (messages, badMessages) = try elements(.messages, Message.self)
        self.conversations = conversations
        self.messages = messages
        skipped = badConversations + badMessages
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(conversations, forKey: .conversations)
        try c.encode(messages, forKey: .messages)
    }
}

/// Conversations and messages (messages.json). The whole file is held in memory after the first access and written
/// through on every change: one write per operation, no reads. Safe from any thread.
public final class MessageStore: @unchecked Sendable {
    private let store: JSONStore<MessageFile>
    private let directory: URL
    private let contacts: ContactStore?
    private let limit: @Sendable () -> Int
    private let lock = NSLock()
    private var cache: MessageFile?
    private static let log = Logger(subsystem: "com.hsmm.macrosip", category: "messages")

    /// `contacts`: used to resolve `contactID` when a conversation is created. `limit`: max messages kept overall
    /// (default 5000); the oldest are dropped and conversations left without messages are pruned.
    public init(directory: URL, contacts: ContactStore? = nil, limit: @escaping @Sendable () -> Int = { 5000 }) {
        self.directory = directory
        store = JSONStore(directory: directory, name: "messages", default: MessageFile())
        self.contacts = contacts
        self.limit = limit
    }

    // MARK: - Access

    /// The file, read on first use. A file with unreadable records keeps a copy of the original and is rewritten
    /// without them; a file that is not JSON at all is moved aside by `JSONStore.load`.
    private func loaded() -> MessageFile {
        if let cache { return cache }
        var file = store.load()
        if file.skipped > 0 {
            if let data = try? Data(contentsOf: store.fileURL) {
                let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
                let copy = directory.appendingPathComponent("messages.damaged-\(stamp).json")
                try? data.write(to: copy)
                Self.log.error("messages.json: \(file.skipped) unreadable records skipped, original kept as \(copy.lastPathComponent, privacy: .public)")
            }
            file.skipped = 0
            try? store.save(file)
        }
        cache = file
        return file
    }

    private func read<T>(_ body: (MessageFile) -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body(loaded())
    }

    /// Applies `body` to a copy, writes it, and only then keeps it: a failed write leaves memory and file as they were.
    @discardableResult
    private func change<T>(_ body: (inout MessageFile) throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        var file = loaded()
        let result = try body(&file)
        try store.save(file)
        cache = file
        return result
    }

    /// Newest activity first.
    public func conversations() -> [Conversation] {
        read { $0.conversations.sorted { $0.lastActivityAt > $1.lastActivityAt } }
    }

    /// Oldest first; messages with equal dates keep their insertion order.
    public func messages(in conversation: UUID) -> [Message] {
        read { Self.ordered($0.messages.filter { $0.conversationID == conversation }) }
    }

    public func allMessages() -> [Message] { read { Self.ordered($0.messages) } }

    /// The newest message of every conversation (what the list previews), in one pass.
    public func lastMessages() -> [UUID: Message] {
        read { file in
            var best: [UUID: (Message, Int)] = [:]
            for (i, m) in file.messages.enumerated() {
                if let b = best[m.conversationID], (b.0.at, b.1) > (m.at, i) { continue }
                best[m.conversationID] = (m, i)
            }
            return best.mapValues(\.0)
        }
    }

    public var unreadTotal: Int { read { $0.conversations.reduce(0) { $0 + $1.unread } } }

    private static func ordered(_ list: [Message]) -> [Message] {
        list.enumerated().sorted { ($0.element.at, $0.offset) < ($1.element.at, $1.offset) }.map(\.element)
    }

    // MARK: - Conversations

    /// Finds the conversation of (account, peer) or creates it. The peer is told apart by `ConversationAddress`: the user
    /// (numbers by their digits, so `+375291234567` and `375 29 123-45-67` meet) and the host where it matters (an explicit
    /// host other than `accountDomain`, or any host of a non-numeric user). A non-empty `remoteURI` or `displayName`
    /// replaces the stored one. `remoteNumber` is the user part; `remoteURI` may carry the host.
    @discardableResult
    public func conversation(account: AccountID, remoteNumber: String, remoteURI: String, displayName: String?,
                             accountDomain: String = "") throws -> Conversation {
        try change { file in
            Self.findOrCreate(&file, account: account, remoteNumber: remoteNumber, remoteURI: remoteURI, displayName: displayName,
                              accountDomain: accountDomain, contactID: contacts?.findUnique(byNumber: remoteNumber)?.id)
        }
    }

    /// `conversation(...)` and the first message in one write; `message` gets the conversation's id. Nothing is
    /// stored when the write fails.
    @discardableResult
    public func conversation(account: AccountID, remoteNumber: String, remoteURI: String, displayName: String?,
                             accountDomain: String = "", appending message: (UUID) -> Message) throws -> (Conversation, Message) {
        let max = Swift.max(1, limit())
        let contactID = contacts?.findUnique(byNumber: remoteNumber)?.id
        return try change { file in
            let conv = Self.findOrCreate(&file, account: account, remoteNumber: remoteNumber, remoteURI: remoteURI, displayName: displayName,
                                         accountDomain: accountDomain, contactID: contactID)
            let m = message(conv.id)
            Self.appendLocked(&file, m, max: max)
            return (file.conversations.first { $0.id == conv.id } ?? conv, m)
        }
    }

    private static func findOrCreate(_ file: inout MessageFile, account: AccountID, remoteNumber: String, remoteURI: String,
                                     displayName: String?, accountDomain: String, contactID: UUID?) -> Conversation {
        let key = ConversationAddress(number: remoteNumber, uri: remoteURI, accountDomain: accountDomain)
        if let i = file.conversations.firstIndex(where: { $0.matches(account: account, address: key) }) {
            if !remoteURI.isEmpty { file.conversations[i].remoteURI = remoteURI }
            if let name = displayName, !name.isEmpty { file.conversations[i].remoteDisplayName = name }
            if file.conversations[i].contactID == nil { file.conversations[i].contactID = contactID }
            return file.conversations[i]
        }
        let c = Conversation(
            accountID: account, remoteNumber: remoteNumber, remoteURI: remoteURI, remoteHost: key.host,
            remoteDisplayName: (displayName?.isEmpty ?? true) ? nil : displayName,
            contactID: contactID, lastActivityAt: Date(), unread: 0)
        file.conversations.append(c)
        return c
    }

    // MARK: - Messages

    /// Adds the message, bumps the conversation's activity and, for an incoming one, its unread count.
    @discardableResult
    public func append(_ message: Message) throws -> Message {
        let max = Swift.max(1, limit())
        try change { Self.appendLocked(&$0, message, max: max) }
        return message
    }

    private static func appendLocked(_ file: inout MessageFile, _ message: Message, max: Int) {
        file.messages.append(message)
        if let i = file.conversations.firstIndex(where: { $0.id == message.conversationID }) {
            if message.at > file.conversations[i].lastActivityAt { file.conversations[i].lastActivityAt = message.at }
            if message.direction == .incoming { file.conversations[i].unread += 1 }
        }
        prune(&file, max: max)
    }

    private static func prune(_ file: inout MessageFile, max: Int) {
        if file.messages.count > max {
            let drop = file.messages.enumerated()
                .sorted { ($0.element.at, $0.offset) < ($1.element.at, $1.offset) }
                .prefix(file.messages.count - max).map(\.offset)
            let dropSet = Set(drop)
            file.messages = file.messages.enumerated().filter { !dropSet.contains($0.offset) }.map(\.element)
            let alive = Set(file.messages.map(\.conversationID))
            file.conversations.removeAll { !alive.contains($0.id) }
            clampUnread(&file)
        }
    }

    /// A conversation never has more unread messages than incoming messages left in it.
    private static func clampUnread(_ file: inout MessageFile) {
        var incoming: [UUID: Int] = [:]
        for m in file.messages where m.direction == .incoming { incoming[m.conversationID, default: 0] += 1 }
        for i in file.conversations.indices where file.conversations[i].unread > (incoming[file.conversations[i].id] ?? 0) {
            file.conversations[i].unread = incoming[file.conversations[i].id] ?? 0
        }
    }

    /// Changes one message (state transitions). A message that is gone is ignored.
    public func update(_ id: UUID, _ change: (inout Message) -> Void) throws {
        try self.change { file in
            if let i = file.messages.firstIndex(where: { $0.id == id }) { change(&file.messages[i]) }
        }
    }

    /// Retry: `old` is removed and `new` added in one write, so the message moves to the end with its new time.
    /// Nothing changes when the write fails.
    public func replace(message old: UUID, with new: Message) throws {
        let max = Swift.max(1, limit())
        try change { file in
            file.messages.removeAll { $0.id == old }
            Self.appendLocked(&file, new, max: max)
            Self.clampUnread(&file)
        }
    }

    public func markRead(_ conversation: UUID) throws {
        try change { file in
            if let i = file.conversations.firstIndex(where: { $0.id == conversation }) { file.conversations[i].unread = 0 }
        }
    }

    public func remove(message id: UUID) throws {
        try change { file in
            file.messages.removeAll { $0.id == id }
            Self.clampUnread(&file)
        }
    }

    public func remove(conversation id: UUID) throws {
        try change { file in
            file.conversations.removeAll { $0.id == id }
            file.messages.removeAll { $0.conversationID == id }
        }
    }

    public func clear() throws { try change { $0 = MessageFile() } }

    /// At launch: every message still `.sending` becomes `.failed(0, "interrupted")` so the UI can offer Retry.
    public func failInterruptedSends() throws {
        try change { file in
            for i in file.messages.indices where file.messages[i].state == .sending {
                file.messages[i].state = .failed
                file.messages[i].failureCode = 0
                file.messages[i].failureReason = "interrupted"
            }
        }
    }
}
