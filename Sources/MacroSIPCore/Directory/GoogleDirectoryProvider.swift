import Foundation

/// Google Contacts through the People API (read-only). The tokens come from the Keychain
/// (`DirectoryCredentials.googleToken`, written by `GoogleOAuth.signIn`); without one every request
/// fails with `.signInRequired`.
///
/// - Search: `people:searchContacts` (server-side; a warm-up request with an empty query first, as Google
///   asks, when no search ran for 10 minutes).
/// - Import: `people/me/connections`, 1000 per page, following `nextPageToken`; non-default photos fetched.
/// - Lookup: a `DirectoryIndex` built from the connections (searchContacts does not match reformatted
///   numbers), refreshed every hour in the background while the stale copy answers (a failed refresh is
///   retried a minute later at the earliest).
/// - Tokens: refreshed 60 s before `expiresAt` and on 401; `invalid_grant` or a 401 that survives the refresh
///   deletes the token and throws `.signInRequired`. 15 s per request.
public actor GoogleDirectoryProvider: DirectoryProvider {
    public typealias Fetch = URLDirectoryProvider.Fetch

    public static let personFields = "names,phoneNumbers,organizations,emailAddresses,photos"
    /// searchContacts accepts at most 30.
    static let searchPageLimit = 30
    static let connectionsPageSize = 1000
    /// A new search session after this long without a search starts with a warm-up request.
    static let warmUpInterval: TimeInterval = 600
    /// A background refresh of the lookup index that failed is not tried again sooner.
    static let retryAfter: TimeInterval = 60

    public nonisolated let sourceID: UUID
    private let credentials: DirectoryCredentials
    private let oauth: GoogleOAuth
    private let fetch: Fetch
    private let now: @Sendable () -> Date
    private let endpoint: URL
    private let indexMaxAge: TimeInterval
    private let importPhotos: Bool

    private var index: DirectoryIndex?
    private var indexedAt: Date?
    private var indexing: (task: Task<DirectoryIndex, Error>, photos: Bool, generation: Int)?
    private var indexGeneration = 0
    private var indexFailedAt: Date?
    private var refreshing: Task<GoogleToken, Error>?
    private var lastSearchAt: Date?

    public init(source: DirectorySource, credentials: DirectoryCredentials, fetch: Fetch? = nil, oauth: GoogleOAuth? = nil,
                indexMaxAge: TimeInterval = 3600, importPhotos: Bool = true,
                endpoint: URL = GoogleOAuth.Configuration.peopleEndpoint, now: @escaping @Sendable () -> Date = { Date() }) {
        sourceID = source.id
        self.credentials = credentials
        let f = fetch ?? URLDirectoryProvider.urlSessionFetch
        self.fetch = f
        self.oauth = oauth ?? GoogleOAuth(credentials: credentials, fetch: f, now: now)
        self.now = now
        self.endpoint = endpoint
        self.indexMaxAge = indexMaxAge
        self.importPhotos = importPhotos
    }

    // MARK: DirectoryProvider

    public func search(_ query: String, limit: Int) async throws -> [DirectoryEntry] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, limit > 0 else { return [] }
        if lastSearchAt.map({ now().timeIntervalSince($0) > Self.warmUpInterval }) ?? true {
            _ = try await get("people:searchContacts", [("query", ""), ("readMask", "names")])
        }
        lastSearchAt = now()
        let data = try await get("people:searchContacts", [
            ("query", q), ("pageSize", String(min(limit, Self.searchPageLimit))), ("readMask", Self.personFields),
        ])
        let found = try GooglePeople.decode(GooglePeople.SearchResponse.self, from: data)
        let id = sourceID
        return Array((found.results ?? []).compactMap { $0.person.flatMap { GooglePeople.entry($0, sourceID: id) } }.prefix(limit))
    }

    public func lookup(number: String) async throws -> DirectoryEntry? {
        guard !DirectoryNumber.digits(number).isEmpty else { return nil }
        if let index, let at = indexedAt {
            // The stale copy answers now; a refresh runs in the background (after a failure, not before `retryAfter`).
            let pausedUntil = indexFailedAt.map { $0.addingTimeInterval(Self.retryAfter) }
            if now().timeIntervalSince(at) >= indexMaxAge, now() >= (pausedUntil ?? .distantPast) { _ = startIndexing(photos: false) }
            return index.lookup(number)
        }
        return try await rebuildIndex(photos: false).lookup(number)
    }

    public func test() async throws -> DirectoryTestResult {
        let data = try await get("people/me/connections", [("personFields", "names"), ("pageSize", "1")])
        let page = try GooglePeople.decode(GooglePeople.ConnectionsResponse.self, from: data)
        return .connected(entries: page.totalPeople)
    }

    public func allEntries() async throws -> [DirectoryEntry] {
        try await rebuildIndex(photos: importPhotos).entries
    }

    // MARK: Index

    /// The index of all connections, fetched now. Concurrent callers share one fetch; a lookup that needs the
    /// index while an import runs waits for the import.
    private func rebuildIndex(photos: Bool) async throws -> DirectoryIndex {
        do { return try await startIndexing(photos: photos).value } catch { throw DirectoryError.from(error) }
    }

    /// Starts (or joins) a fetch of all connections; the task stores the index when it is done.
    private func startIndexing(photos: Bool) -> Task<DirectoryIndex, Error> {
        if let running = indexing, running.photos || !photos { return running.task }
        indexGeneration += 1
        let generation = indexGeneration
        let task = Task { [self] in
            defer { if indexing?.generation == generation { indexing = nil } }
            do {
                let fresh = try await fetchAll(photos: photos)
                index = fresh
                indexedAt = now()
                indexFailedAt = nil
                return fresh
            } catch {
                indexFailedAt = now()
                throw error
            }
        }
        indexing = (task, photos, generation)
        return task
    }

    private func fetchAll(photos: Bool) async throws -> DirectoryIndex {
        var entries: [DirectoryEntry] = []
        var photoURLs: [String: URL] = [:]
        var pageToken: String?
        for _ in 0..<200 {
            var items = [("personFields", Self.personFields), ("pageSize", String(Self.connectionsPageSize))]
            if let pageToken { items.append(("pageToken", pageToken)) }
            let data = try await get("people/me/connections", items)
            let page = try GooglePeople.decode(GooglePeople.ConnectionsResponse.self, from: data)
            for person in page.connections ?? [] {
                guard let e = GooglePeople.entry(person, sourceID: sourceID) else { continue }
                entries.append(e)
                if photos, let url = GooglePeople.photoURL(person) { photoURLs[e.id] = url }
            }
            guard let next = page.nextPageToken, !next.isEmpty else { break }
            pageToken = next
        }
        if !photoURLs.isEmpty { entries = await Self.withPhotos(entries, urls: photoURLs, fetch: fetch) }
        return DirectoryIndex(entries)
    }

    /// Fetches the photos (four at a time; a failure leaves the entry without one).
    static func withPhotos(_ entries: [DirectoryEntry], urls: [String: URL], fetch: @escaping Fetch) async -> [DirectoryEntry] {
        let photos = await withTaskGroup(of: (String, Data?).self, returning: [String: Data].self) { group in
            var out: [String: Data] = [:]
            var running = 0
            for (id, url) in urls {
                if running >= 4, let (k, d) = await group.next() {
                    running -= 1
                    if let d { out[k] = d }
                }
                group.addTask {
                    let r = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 15)
                    guard let (data, http) = try? await fetch(r), !data.isEmpty,
                          http.map({ (200..<300).contains($0.statusCode) }) ?? true else { return (id, nil) }
                    return (id, data)
                }
                running += 1
            }
            for await (k, d) in group { if let d { out[k] = d } }
            return out
        }
        return entries.map { e in
            var e = e
            e.photo = photos[e.id]
            return e
        }
    }

    // MARK: Requests and tokens

    /// GET `path` under the People API endpoint with a valid access token; refreshes it once on 401. A 401
    /// that survives the refresh deletes the stored token (the source shows "Sign in required").
    private func get(_ path: String, _ query: [(String, String)]) async throws -> Data {
        var token = try await accessToken(renew: false)
        var (data, http) = try await send(path, query, token: token)
        if http?.statusCode == 401 {
            token = try await accessToken(renew: true)
            (data, http) = try await send(path, query, token: token)
            if http?.statusCode == 401 {
                try? credentials.setGoogleToken(nil, for: sourceID)
                throw DirectoryError.signInRequired
            }
        }
        if let http { try Self.check(http, data) }
        return data
    }

    private func send(_ path: String, _ query: [(String, String)], token: String) async throws -> (Data, HTTPURLResponse?) {
        guard var c = URLComponents(string: endpoint.absoluteString + path) else { throw DirectoryError.unsupportedSource }
        c.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) }
        guard let url = c.url else { throw DirectoryError.unsupportedSource }
        var r = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        r.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        do { return try await fetch(r) } catch { throw DirectoryError.from(error) }
    }

    /// 2xx passes; 401 means the token is not accepted; other errors carry Google's message when there is one.
    static func check(_ http: HTTPURLResponse, _ data: Data) throws {
        guard !(200..<300).contains(http.statusCode) else { return }
        if http.statusCode == 401 { throw DirectoryError.signInRequired }
        if let message = (try? JSONDecoder().decode(GooglePeople.APIError.self, from: data))?.error?.message, !message.isEmpty {
            throw DirectoryError.server(message)
        }
        throw DirectoryError.http(http.statusCode)
    }

    /// The stored access token, renewed when it expires within a minute (or when `renew` says so).
    private func accessToken(renew: Bool) async throws -> String {
        guard let token = (try? credentials.googleToken(for: sourceID)) ?? nil else { throw DirectoryError.signInRequired }
        let expiring = token.expiresAt.map { $0.timeIntervalSince(now()) < 60 } ?? false
        guard renew || expiring else { return token.accessToken }
        return try await renewToken(token).accessToken
    }

    /// One refresh at a time; callers that arrive meanwhile share it.
    private func renewToken(_ token: GoogleToken) async throws -> GoogleToken {
        if let running = refreshing { return try await running.value }
        let oauth = self.oauth, id = sourceID
        let task = Task { try await oauth.refresh(token, sourceID: id) }
        refreshing = task
        defer { if refreshing == task { refreshing = nil } }
        return try await task.value
    }
}

// MARK: - People API JSON

/// The parts of a People API `Person` the directory uses, decoded tolerantly (every field optional).
enum GooglePeople {
    struct Metadata: Decodable, Sendable { var primary: Bool? }
    struct Name: Decodable, Sendable {
        var displayName: String?
        var givenName: String?
        var familyName: String?
        var metadata: Metadata?
    }
    struct Phone: Decodable, Sendable {
        var value: String?
        var canonicalForm: String?
        var type: String?
        var metadata: Metadata?
    }
    struct Organization: Decodable, Sendable {
        var name: String?
        var title: String?
        var metadata: Metadata?
    }
    struct Email: Decodable, Sendable {
        var value: String?
        var metadata: Metadata?
    }
    struct Photo: Decodable, Sendable {
        var url: String?
        var isDefault: Bool?
        var metadata: Metadata?
        enum CodingKeys: String, CodingKey { case url, isDefault = "default", metadata }
    }
    struct Person: Decodable, Sendable {
        var resourceName: String?
        var names: [Name]?
        var phoneNumbers: [Phone]?
        var organizations: [Organization]?
        var emailAddresses: [Email]?
        var photos: [Photo]?
    }
    struct SearchResult: Decodable, Sendable { var person: Person? }
    struct SearchResponse: Decodable, Sendable { var results: [SearchResult]? }
    struct ConnectionsResponse: Decodable, Sendable {
        var connections: [Person]?
        var nextPageToken: String?
        var totalPeople: Int?
        var totalItems: Int?
    }
    struct APIError: Decodable, Sendable {
        struct Body: Decodable, Sendable {
            var code: Int?
            var message: String?
            var status: String?
        }
        var error: Body?
    }

    static let idPrefix = "google:"

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw DirectoryError.server("Unexpected answer from the People API") }
    }

    /// A person with at least one number; the primary number first and default. Name: the primary name's
    /// display name, else given and family name, else the organization, else the number.
    static func entry(_ p: Person, sourceID: UUID) -> DirectoryEntry? {
        var numbers: [PhoneNumber] = []
        var primaryIndex: Int?
        for ph in p.phoneNumbers ?? [] {
            let value = (ph.value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }
            if ph.metadata?.primary == true, primaryIndex == nil { primaryIndex = numbers.count }
            numbers.append(PhoneNumber(label: label(ph.type), value: value))
        }
        guard !numbers.isEmpty else { return nil }
        if let i = primaryIndex, i != 0 { numbers.insert(numbers.remove(at: i), at: 0) }
        numbers[0].isDefault = true
        let org = clean(primary(p.organizations)?.name)
        let name = primary(p.names)
        var display = clean(name?.displayName)
            ?? clean([name?.givenName, name?.familyName].compactMap { clean($0) }.joined(separator: " "))
        if display == nil { display = org ?? numbers[0].value }
        let id = idPrefix + (clean(p.resourceName) ?? numbers[0].value)
        return DirectoryEntry(id: id, sourceID: sourceID, sourceKind: .google, displayName: display ?? "", numbers: numbers,
                              organization: org, email: primaryEmail(p))
    }

    static func primaryEmail(_ p: Person) -> String? {
        clean(primary(p.emailAddresses)?.value)
    }

    /// The URL of a photo the user set (Google's default silhouettes are skipped).
    static func photoURL(_ p: Person) -> URL? {
        let real = (p.photos ?? []).filter { $0.isDefault != true && !(clean($0.url) ?? "").isEmpty }
        let pick = real.first { $0.metadata?.primary == true } ?? real.first
        return pick.flatMap { URL(string: $0.url!) }
    }

    /// People API phone types → the app's labels.
    static func label(_ type: String?) -> PhoneLabel {
        switch (type ?? "").lowercased() {
        case "mobile", "workmobile", "googlevoice": return .mobile
        case "work", "main", "workfax", "workpager": return .work
        case "home", "homefax": return .home
        default: return .other
        }
    }

    private static func primary<T>(_ list: [T]?) -> T? where T: PrimaryMarked {
        guard let list, !list.isEmpty else { return nil }
        return list.first { $0.metadata?.primary == true } ?? list[0]
    }

    private static func clean(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }
}

private protocol PrimaryMarked { var metadata: GooglePeople.Metadata? { get } }
extension GooglePeople.Name: PrimaryMarked {}
extension GooglePeople.Organization: PrimaryMarked {}
extension GooglePeople.Email: PrimaryMarked {}
