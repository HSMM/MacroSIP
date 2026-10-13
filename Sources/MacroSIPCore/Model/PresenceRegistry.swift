import Foundation

/// Who watches which presence target. Contacts and quick keys share one engine subscription per target:
/// a target is subscribed when its first owner asks and unsubscribed when the last owner is gone.
/// Targets are identified by `key(_:)`, so "sip:102@pbx;transport=tls" and "102@PBX" are one target; the
/// engine is given the spelling of the first owner.
public struct PresenceRegistry: Sendable {
    public struct Watch: Equatable, Sendable {
        public var key: String
        public var uri: String
    }

    /// What has to be done in the engine after a change.
    public struct Change: Equatable, Sendable {
        public var subscribe: [Watch] = []
        public var unsubscribe: [Watch] = []
        public var isEmpty: Bool { subscribe.isEmpty && unsubscribe.isEmpty }
    }

    private struct Entry: Sendable {
        var uri: String
        var owners: Set<String>
    }

    private var entries: [String: Entry] = [:]
    private var failed: Set<String> = []

    public init() {}

    /// Lower case, no scheme, no URI parameters ("102@pbx.example.com").
    public static func key(_ uri: String) -> String {
        var s = uri.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if s.hasPrefix("<"), s.hasSuffix(">") { s = String(s.dropFirst().dropLast()) }
        for scheme in ["sips:", "sip:"] where s.hasPrefix(scheme) { s.removeFirst(scheme.count); break }
        if let semicolon = s.firstIndex(of: ";") { s = String(s[..<semicolon]) }
        return s
    }

    public var count: Int { entries.count }
    public func isWatched(_ uri: String) -> Bool { entries[Self.key(uri)] != nil }
    public func owners(of uri: String) -> Set<String> { entries[Self.key(uri)]?.owners ?? [] }

    /// Replaces the targets `owner` watches. Returns the engine work: targets nobody watched before, and
    /// targets nobody watches any more.
    public mutating func setWatches(owner: String, uris: [String]) -> Change {
        var change = Change()
        var wanted: [String: String] = [:]
        for uri in uris {
            let k = Self.key(uri)
            if !k.isEmpty, wanted[k] == nil { wanted[k] = uri.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        for (k, uri) in wanted.sorted(by: { $0.key < $1.key }) {
            if var e = entries[k] {
                e.owners.insert(owner)
                entries[k] = e
            } else {
                entries[k] = Entry(uri: uri, owners: [owner])
                change.subscribe.append(Watch(key: k, uri: uri))
            }
        }
        for (k, e) in entries.sorted(by: { $0.key < $1.key }) where e.owners.contains(owner) && wanted[k] == nil {
            var e = e
            e.owners.remove(owner)
            if e.owners.isEmpty {
                entries[k] = nil
                failed.remove(k)
                change.unsubscribe.append(Watch(key: k, uri: e.uri))
            } else {
                entries[k] = e
            }
        }
        return change
    }

    /// The engine lost its subscriptions (restart). Owners must ask again.
    public mutating func reset() {
        entries = [:]
        failed = []
    }

    /// A subscribe failed. true the first time for a target (log it then), false after.
    public mutating func reportFailure(key: String) -> Bool {
        guard entries[key] != nil else { return false }
        return failed.insert(key).inserted
    }
}
