import Foundation

public final class AccountStore: Sendable {
    private let store: JSONStore<[AccountConfig]>
    public init(directory: URL) { store = JSONStore(directory: directory, name: "accounts", default: []) }

    public func all() -> [AccountConfig] { store.load() }

    /// Exactly one default outgoing account exists whenever any account exists.
    private static func normalize(_ list: inout [AccountConfig], preferring id: AccountID? = nil) {
        guard !list.isEmpty else { return }
        let winner = id.flatMap { i in list.firstIndex { $0.id == i && $0.isDefaultOutgoing } }
            ?? list.firstIndex { $0.isDefaultOutgoing } ?? 0
        for i in list.indices { list[i].isDefaultOutgoing = (i == winner) }
    }

    public func upsert(_ account: AccountConfig) throws {
        try store.update { list in
            if let i = list.firstIndex(where: { $0.id == account.id }) { list[i] = account } else { list.append(account) }
            Self.normalize(&list, preferring: account.id)
        }
    }

    public func remove(_ id: AccountID) throws {
        try store.update { list in
            list.removeAll { $0.id == id }
            Self.normalize(&list)
        }
    }

    public func setDefaultOutgoing(_ id: AccountID) throws {
        try store.update { list in
            guard list.contains(where: { $0.id == id }) else { return }
            for i in list.indices { list[i].isDefaultOutgoing = (list[i].id == id) }
        }
    }

    public func defaultOutgoing() -> AccountConfig? { all().first { $0.isDefaultOutgoing } }
}

public final class ContactStore: Sendable {
    private let store: JSONStore<[Contact]>
    public init(directory: URL) { store = JSONStore(directory: directory, name: "contacts", default: []) }

    public func all() -> [Contact] { store.load() }

    public func upsert(_ contact: Contact) throws {
        try store.update { list in
            if let i = list.firstIndex(where: { $0.id == contact.id }) { list[i] = contact } else { list.append(contact) }
        }
    }

    public func remove(_ id: UUID) throws { try store.update { $0.removeAll { $0.id == id } } }

    /// Case-insensitive match on name and number; also matches normalized numbers.
    public func search(_ query: String) -> [Contact] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let list = all()
        guard !q.isEmpty else { return list }
        let nq = Contact.normalize(q)
        return list.filter {
            $0.name.lowercased().contains(q) || $0.number.lowercased().contains(q)
                || (!nq.isEmpty && $0.normalizedNumber.contains(nq))
        }
    }

    public func find(byNumber number: String) -> Contact? {
        Self.find(byNumber: number, in: all())
    }

    static func find(byNumber number: String, in list: [Contact]) -> Contact? {
        let n = Contact.normalize(number)
        guard !n.isEmpty else { return nil }
        return list.first { $0.normalizedNumber == n }
    }
}

public final class CallLogStore: Sendable {
    private let store: JSONStore<[CallLogEntry]>
    private let contacts: ContactStore?
    private let limit: @Sendable () -> Int

    /// `contacts`: used to resolve `contactID` on append. `limit`: max entries kept (default 1000).
    public init(directory: URL, contacts: ContactStore? = nil, limit: @escaping @Sendable () -> Int = { 1000 }) {
        store = JSONStore(directory: directory, name: "calllog", default: [])
        self.contacts = contacts
        self.limit = limit
    }

    /// Newest first.
    public func all() -> [CallLogEntry] { store.load().sorted { $0.startedAt > $1.startedAt } }

    @discardableResult
    public func append(_ entry: CallLogEntry) throws -> CallLogEntry {
        var e = entry
        if e.contactID == nil, let c = contacts?.find(byNumber: e.remoteNumber) { e.contactID = c.id }
        let max = Swift.max(1, limit())
        try store.update { list in
            list.append(e)
            list.sort { $0.startedAt > $1.startedAt }
            if list.count > max { list.removeLast(list.count - max) }
        }
        return e
    }

    public func remove(_ id: UUID) throws { try store.update { $0.removeAll { $0.id == id } } }
    public func clear() throws { try store.save([]) }
}

public final class SettingsStore: Sendable {
    private let store: JSONStore<AppSettings>
    public init(directory: URL) { store = JSONStore(directory: directory, name: "settings", default: .default) }
    public func load() -> AppSettings { store.load() }
    public func save(_ settings: AppSettings) throws { try store.save(settings) }
}
