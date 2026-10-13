import Foundation

/// The quick keys and their panel settings as a file of their own (`quickkeys.json`), for tools that edit
/// the list without the rest of the settings. The app keeps the live copy in `AppSettings.quickKeys`.
/// Every mutation normalises the list: empty rows dropped, at most `QuickKeysSettings.maxKeys` keys.
public final class QuickKeyStore: Sendable {
    private let store: JSONStore<QuickKeysSettings>
    public init(directory: URL) { store = JSONStore(directory: directory, name: "quickkeys", default: QuickKeysSettings()) }

    public func load() -> QuickKeysSettings { store.load() }
    public func keys() -> [QuickKey] { store.load().keys }

    public func save(_ settings: QuickKeysSettings) throws {
        var s = settings
        s.normalize()
        try store.save(s)
    }

    /// Replaces the key with the same id, or appends it. Throws nothing when the list is full: the key is dropped.
    public func upsert(_ key: QuickKey) throws {
        try mutate { s in
            if let i = s.keys.firstIndex(where: { $0.id == key.id }) { s.keys[i] = key } else { s.add(key) }
        }
    }

    public func remove(_ id: UUID) throws { try mutate { $0.remove(id) } }
    public func move(from: Int, to: Int) throws { try mutate { $0.move(from: from, to: to) } }

    private func mutate(_ body: (inout QuickKeysSettings) -> Void) throws {
        try store.update { s in
            body(&s)
            s.normalize()
        }
    }
}
