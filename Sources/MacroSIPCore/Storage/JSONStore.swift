import Foundation

/// Atomic JSON persistence for one value. Thread-safe.
public final class JSONStore<T: Codable & Sendable>: @unchecked Sendable {
    public let fileURL: URL
    private let directory: URL
    private let name: String
    private let defaultValue: T
    private let lock = NSLock()

    public init(directory: URL, name: String, default defaultValue: T) {
        self.directory = directory
        self.name = name
        self.fileURL = directory.appendingPathComponent("\(name).json")
        self.defaultValue = defaultValue
    }

    /// `~/Library/Application Support/MacroSIP/`, created on demand.
    public static func appSupportDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("MacroSIP", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    private static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    public func load() -> T {
        lock.lock(); defer { lock.unlock() }
        return loadLocked()
    }

    func loadLocked() -> T {
        let fm = FileManager.default
        guard fm.fileExists(atPath: fileURL.path) else { return defaultValue }
        do {
            let data = try Data(contentsOf: fileURL)
            return try Self.decoder().decode(T.self, from: data)
        } catch {
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            var broken = directory.appendingPathComponent("\(name).broken-\(stamp).json")
            var n = 1
            while fm.fileExists(atPath: broken.path) {
                broken = directory.appendingPathComponent("\(name).broken-\(stamp)-\(n).json")
                n += 1
            }
            try? fm.moveItem(at: fileURL, to: broken)
            return defaultValue
        }
    }

    public func save(_ value: T) throws {
        lock.lock(); defer { lock.unlock() }
        try saveLocked(value)
    }

    func saveLocked(_ value: T) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try Self.encoder().encode(value)
        let tmp = directory.appendingPathComponent(".\(name).\(UUID().uuidString).tmp")
        try data.write(to: tmp)
        do {
            if fm.fileExists(atPath: fileURL.path) {
                _ = try fm.replaceItemAt(fileURL, withItemAt: tmp)
            } else {
                try fm.moveItem(at: tmp, to: fileURL)
            }
        } catch {
            try? fm.removeItem(at: tmp)
            throw error
        }
    }

    /// Load, mutate and save under one lock. Returns the saved value.
    @discardableResult
    func update(_ body: (inout T) -> Void) throws -> T {
        lock.lock(); defer { lock.unlock() }
        var v = loadLocked()
        body(&v)
        try saveLocked(v)
        return v
    }
}
