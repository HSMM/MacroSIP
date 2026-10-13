import Foundation
import os

/// What `DirectoryService.searchUpdates` reports while sources answer (SCREENS.md 13: "Searching <source>…"
/// rows, results added as they arrive, then the result count).
public enum DirectorySearchUpdate: Equatable, Sendable {
    /// The sources being asked, in result order. Empty when nothing is searched.
    case started([UUID])
    /// One source answered (possibly with no entries).
    case results(sourceID: UUID, entries: [DirectoryEntry])
    /// A source failed or did not answer in time; it is skipped.
    case failed(sourceID: UUID)
    /// Every source answered or the time limit passed. The stream ends after this.
    case finished
}

/// Searches the directory sources of Settings › Directory.
///
/// - `search` asks every enabled source at once (`resultsPerSource` each), waits at most `searchTimeout`
///   (3 s) and returns what arrived, in source order. The 300 ms typing pause is the caller's job.
/// - `lookup` asks the enabled search-only sources for a ringing caller for at most `lookupTimeout` (1 s);
///   imported sources are already in Contacts.
/// - Sources in "Sign in required" are not asked until their settings change or a test succeeds; a source
///   that failed is skipped for `retryAfter` (60 s), then tried again.
/// - Status changes are published on `events`.
public actor DirectoryService {
    public typealias ProviderFactory = @Sendable (DirectorySource, DirectoryCredentials) -> (any DirectoryProvider)?

    public nonisolated let events: AsyncStream<DirectoryEvent>
    private nonisolated let eventSink: AsyncStream<DirectoryEvent>.Continuation

    public let credentials: DirectoryCredentials
    private let googleOAuth: GoogleOAuth
    private let makeProvider: ProviderFactory
    private let searchTimeout: TimeInterval
    private let lookupTimeout: TimeInterval
    private let retryAfter: TimeInterval

    private(set) var settings: DirectorySettings
    private var providers: [UUID: (source: DirectorySource, provider: any DirectoryProvider)] = [:]
    private var statuses: [UUID: DirectorySourceStatus] = [:]
    private var failedAt: [UUID: Date] = [:]

    /// `credentials` replaces the Keychain-backed ones (tests, demos); `googleOAuth` runs `signInGoogle`
    /// (by default `GoogleOAuth(credentials:)` with the build's client id).
    public init(settings: DirectorySettings, keychain: Keychain = Keychain(), credentials: DirectoryCredentials? = nil,
                makeProvider: ProviderFactory? = nil, googleOAuth: GoogleOAuth? = nil,
                searchTimeout: TimeInterval = 3, lookupTimeout: TimeInterval = 1, retryAfter: TimeInterval = 60) {
        (events, eventSink) = AsyncStream.makeStream(of: DirectoryEvent.self, bufferingPolicy: .bufferingNewest(64))
        let creds = credentials ?? DirectoryCredentials(keychain: keychain)
        self.credentials = creds
        self.googleOAuth = googleOAuth ?? GoogleOAuth(credentials: creds)
        self.makeProvider = makeProvider ?? DirectoryService.defaultProvider
        self.searchTimeout = searchTimeout
        self.lookupTimeout = lookupTimeout
        self.retryAfter = retryAfter
        self.settings = settings
        let factory = self.makeProvider
        for s in settings.sources {
            guard let p = factory(s, creds) else { continue }
            providers[s.id] = (s, p)
            if Self.needsSignIn(s, creds) {
                statuses[s.id] = .signInRequired
                eventSink.yield(.sourceStatus(id: s.id, status: .signInRequired))
            }
        }
    }

    /// A Google source without a stored token is not asked until `signInGoogle` succeeds.
    private static func needsSignIn(_ s: DirectorySource, _ credentials: DirectoryCredentials) -> Bool {
        s.kind == .google && ((try? credentials.googleToken(for: s.id)) ?? nil) == nil
    }

    deinit { eventSink.finish() }

    /// The built-in providers.
    public static let defaultProvider: ProviderFactory = { source, credentials in
        switch source.kind {
        case .macContacts: return MacContactsProvider(source: source)
        case .ldap: return LDAPDirectoryProvider(source: source, credentials: credentials)
        case .url: return URLDirectoryProvider(source: source)
        case .google: return GoogleDirectoryProvider(source: source, credentials: credentials)
        }
    }

    // MARK: Settings and status

    public func update(settings new: DirectorySettings) {
        let ids = Set(new.sources.map(\.id))
        for id in providers.keys where !ids.contains(id) {
            providers[id] = nil
            statuses[id] = nil
            failedAt[id] = nil
        }
        for s in new.sources {
            if let old = providers[s.id]?.source, Self.sameConnection(old, s) {
                providers[s.id]?.source = s
            } else {
                install(s)
            }
        }
        settings = new
    }

    /// The last known status of each source (sources never asked are missing).
    public func currentStatuses() -> [UUID: DirectorySourceStatus] { statuses }

    /// Enabled sources the number field would ask now, in result order.
    public func searchableSources() -> [DirectorySource] { targets(searchOnly: false).map(\.source) }

    private func install(_ s: DirectorySource) {
        failedAt[s.id] = nil
        statuses[s.id] = nil
        guard let p = makeProvider(s, credentials) else { providers[s.id] = nil; return }
        providers[s.id] = (s, p)
        if Self.needsSignIn(s, credentials) { setStatus(.signInRequired, for: s.id) }
    }

    /// Whether the provider of `a` still serves `b`. A Google source is identified by its id (the token is
    /// keyed by it) and `GoogleConfig.accountEmail` is display only, so it never rebuilds the provider.
    private static func sameConnection(_ a: DirectorySource, _ b: DirectorySource) -> Bool {
        a.kind == b.kind && a.ldap == b.ldap && a.url == b.url
    }

    private func setStatus(_ status: DirectorySourceStatus, for id: UUID) {
        guard statuses[id] != status else { return }
        statuses[id] = status
        eventSink.yield(.sourceStatus(id: id, status: status))
    }

    private func markSuccess(_ id: UUID) async {
        failedAt[id] = nil
        guard let entry = providers[id] else { return }
        if let url = entry.provider as? URLDirectoryProvider, let at = await url.fetchedAt {
            setStatus(.syncedAt(at), for: id)
        } else if case .syncedAt = statuses[id] {
            // an imported source keeps "Synced N min ago"
        } else {
            setStatus(.connected, for: id)
        }
    }

    private func markFailure(_ id: UUID, _ error: DirectoryError) {
        guard providers[id] != nil else { return }          // a late answer of a removed source
        if error == .cancelled { return }                   // the caller gave up; the source is not at fault
        failedAt[id] = Date()
        setStatus(error.status, for: id)
    }

    private func targets(searchOnly: Bool) -> [(source: DirectorySource, provider: any DirectoryProvider)] {
        let now = Date()
        return settings.sources.compactMap { s in
            guard s.isEnabled, !(searchOnly && s.importIntoContacts), let p = providers[s.id]?.provider else { return nil }
            if statuses[s.id] == .signInRequired { return nil }
            if let t = failedAt[s.id], now.timeIntervalSince(t) < retryAfter { return nil }
            return (s, p)
        }
    }

    // MARK: Search

    public func search(_ query: String) async -> [DirectoryEntry] {
        await search(query, progress: nil)
    }

    /// `search` reported source by source.
    public nonisolated func searchUpdates(_ query: String) -> AsyncStream<DirectorySearchUpdate> {
        AsyncStream { cont in
            let task = Task {
                _ = await self.search(query, progress: { cont.yield($0) })
                cont.finish()
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }

    private func search(_ query: String, progress: (@Sendable (DirectorySearchUpdate) -> Void)?) async -> [DirectoryEntry] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let list = (settings.searchFromNumberField && q.count >= settings.minimumQueryLength) ? targets(searchOnly: false) : []
        progress?(.started(list.map(\.source.id)))
        defer { progress?(.finished) }
        guard !list.isEmpty else { return [] }
        let limit = settings.resultsPerSource
        let ids = list.map(\.source.id)
        let results = await FanOut<[DirectoryEntry]>.run(
            list.map(\.provider), timeout: searchTimeout,
            operation: { p in try await p.search(q, limit: limit) },
            isComplete: { r, n in r.count == n },
            onResult: { i, r in
                switch r {
                case .success(let e): progress?(.results(sourceID: ids[i], entries: Array(e.prefix(limit))))
                case .failure: progress?(.failed(sourceID: ids[i]))
                }
            })
        for i in ids.indices where results[i] == nil { progress?(.failed(sourceID: ids[i])) }
        await record(results, ids: ids)
        return ids.indices.flatMap { i -> [DirectoryEntry] in
            if case .success(let e)? = results[i] { return Array(e.prefix(limit)) }
            return []
        }
    }

    // MARK: Lookup

    /// The caller's entry in the first search-only source (in source order) that knows the number.
    public func lookup(number: String) async -> DirectoryEntry? {
        guard settings.lookupIncomingCallers, !DirectoryNumber.digits(number).isEmpty else { return nil }
        let list = targets(searchOnly: true)
        guard !list.isEmpty else { return nil }
        let ids = list.map(\.source.id)
        let results = await FanOut<DirectoryEntry?>.run(
            list.map(\.provider), timeout: lookupTimeout,
            operation: { p in try await p.lookup(number: number) },
            isComplete: { r, n in
                // Done when the earliest source with a match has no unanswered source before it.
                for i in 0..<n {
                    guard let ri = r[i] else { return false }
                    if case .success(.some) = ri { return true }
                }
                return true
            },
            onResult: { _, _ in })
        await record(results, ids: ids)
        for i in ids.indices { if case .success(let e?)? = results[i] { return e } }
        return nil
    }

    private func record<T>(_ results: [Int: Result<T, DirectoryError>], ids: [UUID]) async {
        for (i, r) in results {
            switch r {
            case .success: await markSuccess(ids[i])
            case .failure(let e): markFailure(ids[i], e)
            }
        }
    }

    // MARK: Test, sign-in and import

    /// Connects with `source` as configured (it may be a draft of the sheet). Updates the status of a saved
    /// source with the same id. `ldapPassword` is the one typed in the sheet: used for this test only, not stored.
    public func test(source: DirectorySource, ldapPassword: String? = nil) async -> DirectoryTestResult {
        let creds = ldapPassword.map { credentials.overriding(ldapPassword: $0, for: source.id) } ?? credentials
        guard let p = makeProvider(source, creds) else {
            return DirectoryTestResult(status: .error(.unsupportedSource))
        }
        let result: DirectoryTestResult
        do { result = try await p.test() }
        catch { result = DirectoryTestResult(status: DirectoryError.from(error).status) }
        if providers[source.id] != nil {
            if result.isSuccess {
                failedAt[source.id] = nil
                setStatus(.connected, for: source.id)
            } else {
                if case .error = result.status { failedAt[source.id] = Date() }
                setStatus(result.status, for: source.id)
            }
        }
        return result
    }

    /// Signs in to Google for the source (saved or still a draft of the sheet): `openURL` receives the
    /// authorization URL to open in the browser; the flow waits for the redirect (2 minutes at most, cancellable),
    /// stores the tokens in the Keychain under the source id and returns the account e-mail, which the caller
    /// keeps in `GoogleConfig.accountEmail`. A saved source becomes "Connected". Throws
    /// `.notConfigured(.googleClientID)` in a build without a client id.
    public func signInGoogle(sourceID: UUID, openURL: @Sendable (URL) -> Void) async throws -> String {
        let email = try await googleOAuth.signIn(sourceID: sourceID, openURL: openURL)
        if providers[sourceID] != nil {
            failedAt[sourceID] = nil
            setStatus(.connected, for: sourceID)
        }
        return email
    }

    /// Every entry of `source` as a Contact (no ids shared with the address book; `Contact.importedFrom` names
    /// the source). Sets the status to "Synced" on success.
    public func importAll(source: DirectorySource) async throws -> [Contact] {
        let provider: any DirectoryProvider
        if let p = providers[source.id], Self.sameConnection(p.source, source) { provider = p.provider }
        else if let p = makeProvider(source, credentials) { provider = p }
        else { throw DirectoryError.unsupportedSource }
        do {
            let entries = try await provider.allEntries()
            let contacts = entries.map { $0.makeContact(imported: true) }
            if providers[source.id] != nil {
                failedAt[source.id] = nil
                setStatus(.syncedAt(Date()), for: source.id)
            }
            return contacts
        } catch {
            let e = DirectoryError.from(error)
            if providers[source.id] != nil { markFailure(source.id, e) }
            throw e
        }
    }

    /// How often an imported source is refreshed: a URL source on its own schedule, the others daily.
    public nonisolated static func importInterval(for source: DirectorySource) -> TimeInterval {
        if source.kind == .url, let m = source.url?.refreshMinutes { return TimeInterval(max(1, m)) * 60 }
        return 24 * 3600
    }

    public nonisolated static func isImportDue(_ source: DirectorySource, lastSync: Date?, now: Date = Date()) -> Bool {
        guard source.isEnabled, source.importIntoContacts else { return false }
        guard let lastSync else { return true }
        return now.timeIntervalSince(lastSync) >= importInterval(for: source)
    }
}

/// Runs one operation on several providers at once and returns when `isComplete` says so, when the time
/// limit passes or when the calling task is cancelled, whichever comes first. Late answers are dropped.
final class FanOut<T: Sendable>: Sendable {
    typealias Results = [Int: Result<T, DirectoryError>]

    private struct State: Sendable {
        var results: Results = [:]
        var continuation: CheckedContinuation<Results, Never>?
        var done = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let count: Int
    private let isComplete: @Sendable (Results, Int) -> Bool
    private let onResult: @Sendable (Int, Result<T, DirectoryError>) -> Void

    private init(count: Int, isComplete: @escaping @Sendable (Results, Int) -> Bool,
                 onResult: @escaping @Sendable (Int, Result<T, DirectoryError>) -> Void) {
        self.count = count
        self.isComplete = isComplete
        self.onResult = onResult
    }

    static func run(_ providers: [any DirectoryProvider], timeout: TimeInterval,
                    operation: @escaping @Sendable (any DirectoryProvider) async throws -> T,
                    isComplete: @escaping @Sendable (Results, Int) -> Bool,
                    onResult: @escaping @Sendable (Int, Result<T, DirectoryError>) -> Void) async -> Results {
        let fan = FanOut(count: providers.count, isComplete: isComplete, onResult: onResult)
        let tasks = OSAllocatedUnfairLock<[Task<Void, Never>]>(initialState: [])
        let results = await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Results, Never>) in
                let finished = fan.state.withLock { s -> Bool in
                    if s.done { return true }           // cancelled before we got here
                    s.continuation = cont
                    return false
                }
                if finished { cont.resume(returning: [:]); return }
                var started: [Task<Void, Never>] = []
                for (i, p) in providers.enumerated() {
                    started.append(Task.detached {
                        let r: Result<T, DirectoryError>
                        do { r = .success(try await operation(p)) }
                        catch { r = .failure(DirectoryError.from(error)) }
                        fan.add(i, r)
                    })
                }
                started.append(Task.detached {
                    try? await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
                    fan.finish()
                })
                let all = started
                tasks.withLock { $0 = all }
                if providers.isEmpty { fan.finish() }
            }
        } onCancel: {
            fan.finish()
        }
        for t in tasks.withLock({ $0 }) { t.cancel() }
        return results
    }

    private func add(_ i: Int, _ r: Result<T, DirectoryError>) {
        // `onResult` runs under the lock so no report comes after the caller has its results.
        let resume: (CheckedContinuation<Results, Never>, Results)? = state.withLock { s in
            guard !s.done else { return nil }
            s.results[i] = r
            onResult(i, r)
            guard isComplete(s.results, count), let c = s.continuation else { return nil }
            s.done = true
            s.continuation = nil
            return (c, s.results)
        }
        if let (c, results) = resume { c.resume(returning: results) }
    }

    private func finish() {
        let resume: (CheckedContinuation<Results, Never>, Results)? = state.withLock { s in
            guard !s.done else { return nil }
            s.done = true
            // Cancelled before the continuation was installed: `run` installs it and finds `done`.
            guard let c = s.continuation else { return nil }
            s.continuation = nil
            return (c, s.results)
        }
        if let (c, results) = resume { c.resume(returning: results) }
    }
}
