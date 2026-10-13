import SwiftUI
import AppKit
import MacroSIPCore

/// One source's rows in the number field's suggestion list.
struct DirectorySection: Identifiable, Equatable {
    var sourceID: UUID
    var sourceName: String
    var sourceKind: DirectorySourceKind
    var entries: [DirectoryEntry]
    var id: UUID { sourceID }
}

/// Result line of "Import now".
struct DirectoryImportReport: Equatable {
    var text: String
    var isError: Bool
}

/// UI-side state of the directory feature (screen 13) that is not a setting.
@MainActor @Observable
final class DirectoryRuntime {
    /// Results that belong to `query`, in source order.
    var sections: [DirectorySection] = []
    var query = ""
    /// Sources that have not answered the running search (the "Searching <source>…" rows).
    var pending: [DirectorySource] = []
    /// Sources asked by the last search, and how many of them answered.
    var asked = 0
    /// The user closed the list with Escape; it stays closed until the text changes.
    var dismissed = false
    /// The number a click put into the field: it is not searched again.
    var suppressedText: String?
    var statuses: [UUID: DirectorySourceStatus] = [:]
    /// The selected row of Settings › Directory.
    var selectedSource: UUID?
    /// The source sheet (Settings › Directory).
    var editor: DirectoryEditorRequest?
    /// Why the last Google sign-in of a source failed, shown under the source until the next attempt.
    var signInMessages: [UUID: String] = [:]
    /// Sources whose Google sign-in is running (the browser is open).
    var signingIn: Set<UUID> = []
    var importing: Set<UUID> = []
    var reports: [UUID: DirectoryImportReport] = [:]
    /// Names found for callers that are not in Contacts, by `Contact.normalize(number)`; the newest 64.
    var callerNames: [String: String] = [:]
    @ObservationIgnored var callerOrder: [String] = []

    @ObservationIgnored var backend: (any DirectoryBackend)?
    @ObservationIgnored var searchTask: Task<Void, Never>?
    @ObservationIgnored var eventTask: Task<Void, Never>?
    @ObservationIgnored var importTask: Task<Void, Never>?
    @ObservationIgnored var signInTask: Task<Void, Never>?
    @ObservationIgnored var reportTasks: [UUID: Task<Void, Never>] = [:]

    init() {}

    var isSearching: Bool { !pending.isEmpty }
}

extension AppModel {
    // MARK: - Backend

    /// The directory service, created on first use (demo launches get the in-process mock).
    var directoryBackend: any DirectoryBackend {
        if let b = directory.backend { return b }
        let b: any DirectoryBackend
        #if DEBUG
        b = launch.isDemo ? MockDirectory(settings: settings.directory) : LiveDirectory(settings: settings.directory)
        #else
        b = LiveDirectory(settings: settings.directory)
        #endif
        directory.backend = b
        let stream = b.events
        directory.eventTask = Task { @MainActor [weak self] in
            for await event in stream {
                if case let .sourceStatus(id, status) = event { self?.directory.statuses[id] = status }
            }
        }
        return b
    }

    /// At launch: the service starts, so imported sources sync and statuses fill in.
    func startDirectory() {
        guard !settings.directory.sources.isEmpty else { return }
        _ = directoryBackend
        startDirectoryImportSchedule()
    }

    /// Imported sources are refreshed daily (a URL source on its own schedule): checked shortly after launch
    /// and every 15 minutes. The time of the last import is kept in the app's defaults.
    private func startDirectoryImportSchedule() {
        guard !launch.isDemo, directory.importTask == nil else { return }
        directory.importTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(8))
            while !Task.isCancelled {
                self?.importDueDirectorySources()
                try? await Task.sleep(for: .seconds(15 * 60))
            }
        }
    }

    private func lastDirectoryImport(_ id: UUID) -> Date? { prefs.object(forKey: "directoryLastImport.\(id.uuidString)") as? Date }

    func importDueDirectorySources() {
        for source in settings.directory.sources where !directory.importing.contains(source.id) {
            guard DirectoryService.isImportDue(source, lastSync: lastDirectoryImport(source.id)) else { continue }
            // A source that failed last time is tried again (the last import time is set only on success); one
            // that needs a sign-in is not.
            guard directory.statuses[source.id] != .signInRequired else { continue }
            // macOS Contacts asks for access only when the user presses Allow access, never in the background.
            if source.kind == .macContacts, MacContactsProvider.access != .granted { continue }
            importDirectory(source)
        }
    }

    /// A settings change reaches the service.
    func directorySettingsChanged() {
        guard directory.backend != nil || !settings.directory.sources.isEmpty else { return }
        let backend = directoryBackend
        startDirectoryImportSchedule()
        let s = settings.directory
        Task { await backend.update(settings: s) }
        let alive = Set(s.sources.map(\.id))
        directory.statuses = directory.statuses.filter { alive.contains($0.key) }
        textChangedForDirectory(dialText)
    }

    var directorySources: [DirectorySource] { settings.directory.sources }

    /// Sources switched on; the service itself skips the ones that need a sign-in or failed a moment ago.
    var activeDirectorySources: [DirectorySource] { settings.directory.sources.filter(\.isEnabled) }

    /// Whether a search needs the network: not when every enabled source is on this Mac (macOS Contacts, a
    /// `file:` feed).
    private var directorySearchNeedsNetwork: Bool { activeDirectorySources.contains { !$0.isLocal } }

    // MARK: - Search from the number field

    static let directoryDebounce: Duration = .milliseconds(300)

    /// Called whenever the number field changes. Starts a search after the minimum length and a pause; a
    /// running search is cancelled.
    func textChangedForDirectory(_ text: String) {
        let d = directory
        d.searchTask?.cancel()
        d.dismissed = false
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasSources = !activeDirectorySources.isEmpty
        if d.suppressedText == text { d.sections = []; d.pending = []; d.asked = 0; d.query = ""; return }
        d.suppressedText = nil
        guard settings.directory.searchFromNumberField, q.count >= settings.directory.minimumQueryLength, hasSources,
              !q.lowercased().hasPrefix("sip:"), networkOnline || !directorySearchNeedsNetwork else {
            d.sections = []; d.pending = []; d.asked = 0; d.query = ""
            return
        }
        d.searchTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.directoryDebounce)
            guard !Task.isCancelled, let self else { return }
            await self.runDirectorySearch(q)
        }
    }

    private func runDirectorySearch(_ q: String) async {
        let d = directory
        d.query = q
        d.sections = []
        d.pending = []
        d.asked = 0
        var order: [UUID: Int] = [:]
        for await update in directoryBackend.search(q) {
            guard !Task.isCancelled, d.query == q else { return }
            switch update {
            case let .started(ids):
                let all = settings.directory.sources
                order = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })
                d.pending = ids.compactMap { id in all.first { $0.id == id } }
                d.asked = ids.count
            case let .results(id, found):
                d.pending.removeAll { $0.id == id }
                guard let source = settings.directory.sources.first(where: { $0.id == id }) else { continue }
                let entries = Array(found.filter { $0.defaultNumber != nil }.prefix(settings.directory.resultsPerSource))
                guard !entries.isEmpty else { continue }
                d.sections.append(DirectorySection(sourceID: id, sourceName: source.shownName, sourceKind: source.kind, entries: entries))
                d.sections.sort { (order[$0.sourceID] ?? 0) < (order[$1.sourceID] ?? 0) }
            case let .failed(id):
                d.pending.removeAll { $0.id == id }
            case .finished:
                d.pending = []
            }
        }
        if !Task.isCancelled, d.query == q { d.pending = [] }
    }

    func clearDirectoryResults() {
        directory.searchTask?.cancel()
        directory.sections = []
        directory.pending = []
        directory.asked = 0
        directory.query = ""
    }

    /// Directory rows for the list under the number field: results of the current text, without numbers
    /// the list already shows as local contacts.
    func directorySections(excluding local: [Contact]) -> [DirectorySection] {
        guard !directory.dismissed else { return [] }
        let known = Set(local.flatMap(\.allNormalizedNumbers))
        return directory.sections.compactMap { section in
            var s = section
            s.entries = section.entries.filter { e in
                !(e.numbers.contains { known.contains(Contact.normalize($0.value)) })
            }
            return s.entries.isEmpty ? nil : s
        }
    }

    // MARK: - Calling a result

    func placeCall(to entry: DirectoryEntry) {
        guard let number = entry.defaultNumber?.value else { return }
        placeCall(to: number)
    }

    func addToContacts(_ entry: DirectoryEntry) {
        let card = entry.makeContact()
        ContactCardController.shared.show(
            ContactEditorRequest(contact: nil, prefillName: card.displayName, prefillNumber: entry.defaultNumber?.value ?? ""), model: self)
    }

    func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: - Incoming callers

    /// The name the directory gave a caller who is not in Contacts, if any.
    func directoryName(forNumber number: String) -> String? {
        directory.callerNames[Contact.normalize(number)]
    }

    /// A SIP display name that says nothing: empty, or just the number.
    private func isWeak(_ name: String?, number: String) -> Bool {
        guard let name = name?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return true }
        return Contact.normalize(name) == Contact.normalize(number) && !name.contains(where: \.isLetter)
    }

    /// What a call shows for its remote party when Contacts has no card: the SIP display name, unless it is
    /// empty or only the number, then the directory's name.
    func resolvedRemoteName(_ remote: RemoteParty) -> String? {
        if !isWeak(remote.displayName, number: remote.number) { return remote.displayName }
        return directoryName(forNumber: remote.number) ?? remote.displayName
    }

    /// Asks the sources who is calling (1 s at most) when the number is not in Contacts. The name shows in
    /// the incoming panel, the notification, the call panel and the call log entry.
    func lookupIncomingCaller(_ info: CallInfo) {
        guard settings.directory.lookupIncomingCallers, info.direction == .incoming,
              !settings.directory.sources.isEmpty, contact(for: info.remote) == nil else { return }
        let number = info.remote.number
        guard !Contact.normalize(number).isEmpty, directoryName(forNumber: number) == nil else { return }
        let id = info.id
        Task { @MainActor [weak self] in
            guard let self else { return }
            let backend = self.directoryBackend
            let entry = await Self.withTimeLimit(.seconds(1)) { await backend.lookup(number: number) }
            guard let name = entry?.displayName.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return }
            self.rememberCallerName(name, forNumber: number)
            if let call = self.calls.first(where: { $0.id == id }), call.isRinging, self.presentedIncoming.contains(id) {
                CallNotifications.shared.post(for: call, model: self)      // same identifier: replaces the banner
            }
        }
    }

    func rememberCallerName(_ name: String, forNumber number: String) {
        let key = Contact.normalize(number)
        guard !key.isEmpty else { return }
        let d = directory
        if d.callerNames.updateValue(name, forKey: key) == nil { d.callerOrder.append(key) }
        while d.callerOrder.count > 64 { d.callerNames[d.callerOrder.removeFirst()] = nil }
    }

    /// The result of `body`, or nil when it takes longer than `limit`.
    nonisolated static func withTimeLimit<T: Sendable>(_ limit: Duration, _ body: @escaping @Sendable () async -> T?) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await body() }
            group.addTask { try? await Task.sleep(for: limit); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    // MARK: - Import

    /// "Import now": copies the source's entries into Contacts (matched by number, never duplicated; see
    /// `DirectoryMerge`). New cards get the note "Imported from <source>".
    func importDirectory(_ source: DirectorySource) {
        let d = directory
        guard !d.importing.contains(source.id) else { return }
        d.importing.insert(source.id)
        d.reports[source.id] = nil
        let backend = directoryBackend
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { d.importing.remove(source.id) }
            do {
                let note = L.directoryImportedFrom(source.shownName)
                let imported = try await backend.importAll(source: source).map { c in var c = c; c.notes = note; return c }
                let result = try await self.saveImported(imported, source: source.id)
                self.prefs.set(Date(), forKey: "directoryLastImport.\(source.id.uuidString)")
                let text: String
                if result.imported == 0 { text = L.directoryImportNothing }
                else if result.updated > 0 { text = "\(L.directoryImported(result.imported)) \(L.directoryImportedUpdated(result.updated))" }
                else { text = L.directoryImported(result.imported) }
                self.setImportReport(DirectoryImportReport(text: text, isError: false), for: source.id)
            } catch {
                AppLog.app.error("directory import failed: \(describe(error))")
                let reason = (error as? DirectoryError).map { DirectoryStyle.text(for: $0) } ?? describe(error)
                self.setImportReport(DirectoryImportReport(text: L.directoryImportFailed(reason), isError: true), for: source.id)
            }
        }
    }

    /// Merges `imported` into the address book and writes the changed cards off the main actor (a large import
    /// must not freeze the window). If a card was edited while the write ran, the merge is redone against the
    /// current list and written again, so no edit is lost.
    private func saveImported(_ imported: [Contact], source: UUID) async throws -> DirectoryMerge.Result {
        let store = contactStore
        var attempt = 0
        while true {
            let snapshot = contacts
            let result = DirectoryMerge.merge(imported, into: snapshot, source: source)
            guard !result.changed.isEmpty else { return result }
            let changed = result.changed
            try await Task.detached(priority: .userInitiated) { try store.upsert(contentsOf: changed) }.value
            if contacts == snapshot || attempt >= 2 {
                var list = contacts
                var index: [UUID: Int] = [:]
                for (i, c) in list.enumerated() { index[c.id] = i }
                for c in changed { if let i = index[c.id] { list[i] = c } else { list.append(c) } }
                setContacts(list)
                syncPresenceSubscriptions()
                return result
            }
            attempt += 1
        }
    }

    private func setImportReport(_ report: DirectoryImportReport, for id: UUID) {
        let d = directory
        d.reports[id] = report
        d.reportTasks[id]?.cancel()
        d.reportTasks[id] = Task { @MainActor in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            d.reports[id] = nil
        }
    }

    // MARK: - Sources (Settings › Directory)

    func moveDirectorySources(from offsets: IndexSet, to destination: Int) {
        updateSettings { $0.directory.sources.move(fromOffsets: offsets, toOffset: destination) }
    }

    func setDirectorySource(_ id: UUID, enabled: Bool) {
        updateSettings { s in
            if let i = s.directory.sources.firstIndex(where: { $0.id == id }) { s.directory.sources[i].isEnabled = enabled }
        }
    }

    /// The Keychain slot of directory secrets; nil in demo launches, which never touch it.
    var directoryCredentials: DirectoryCredentials? { launch.isDemo ? nil : DirectoryCredentials() }

    /// Adds or replaces a source. An LDAP password the user typed goes to the Keychain (an empty bind DN
    /// means anonymous: no password is kept).
    func saveDirectorySource(_ source: DirectorySource, password: String? = nil, passwordTouched: Bool = false) {
        if source.kind == .ldap, let credentials = directoryCredentials {
            do {
                if source.ldap?.bindDN.isEmpty == true { try credentials.setLDAPPassword("", for: source.id) }
                else if passwordTouched, let password { try credentials.setLDAPPassword(password, for: source.id) }
            } catch { report(error) }
        }
        updateSettings { s in
            if let i = s.directory.sources.firstIndex(where: { $0.id == source.id }) { s.directory.sources[i] = source }
            else { s.directory.sources.append(source) }
        }
        // A Google source without a token in the Keychain needs a sign-in; otherwise the service reports the status.
        if source.kind == .google, let credentials = directoryCredentials, ((try? credentials.googleToken(for: source.id)) ?? nil) == nil {
            directory.statuses[source.id] = .signInRequired
        } else {
            directory.statuses[source.id] = nil
        }
    }

    /// The Test button: the password typed in the sheet is used for this test only; Save stores it.
    func testDirectorySource(_ source: DirectorySource, password: String?) async -> DirectoryTestResult {
        let result = await directoryBackend.test(source: source, ldapPassword: password)
        directory.statuses[source.id] = settings.directory.sources.contains(where: { $0.id == source.id }) ? result.status : nil
        return result
    }

    /// Sign In… under a saved Google source: opens the consent page in the browser and waits for the redirect
    /// (one sign-in at a time). Success stores the account e-mail in the source and shows it as connected;
    /// a failure shows its reason under the source; a cancelled sign-in shows nothing.
    func signInToGoogle(_ source: DirectorySource) {
        let d = directory
        d.signInTask?.cancel()
        d.signInMessages[source.id] = nil
        d.signInTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let email = try await self.runGoogleSignIn(sourceID: source.id)
                self.updateSettings { s in
                    guard let i = s.directory.sources.firstIndex(where: { $0.id == source.id }) else { return }
                    var g = s.directory.sources[i].google ?? GoogleConfig()
                    g.accountEmail = email
                    s.directory.sources[i].google = g
                }
                d.statuses[source.id] = .connected
            } catch DirectoryError.cancelled {
            } catch is CancellationError {
            } catch {
                d.signInMessages[source.id] = (error as? DirectoryError).map { DirectoryStyle.text(for: $0) } ?? describe(error)
            }
        }
    }

    /// The sign-in itself, also used by the source sheet for a source that is not saved yet: the e-mail on
    /// success. `signingIn` holds the source while the browser is open.
    func runGoogleSignIn(sourceID: UUID) async throws -> String {
        let d = directory
        d.signingIn.insert(sourceID)
        defer { d.signingIn.remove(sourceID) }
        let backend = directoryBackend
        do {
            let email = try await backend.signInGoogle(sourceID: sourceID, openURL: { url in
                Task { @MainActor in NSWorkspace.shared.open(url) }
            })
            AppLog.app.info("google sign-in: \(email)")
            return email
        } catch {
            if (error as? DirectoryError) != .cancelled { AppLog.app.error("google sign-in failed: \(describe(error))") }
            throw error
        }
    }

    /// The source sheet closed: a sign-in started from it is abandoned.
    func cancelGoogleSignIn() {
        directory.signInTask?.cancel()
        directory.signInTask = nil
    }

    func removeDirectorySource(_ id: UUID) {
        updateSettings { $0.directory.sources.removeAll { $0.id == id } }
        try? directoryCredentials?.deleteAll(for: id)
        directory.statuses[id] = nil
        directory.reports[id] = nil
    }

    /// The source sheet was cancelled for a source that was never saved: whatever the sign-in stored for its
    /// id (a Google token) goes. A saved source keeps its secrets.
    func discardDirectorySecrets(for id: UUID) {
        guard !settings.directory.sources.contains(where: { $0.id == id }) else { return }
        try? directoryCredentials?.deleteAll(for: id)
        directory.statuses[id] = nil
        directory.signInMessages[id] = nil
    }
}

extension DirectorySource {
    /// The name shown in lists and notes: a macOS Contacts source has none of its own (the label follows the
    /// app's language).
    var shownName: String { name.isEmpty && kind == .macContacts ? L.directoryMacOSName : name }

    /// Answers without the network: macOS Contacts and a `file:` feed.
    var isLocal: Bool {
        switch kind {
        case .macContacts: return true
        case .url: return url?.url.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("file:") ?? false
        case .ldap, .google: return false
        }
    }
}
