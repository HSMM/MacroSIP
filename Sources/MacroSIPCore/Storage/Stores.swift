import Foundation
import os

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

/// contacts.json as the store reads it: an array, one damaged element does not lose the rest.
struct ContactList: Codable, Sendable {
    var items: [Contact]
    /// Elements the decoder could not read (only set by decoding).
    var skipped = 0

    init(_ items: [Contact]) { self.items = items }

    private struct Skip: Decodable {}

    init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        items = []
        while !c.isAtEnd {
            if let contact = try? c.decode(Contact.self) { items.append(contact) }
            else { _ = try? c.decode(Skip.self); skipped += 1 }
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.unkeyedContainer()
        for item in items { try c.encode(item) }
    }
}

public final class ContactStore: @unchecked Sendable {
    private let store: JSONStore<ContactList>
    private let directory: URL
    private let lock = NSLock()
    /// Photos by contact id; `.some(nil)` = looked for, none.
    private var photoCache: [UUID: Data?] = [:]
    private static let log = Logger(subsystem: "com.hsmm.macrosip", category: "contacts")

    public init(directory: URL) {
        self.directory = directory
        store = JSONStore(directory: directory, name: "contacts", default: ContactList([]))
        prepare()
    }

    public var photoDirectory: URL { directory.appendingPathComponent("photos", isDirectory: true) }

    private func photoURL(_ id: UUID) -> URL { photoDirectory.appendingPathComponent("\(id.uuidString).jpg") }

    /// Once per start: keeps a copy of a file with unreadable entries before they are dropped, and moves photos
    /// that older files hold inline into `photos/`.
    private func prepare() {
        guard let data = try? Data(contentsOf: store.fileURL),
              let list = try? JSONStore<ContactList>.decoder().decode(ContactList.self, from: data) else { return }
        var dirty = false
        if list.skipped > 0 {
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let copy = directory.appendingPathComponent("contacts.damaged-\(stamp).json")
            try? data.write(to: copy)
            Self.log.error("contacts.json: \(list.skipped) unreadable entries skipped, original kept as \(copy.lastPathComponent, privacy: .public)")
            dirty = true
        }
        for c in list.items {
            guard let photo = c.photo else { continue }
            if (try? writePhotoFile(photo, for: c.id)) != nil { lock.lock(); photoCache[c.id] = .some(photo); lock.unlock(); dirty = true }
        }
        if dirty { try? store.save(ContactList(list.items.map { var c = $0; c.photo = nil; return c })) }
    }

    private func writePhotoFile(_ data: Data, for id: UUID) throws {
        try FileManager.default.createDirectory(at: photoDirectory, withIntermediateDirectories: true)
        try data.write(to: photoURL(id), options: .atomic)
    }

    private func photo(for id: UUID) -> Data? {
        lock.lock(); defer { lock.unlock() }
        if let cached = photoCache[id] { return cached }
        let data = try? Data(contentsOf: photoURL(id))
        photoCache[id] = .some(data)
        return data
    }

    public func all() -> [Contact] {
        store.load().items.map { c in var c = c; c.photo = photo(for: c.id); return c }
    }

    public func upsert(_ contact: Contact) throws {
        try savePhoto(contact)
        var stored = contact
        stored.photo = nil
        try store.update { list in
            if let i = list.items.firstIndex(where: { $0.id == stored.id }) { list.items[i] = stored } else { list.items.append(stored) }
        }
    }

    /// Saves many contacts with one read and one write of contacts.json (directory import).
    public func upsert(contentsOf contacts: [Contact]) throws {
        guard !contacts.isEmpty else { return }
        for c in contacts { try savePhoto(c) }
        try store.update { list in
            var index: [UUID: Int] = [:]
            for (i, c) in list.items.enumerated() { index[c.id] = i }
            for contact in contacts {
                var stored = contact
                stored.photo = nil
                if let i = index[stored.id] { list.items[i] = stored }
                else { index[stored.id] = list.items.count; list.items.append(stored) }
            }
        }
    }

    private func savePhoto(_ contact: Contact) throws {
        lock.lock(); defer { lock.unlock() }
        if let cached = photoCache[contact.id], cached == contact.photo { return }
        if let data = contact.photo {
            try writePhotoFile(data, for: contact.id)
        } else {
            try? FileManager.default.removeItem(at: photoURL(contact.id))
        }
        photoCache[contact.id] = .some(contact.photo)
    }

    public func remove(_ id: UUID) throws {
        try store.update { $0.items.removeAll { $0.id == id } }
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.removeItem(at: photoURL(id))
        photoCache[id] = .some(nil)
    }

    /// Case-insensitive match on names, organization and every number (`Contact.search`).
    public func search(_ query: String) -> [Contact] {
        Contact.search(all(), query: query)
    }

    public func find(byNumber number: String) -> Contact? {
        Contact.find(number: number, in: all())
    }

    /// nil when no contact has the number or two contacts have it equally well.
    public func findUnique(byNumber number: String) -> Contact? {
        Contact.findUnique(number: number, in: all())
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
        if e.contactID == nil, let c = contacts?.findUnique(byNumber: e.remoteNumber) { e.contactID = c.id }
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

    /// Remembers the recording of an entry (nil forgets it). An entry that is gone is ignored.
    public func setRecording(_ url: URL?, for id: UUID) throws {
        try store.update { list in
            if let i = list.firstIndex(where: { $0.id == id }) { list[i].recordingURL = url }
        }
    }
}

public final class SettingsStore: Sendable {
    private let store: JSONStore<AppSettings>
    public init(directory: URL) { store = JSONStore(directory: directory, name: "settings", default: .default) }
    public func load() -> AppSettings { store.load() }
    public func save(_ settings: AppSettings) throws { try store.save(settings) }
}
