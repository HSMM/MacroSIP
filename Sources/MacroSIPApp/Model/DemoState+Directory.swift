import Foundation
import MacroSIPCore
#if DEBUG
import AppKit

/// Demo states of screen 13 (the mock directory answers with delays, see `MockDirectory`):
///   directory            "ka" typed; the Google source is still answering (use `--snapshot-after 3` for the spinner row)
///   directory-done       the same after every source has answered
///   directory-selftest   only the directory checks of `selftest`
///   directory-incoming   a call from 2214 rings; the lookup names it (floating panel)
///   directory-sheet[-url|-google|-macos]   Settings › Directory with the Add Directory Source sheet open
///   directory-import     Settings › Directory after "Import now" on macOS Contacts
///   settings-directory   Settings › Directory, Google sign-in expired (generic `settings-<tab>` state)
extension DemoState {
    static let ldapSourceID = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!
    static let googleSourceID = UUID(uuidString: "00000000-0000-0000-0000-0000000000A2")!
    static let macSourceID = UUID(uuidString: "00000000-0000-0000-0000-0000000000A3")!

    static func isDirectoryState(_ state: String) -> Bool { state.hasPrefix("directory") || state == "settings-directory" }

    /// The three sources of the mockup: Company LDAP, Google Contacts, macOS Contacts (imported).
    static func demoDirectorySources() -> [DirectorySource] {
        [
            DirectorySource(id: ldapSourceID, kind: .ldap, name: "Company LDAP",
                            ldap: LDAPConfig(server: "ldap://ldap.example.com", baseDN: "ou=people,dc=example,dc=com")),
            DirectorySource(id: googleSourceID, kind: .google, name: "Google Contacts", google: GoogleConfig(accountEmail: "andrei@gmail.com")),
            DirectorySource(id: macSourceID, kind: .macContacts, name: ""),
        ]
    }

    static func seedDirectory(_ store: SettingsStore) {
        var settings = store.load()
        settings.directory = DirectorySettings(sources: demoDirectorySources())
        try? store.save(settings)
    }

    @MainActor
    static func runDirectory(_ model: AppModel, state: String) async {
        try? await Task.sleep(for: .seconds(1.0))
        let query = Locale.preferredLanguages.first?.hasPrefix("ru") == true ? "ка" : "ka"
        switch state {
        case "directory", "directory-done":
            model.directory.selectedSource = googleSourceID
            model.dialText = query
            if state == "directory-done" { try? await Task.sleep(for: .seconds(Double(MockDirectory.googleDelayMilliseconds) / 1000 + 1)) }
        case "directory-selftest":      // only the directory checks of `selftest`
            let results = await directorySelftest(model)
            let failures = results.filter { !$0.1 }.count
            let text = results.map { "\($0.1 ? "PASS" : "FAIL") \($0.0) \($0.2)" }.joined(separator: "\n") + "\nfailures=\(failures)\n"
            if let prefix = model.launch.snapshotPrefix { try? text.write(toFile: "\(prefix)-selftest.txt", atomically: true, encoding: .utf8) }
            print(text)
            quitLater()
        case "directory-incoming":
            await (model.engine as? MockEngine)?.simulateIncoming(name: nil, number: "2214", account: model.defaultAccount?.id)
        case "directory-import":
            model.directory.selectedSource = macSourceID
            model.openSettings(tab: .directory)
            try? await Task.sleep(for: .seconds(0.6))
            if let mac = model.settings.directory.sources.first(where: { $0.id == macSourceID }) { model.importDirectory(mac) }
            try? await Task.sleep(for: .seconds(1.2))
        default:
            let kind: DirectorySourceKind
            switch state {
            case "directory-sheet-url": kind = .url
            case "directory-sheet-google": kind = .google
            case "directory-sheet-macos": kind = .macContacts
            default: kind = .ldap
            }
            model.directory.selectedSource = ldapSourceID
            model.openSettings(tab: .directory)
            try? await Task.sleep(for: .seconds(0.8))
            model.directory.editor = DirectoryEditorRequest(sourceID: nil, kind: kind)
        }
    }

    /// Self test of the directory (suggestions, incoming lookup, import); returns (name, passed, detail).
    @MainActor
    static func directorySelftest(_ model: AppModel) async -> [(String, Bool, String)] {
        var out: [(String, Bool, String)] = []
        func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") { out.append((name, ok, ok ? "" : detail())) }
        func wait(_ s: Double) async { try? await Task.sleep(for: .seconds(s)) }
        /// Polls until `condition` holds (a loaded machine answers late), at most `seconds`.
        func until(_ seconds: Double, _ condition: () -> Bool) async {
            let end = Date().addingTimeInterval(seconds)
            while !condition(), Date() < end { try? await Task.sleep(for: .milliseconds(50)) }
        }
        let mock = model.engine as? MockEngine
        let d = model.directory
        let ka = Locale.preferredLanguages.first?.hasPrefix("ru") == true ? "ка" : "ka"
        let sources = demoDirectorySources()
        let (ldap, google, mac) = (sources[0], sources[1], sources[2])
        model.updateSettings { $0.directory = DirectorySettings(sources: [ldap, google, mac]) }
        await wait(0.3)

        // statuses arrive as events
        check("sources report their status", d.statuses[ldap.id] == .connected && d.statuses[google.id] == .connected
              && { if case .syncedAt = d.statuses[mac.id] { return true } else { return false } }(), "\(d.statuses)")

        // suggestions
        model.dialText = "k"
        await wait(0.6)
        check("no search below the minimum length", d.sections.isEmpty && d.pending.isEmpty)
        model.dialText = ka
        await wait(0.15)
        check("no search before the pause", d.pending.isEmpty && d.sections.isEmpty)
        await until(3) { d.sections.contains { $0.sourceKind == .macContacts } }
        check("search shows partial results while sources answer",
              d.isSearching && d.pending.contains { $0.id == google.id } && d.sections.contains { $0.sourceKind == .macContacts },
              "pending \(d.pending.map(\.name)) sections \(d.sections.map(\.sourceName))")
        await until(Double(MockDirectory.googleDelayMilliseconds) / 1000 + 3) { !d.isSearching }
        check("searching ends when every source answered", !d.isSearching && d.asked == 3, "pending \(d.pending.map(\.name))")
        let local = model.suggestions(for: ka)
        let shown = model.directorySections(excluding: local)
        check("directory results come in source order", shown.map(\.sourceKind) == [.ldap, .macContacts] || shown.map(\.sourceKind) == [.ldap, .macContacts, .url],
              "\(shown.map(\.sourceKind))")
        check("LDAP result is listed with its number", shown.first(where: { $0.sourceKind == .ldap })?.entries.contains { $0.displayName == DemoPeople.natallia && $0.defaultNumber?.value == "2214" } == true,
              "\(d.sections.map { "\($0.sourceName): \($0.entries.map(\.displayName))" }) shown \(shown.map(\.sourceName))")
        d.dismissed = true
        check("Escape hides the directory rows", model.directorySections(excluding: local).isEmpty)
        d.dismissed = false

        // a number that is already in Contacts is shown once
        model.dialText = String(DemoPeople.dzmitry.prefix(5))
        let dzText = model.dialText
        await until(8) { d.query == dzText && d.sections.contains { $0.sourceKind == .macContacts } }
        let dz = model.suggestions(for: model.dialText)
        let dzShown = model.directorySections(excluding: dz).flatMap(\.entries)
        check("a result already in Contacts is listed once",
              dz.contains { $0.displayName == DemoPeople.dzmitry } && !dzShown.contains { $0.displayName == DemoPeople.dzmitry }, "\(dzShown.map(\.displayName))")

        // switched-off and signed-out sources are not asked
        model.dialText = ""
        await until(2) { d.query.isEmpty }
        model.setDirectorySource(ldap.id, enabled: false)
        model.dialText = ka
        await until(6) { !d.isSearching && d.query == ka && d.asked > 0 }
        check("a switched-off source is not searched", !(d.sections.contains { $0.sourceID == ldap.id }) && !d.pending.contains { $0.id == ldap.id },
              "sections \(d.sections.map(\.sourceName)) pending \(d.pending.map(\.name)) query \(d.query) asked \(d.asked) enabled \(model.settings.directory.sources.map(\.isEnabled))")
        model.setDirectorySource(ldap.id, enabled: true)
        model.dialText = ""
        await wait(0.2)
        check("clearing the field clears the results", d.sections.isEmpty && d.pending.isEmpty)
        model.updateSettings { $0.directory.searchFromNumberField = false }
        model.dialText = ka
        await wait(0.8)
        check("search from the number field can be switched off", d.sections.isEmpty && d.pending.isEmpty)
        model.updateSettings { $0.directory.searchFromNumberField = true }
        model.dialText = ""

        // incoming caller lookup
        await mock?.simulateIncoming(name: nil, number: "2214", account: officeID)
        await wait(0.2)
        check("unknown caller shows its number first", model.incomingCall.map { model.name(for: $0.remote) } == "2214", "\(String(describing: model.incomingCall.map { model.name(for: $0.remote) }))")
        await until(3) { model.incomingCall.map { model.name(for: $0.remote) } == DemoPeople.natallia }
        check("lookup names the incoming call", model.incomingCall.map { model.name(for: $0.remote) } == DemoPeople.natallia,
              "\(String(describing: model.incomingCall.map { model.name(for: $0.remote) }))")
        if let c = model.incomingCall { model.decline(c.id) }
        await until(3) { model.callLog.first?.remoteNumber == "2214" }
        check("the name is written to the call log", model.callLog.first?.remoteNumber == "2214" && model.callLog.first?.remoteDisplayName == DemoPeople.natallia,
              "\(String(describing: model.callLog.first?.remoteDisplayName))")
        model.updateSettings { $0.directory.lookupIncomingCallers = false }
        await mock?.simulateIncoming(name: nil, number: "2230", account: officeID)
        await wait(1.0)
        check("lookup can be switched off", model.incomingCall.map { model.name(for: $0.remote) } == "2230")
        if let c = model.incomingCall { model.decline(c.id) }
        model.updateSettings { $0.directory.lookupIncomingCallers = true }
        await wait(0.3)
        await mock?.simulateIncoming(name: nil, number: "101", account: officeID)
        await wait(0.8)
        check("a caller in Contacts is not looked up", model.incomingCall.map { model.name(for: $0.remote) } == DemoPeople.andrei && model.directoryName(forNumber: "101") == nil)
        if let c = model.incomingCall { model.decline(c.id) }
        await wait(0.3)
        await mock?.simulateIncoming(name: "Switchboard 7", number: "2241", account: officeID)
        await wait(0.8)
        check("a SIP display name is kept", model.incomingCall.map { model.name(for: $0.remote) } == "Switchboard 7")
        if let c = model.incomingCall { model.decline(c.id) }
        await wait(0.3)

        // import into Contacts
        let before = model.contacts.count
        model.importDirectory(mac)
        await until(5) { d.reports[mac.id] != nil }
        let report = d.reports[mac.id]
        check("import adds new contacts and updates matched ones", model.contacts.count == before + 4
              && model.contacts.first(where: { $0.displayName == DemoPeople.yauheni })?.organization == "Example Ltd",
              "\(before) -> \(model.contacts.count)")
        check("import result banner", report?.isError == false && report?.text == "\(L.directoryImported(6)) \(L.directoryImportedUpdated(2))", report?.text ?? "none")
        check("imported contacts are stored", model.contactStore.all().count == model.contacts.count)
        check("matched contact keeps its id and number", model.contacts.filter { $0.hasNumber("+49 30 123456") }.count == 1)
        let after = model.contacts.count
        d.reports[mac.id] = nil
        model.importDirectory(mac)
        await until(5) { d.reports[mac.id] != nil }
        check("importing again never duplicates", model.contacts.count == after && d.reports[mac.id]?.text == L.directoryImportNothing,
              "\(after) -> \(model.contacts.count) \(d.reports[mac.id]?.text ?? "")")
        let merged = DirectoryMerge.merge([Contact(name: "A B", number: "+1 555 0100"), Contact(name: "A Bee", number: "+1 (555) 0100")], into: [], source: mac.id)
        check("two entries with one number become one contact", merged.changed.count == 1 && merged.added == 1, "\(merged.changed.count)")
        for c in model.contacts where c.importedFrom != nil || [DemoPeople.kate, DemoPeople.lev].contains(c.displayName) { model.deleteContact(c.id) }

        // source list
        model.moveDirectorySources(from: IndexSet(integer: 2), to: 0)
        check("sources reorder", model.settings.directory.sources.map(\.id) == [mac.id, ldap.id, google.id])
        model.removeDirectorySource(google.id)
        check("a source is removed and the list persisted", model.settingsStore.load().directory.sources.map(\.id) == [mac.id, ldap.id])
        model.updateSettings { $0.directory = DirectorySettings() }
        await wait(0.2)
        return out
    }
}
#endif
