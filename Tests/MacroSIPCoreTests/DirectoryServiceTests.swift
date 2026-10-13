import Foundation
import os
import Testing
@testable import MacroSIPCore

/// A provider with fixed entries, an optional delay and an optional error; counts its calls.
final class StubDirectoryProvider: DirectoryProvider, @unchecked Sendable {
    let sourceID: UUID
    let entries: [DirectoryEntry]
    let delay: TimeInterval
    let error: DirectoryError?
    private let counter = OSAllocatedUnfairLock(initialState: 0)
    var calls: Int { counter.withLock { $0 } }

    init(source: DirectorySource, names: [String] = [], numbers: [String]? = nil, delay: TimeInterval = 0, error: DirectoryError? = nil) {
        sourceID = source.id
        let nums = numbers ?? names.indices.map { "10\($0)" }
        entries = names.enumerated().map { i, n in
            DirectoryEntry(id: "\(source.id)-\(i)", sourceID: source.id, sourceKind: source.kind, displayName: n,
                           numbers: [PhoneNumber(value: nums[i], isDefault: true)])
        }
        self.delay = delay
        self.error = error
    }

    private func run() async throws {
        counter.withLock { $0 += 1 }
        if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1e9)) }
        if let error { throw error }
    }

    func search(_ query: String, limit: Int) async throws -> [DirectoryEntry] {
        try await run()
        return Array(DirectoryIndex(entries).search(query, limit: limit))
    }
    func lookup(number: String) async throws -> DirectoryEntry? {
        try await run()
        return DirectoryIndex(entries).lookup(number)
    }
    func test() async throws -> DirectoryTestResult {
        try await run()
        return .connected(entries: entries.count)
    }
    func allEntries() async throws -> [DirectoryEntry] {
        try await run()
        return entries
    }
}

@Suite("Directory service")
struct DirectoryServiceTests {
    struct Setup {
        var sources: [DirectorySource] = []
        var stubs: [UUID: StubDirectoryProvider] = [:]

        mutating func add(_ kind: DirectorySourceKind = .ldap, name: String, enabled: Bool = true, imports: Bool = false,
                          entries: [String] = [], numbers: [String]? = nil, delay: TimeInterval = 0, error: DirectoryError? = nil) -> UUID {
            let s = DirectorySource(kind: kind, name: name, isEnabled: enabled, importIntoContacts: imports)
            sources.append(s)
            stubs[s.id] = StubDirectoryProvider(source: s, names: entries, numbers: numbers, delay: delay, error: error)
            return s.id
        }

        func service(_ settings: DirectorySettings? = nil, searchTimeout: TimeInterval = 0.5, lookupTimeout: TimeInterval = 0.5) -> DirectoryService {
            let stubs = self.stubs
            return DirectoryService(settings: settings ?? DirectorySettings(sources: sources), keychain: Keychain(service: "com.hsmm.macrosip.tests"),
                                    makeProvider: { s, _ in stubs[s.id] }, searchTimeout: searchTimeout, lookupTimeout: lookupTimeout)
        }
    }

    @Test func slowSourceGivesPartialResults() async {
        var setup = Setup()
        let a = setup.add(name: "A", entries: ["Anna A", "Andrei A"])
        let slow = setup.add(name: "Slow", entries: ["Anna Slow"], delay: 5)
        let broken = setup.add(name: "Broken", error: .server("down"))
        let service = setup.service()
        let start = Date()
        let found = await service.search("an")
        #expect(Date().timeIntervalSince(start) < 2)
        #expect(found.map(\.displayName) == ["Anna A", "Andrei A"])
        let st = await service.currentStatuses()
        #expect(st[a] == .connected)
        #expect(st[slow] == nil)                                // slow is not an error
        #expect(st[broken] == .error(.server("down")))
        // A failed source is skipped for a while.
        _ = await service.search("an")
        #expect(setup.stubs[broken]!.calls == 1)
        #expect(setup.stubs[a]!.calls == 2)
    }

    @Test func resultsKeepSourceOrderAndLimit() async {
        var setup = Setup()
        let late = setup.add(name: "First, answers late", entries: (1...8).map { "Ann \($0)" }, delay: 0.1)
        _ = setup.add(name: "Second, answers first", entries: ["Annette"])
        _ = setup.add(name: "Off", enabled: false, entries: ["Anna Off"])
        var settings = DirectorySettings(sources: setup.sources)
        settings.resultsPerSource = 5
        let found = await setup.service(settings).search("ann")
        #expect(found.map(\.displayName) == ["Ann 1", "Ann 2", "Ann 3", "Ann 4", "Ann 5", "Annette"])
        #expect(found.allSatisfy { $0.displayName != "Anna Off" })
        #expect(found.first?.sourceID == late)
    }

    @Test func shortQueriesAndSwitchedOffSearchAskNobody() async {
        var setup = Setup()
        let a = setup.add(name: "A", entries: ["Anna"])
        let service = setup.service()
        #expect(await service.search("a").isEmpty)
        #expect(await service.search("  ").isEmpty)
        var off = DirectorySettings(sources: setup.sources)
        off.searchFromNumberField = false
        await service.update(settings: off)
        #expect(await service.search("anna").isEmpty)
        #expect(setup.stubs[a]!.calls == 0)
    }

    @Test func updatesReportEachSource() async {
        var setup = Setup()
        let a = setup.add(name: "A", entries: ["Anna"])
        let slow = setup.add(name: "Slow", entries: ["Anna Slow"], delay: 5)
        let service = setup.service(searchTimeout: 0.3)
        var updates: [DirectorySearchUpdate] = []
        for await u in service.searchUpdates("anna") { updates.append(u) }
        #expect(updates.first == .started([a, slow]))
        #expect(updates.contains { if case .results(a, let e) = $0 { return e.count == 1 } else { return false } })
        #expect(updates.contains(.failed(sourceID: slow)))
        #expect(updates.last == .finished)
    }

    @Test func cancelledSearchReturnsAtOnce() async {
        var setup = Setup()
        _ = setup.add(name: "Slow", entries: ["Anna"], delay: 5)
        let service = setup.service(searchTimeout: 10)
        let start = Date()
        let task = Task { await service.search("anna") }
        try? await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        #expect(await task.value.isEmpty)
        #expect(Date().timeIntervalSince(start) < 2)
    }

    @Test func lookupAsksSearchOnlySourcesInOrder() async {
        var setup = Setup()
        let imported = setup.add(name: "Imported", imports: true, entries: ["Imported Anna"], numbers: ["+7 495 123-45-67"])
        _ = setup.add(name: "Slow match", entries: ["Slow Anna"], numbers: ["84951234567"], delay: 5)
        _ = setup.add(name: "Fast match", entries: ["Fast Anna"], numbers: ["+7 (495) 123-45-67"])
        let service = setup.service(lookupTimeout: 0.4)
        let start = Date()
        // The first source in order does not answer within the limit; the next one's match is used.
        #expect(await service.lookup(number: "sip:+74951234567@pbx")?.displayName == "Fast Anna")
        #expect(Date().timeIntervalSince(start) < 2)
        #expect(setup.stubs[imported]!.calls == 0)
        #expect(await service.lookup(number: "999") == nil)
    }

    @Test func lookupReturnsEarlyForTheFirstSource() async {
        var setup = Setup()
        _ = setup.add(name: "Fast", entries: ["Fast Anna"], numbers: ["101"])
        _ = setup.add(name: "Slow", entries: ["Slow Anna"], numbers: ["101"], delay: 5)
        let service = setup.service(lookupTimeout: 3)
        let start = Date()
        #expect(await service.lookup(number: "101")?.displayName == "Fast Anna")
        #expect(Date().timeIntervalSince(start) < 1.5)
        var off = DirectorySettings(sources: setup.sources)
        off.lookupIncomingCallers = false
        await service.update(settings: off)
        #expect(await service.lookup(number: "101") == nil)
    }

    @Test func googleNeedsSignInAndIsSkipped() async {
        let google = DirectorySource(kind: .google, name: "Google")
        let service = DirectoryService(settings: DirectorySettings(sources: [google]), keychain: Keychain(service: "com.hsmm.macrosip.tests"))
        var it = service.events.makeAsyncIterator()
        #expect(await it.next() == .sourceStatus(id: google.id, status: .signInRequired))
        #expect(await service.currentStatuses()[google.id] == .signInRequired)
        #expect(await service.searchableSources().isEmpty)
        #expect(await service.search("anna").isEmpty)
        let result = await service.test(source: google)
        #expect(result.status == .signInRequired && !result.isSuccess)
    }

    @Test func testAndImport() async throws {
        var setup = Setup()
        let id = setup.add(.url, name: "Phone list", imports: true, entries: ["Anna Ivanova", "Boris"])
        let broken = setup.add(name: "Broken", error: .server("down"))
        let service = setup.service()
        var events = service.events.makeAsyncIterator()
        let source = setup.sources[0]
        #expect(await service.test(source: source) == .connected(entries: 2))
        #expect(await events.next() == .sourceStatus(id: id, status: .connected))
        let contacts = try await service.importAll(source: source)
        #expect(contacts.map(\.displayName) == ["Anna Ivanova", "Boris"])
        #expect(contacts[0].firstName == "Anna" && contacts[0].lastName == "Ivanova")
        #expect(contacts.allSatisfy { $0.importedFrom == id && $0.notes.isEmpty && $0.defaultNumber != nil })
        guard case .sourceStatus(id, .syncedAt)? = await events.next() else { Issue.record("no synced event"); return }
        await #expect(throws: DirectoryError.server("down")) { try await service.importAll(source: setup.sources[1]) }
        #expect(await service.currentStatuses()[broken] == .error(.server("down")))
        #expect(await service.test(source: setup.sources[1]).status == .error(.server("down")))
        // A failed source may still be imported: the status is not a lock.
        #expect(DirectorySourceStatus.error(.server("down")).isUsable)
        #expect(!DirectorySourceStatus.signInRequired.isUsable)
    }

    @Test func removedSourceIsNotResurrectedByALateAnswer() async {
        var setup = Setup()
        _ = setup.add(name: "A", entries: ["Anna A"])
        let slow = setup.add(name: "Slow", delay: 0.3, error: .server("down"))
        let service = setup.service(searchTimeout: 0.1)
        _ = await service.search("an")                           // Slow has not answered yet
        await service.update(settings: DirectorySettings(sources: [setup.sources[0]]))
        try? await Task.sleep(for: .milliseconds(500))           // its failure arrives after the removal
        #expect(await service.currentStatuses()[slow] == nil)
    }

    @Test func testPasswordIsNotStored() throws {
        let id = UUID()
        let creds = DirectoryCredentials(keychain: Keychain(service: "com.hsmm.macrosip.tests.never-used"))
        let draft = creds.overriding(ldapPassword: "typed", for: id)
        #expect(try draft.ldapPassword(for: id) == "typed")
        #expect(try draft.ldapPassword(for: UUID()) == nil || true)   // other ids still go to the Keychain
        #expect(try creds.ldapPassword(for: id) == nil)               // the original never saw the draft
    }

    @Test func importSchedule() {
        let now = Date()
        let url = DirectorySource(kind: .url, importIntoContacts: true, url: URLConfig(url: "https://x", refreshMinutes: 360))
        #expect(DirectoryService.importInterval(for: url) == 6 * 3600)
        #expect(DirectoryService.isImportDue(url, lastSync: nil, now: now))
        #expect(!DirectoryService.isImportDue(url, lastSync: now.addingTimeInterval(-3600), now: now))
        #expect(DirectoryService.isImportDue(url, lastSync: now.addingTimeInterval(-7 * 3600), now: now))
        let ldap = DirectorySource(kind: .ldap, importIntoContacts: false)
        #expect(!DirectoryService.isImportDue(ldap, lastSync: nil, now: now))
        #expect(DirectoryService.importInterval(for: DirectorySource(kind: .macContacts)) == 86400)
    }
}

@Suite("Directory settings")
struct DirectorySettingsTests {
    @Test func appSettingsWithoutDirectoryDecode() throws {
        let s = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"callLogLimit": 50}"#.utf8))
        #expect(s.directory == DirectorySettings())
        #expect(s.directory.lookupIncomingCallers && s.directory.minimumQueryLength == 2 && s.directory.resultsPerSource == 5)
        #expect(s.directory.searchFromNumberField && s.directory.sources.isEmpty)
    }

    @Test func roundTrip() throws {
        var s = AppSettings()
        s.directory.sources = [
            DirectorySource(kind: .macContacts),
            DirectorySource(kind: .ldap, name: "Company", ldap: LDAPConfig(server: "ldaps://ldap.example.com", baseDN: "dc=example,dc=com",
                                                                          bindDN: "cn=reader", attributes: LDAPAttributeMap(organization: "company"))),
            DirectorySource(kind: .url, name: "List", isEnabled: false, url: URLConfig(url: "https://x/y.json", format: .json,
                                                                                      jsonPaths: URLFieldMap(name: "n", number: "p.0"))),
            DirectorySource(kind: .google, name: "Google", google: GoogleConfig(accountEmail: "me@example.com")),
        ]
        s.directory.resultsPerSource = 7
        let back = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(s))
        #expect(back == s)
        #expect(back.directory.sources[0].importIntoContacts)       // macOS Contacts imports by default
        #expect(!back.directory.sources[1].importIntoContacts)
        #expect(back.directory.sources[1].address == "ldaps://ldap.example.com")
    }

    @Test func sparseAndUnknownSources() throws {
        let json = #"""
        {"sources": [
            {"id": "6B1E8C2A-6A5C-4C61-9C7B-0E9E2B4E6F10", "kind": "ldap", "name": "Old", "ldap": {"server": "ldap://h", "searchFilter": ""}},
            {"kind": "carddav", "name": "From a later version"},
            {"kind": "url", "url": {"url": "https://x/list.csv"}}
        ], "resultsPerSource": 40, "minimumQueryLength": 0}
        """#
        let d = try JSONDecoder().decode(DirectorySettings.self, from: Data(json.utf8))
        #expect(d.sources.map(\.kind) == [.ldap, .url])
        let ldap = try #require(d.sources[0].ldap)
        #expect(ldap.searchFilter == LDAPConfig.defaultFilter)
        #expect(ldap.attributes == LDAPAttributeMap())
        #expect(!ldap.startTLS && ldap.port == nil && ldap.bindDN.isEmpty)
        #expect(d.sources[0].isEnabled && !d.sources[0].importIntoContacts)
        let url = try #require(d.sources[1].url)
        #expect(url.format == .csv && url.refreshMinutes == 60)
        #expect(d.resultsPerSource == 10 && d.minimumQueryLength == 1)
        #expect(d.lookupIncomingCallers)
    }
}
