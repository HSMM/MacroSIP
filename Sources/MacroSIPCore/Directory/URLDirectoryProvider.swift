import Foundation

/// A CSV or JSON file on a web server (or a `file://` URL). Fetched with URLSession, kept in memory for
/// `refreshMinutes`, revalidated with ETag / Last-Modified when the server sends them, searched locally.
/// When a refresh fails the previous copy is still searched.
public actor URLDirectoryProvider: DirectoryProvider {
    /// Fetches one request; returns the body and the HTTP response (nil for `file://`).
    public typealias Fetch = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse?)

    public nonisolated let sourceID: UUID
    private let config: URLConfig
    private let fetch: Fetch
    private let now: @Sendable () -> Date

    private var index: DirectoryIndex?
    private var etag: String?
    private var lastModified: String?
    private var inFlight: Task<Fetched, Error>?
    /// When the copy in memory was last fetched or revalidated.
    public private(set) var fetchedAt: Date?

    public init(source: DirectorySource, fetch: Fetch? = nil, now: @escaping @Sendable () -> Date = { Date() }) {
        sourceID = source.id
        config = source.url ?? URLConfig()
        self.fetch = fetch ?? URLDirectoryProvider.urlSessionFetch
        self.now = now
    }

    public static let urlSessionFetch: Fetch = { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, response as? HTTPURLResponse)
    }

    public func search(_ query: String, limit: Int) async throws -> [DirectoryEntry] {
        try await current().search(query, limit: limit)
    }

    public func lookup(number: String) async throws -> DirectoryEntry? {
        try await current().lookup(number)
    }

    public func test() async throws -> DirectoryTestResult {
        let idx = try await refresh(force: true)
        return .connected(entries: idx.count)
    }

    public func allEntries() async throws -> [DirectoryEntry] {
        try await refresh(force: true).entries
    }

    // MARK: Cache

    private func current() async throws -> DirectoryIndex {
        if let index, let at = fetchedAt, now().timeIntervalSince(at) < Double(config.refreshMinutes) * 60 { return index }
        do {
            return try await refresh(force: false)
        } catch {
            if let index { return index }       // stale copy beats nothing
            throw error
        }
    }

    private struct Fetched: Sendable {
        var index: DirectoryIndex?          // nil = 304 Not Modified
        var etag: String?
        var lastModified: String?
    }

    private func refresh(force: Bool) async throws -> DirectoryIndex {
        let task: Task<Fetched, Error>
        if let running = inFlight {
            task = running
        } else {
            let request = try makeRequest(conditional: !force && index != nil)
            let fetch = self.fetch, config = self.config, sourceID = self.sourceID
            task = Task {
                let (data, response) = try await fetch(request)
                if let http = response {
                    if http.statusCode == 304 { return Fetched(index: nil) }
                    guard (200..<300).contains(http.statusCode) else { throw DirectoryError.http(http.statusCode) }
                }
                let parsed = DirectoryIndex(try DirectoryFeedParser.parse(data, config: config, sourceID: sourceID))
                return Fetched(index: parsed, etag: response?.value(forHTTPHeaderField: "ETag"),
                               lastModified: response?.value(forHTTPHeaderField: "Last-Modified"))
            }
            inFlight = task
        }
        let fetched: Fetched
        do {
            fetched = try await task.value
        } catch {
            if inFlight == task { inFlight = nil }
            throw DirectoryError.from(error)
        }
        if inFlight == task {
            inFlight = nil
            if let fresh = fetched.index {
                index = fresh
                etag = fetched.etag
                lastModified = fetched.lastModified
            }
            fetchedAt = now()
        }
        return fetched.index ?? index ?? DirectoryIndex([])
    }

    private func makeRequest(conditional: Bool) throws -> URLRequest {
        let raw = config.url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(), ["http", "https", "file"].contains(scheme) else {
            throw DirectoryError.notConfigured(.badFeedURL)
        }
        var r = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        r.setValue(config.format == .json ? "application/json" : "text/csv, text/plain;q=0.9, */*;q=0.5", forHTTPHeaderField: "Accept")
        if conditional {
            if let etag { r.setValue(etag, forHTTPHeaderField: "If-None-Match") }
            if let lastModified { r.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since") }
        }
        return r
    }
}
