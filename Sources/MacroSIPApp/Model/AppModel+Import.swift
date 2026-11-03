import AppKit
import MacroSIPCore

/// The Import from MicroSIP sheet: which file, what it contains, and what was done.
struct MicroSIPImportSession: Identifiable {
    enum Outcome {
        case preview(MicroSIPImport.Merge)
        case failed(MicroSIPImport.ReadError)
    }

    /// What an import did.
    struct Report: Equatable {
        var accounts: [String]          // display names, in file order
        var contacts: Int
        var firstAccount: AccountID?    // the one whose editor opens next
    }

    let id = UUID()
    var iniURL: URL
    /// nil = no contacts file (found none, or the user chose none).
    var contactsURL: URL?
    var outcome: Outcome
    var report: Report?
}

/// Import of accounts and contacts from MicroSIP (`MicroSIP.ini`, `Contacts.xml`). The reading and sorting is
/// `MicroSIPImport` in Core; this is the app side: the file panels, the sheet's state and the write.
extension AppModel {
    // MARK: - Choosing files

    /// Settings › Accounts › Import from MicroSIP…
    func chooseMicroSIPFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = true
        panel.message = L.importPanelMessage(appData: "%APPDATA%\\MicroSIP")
        panel.prompt = L.importPanelPrompt
        panel.allowsOtherFileTypes = true
        panel.allowedContentTypes = [.init(filenameExtension: "ini") ?? .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        beginMicroSIPImport(ini: url)
    }

    /// Reads the file and opens the preview. Contacts.xml next to it is used when there is one.
    func beginMicroSIPImport(ini: URL) {
        loadMicroSIPPreview(ini: ini, contacts: Self.contactsFile(next: ini))
    }

    /// The preview's "Choose…" for the contacts file.
    func chooseMicroSIPContactsFile() {
        guard let session = microSIPImport else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = session.iniURL.deletingLastPathComponent()
        panel.message = L.importContactsPanelMessage
        panel.prompt = L.importPanelPrompt
        panel.allowedContentTypes = [.init(filenameExtension: "xml") ?? .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setMicroSIPContacts(url)
    }

    /// Another contacts file, or none (nil); the preview is rebuilt.
    func setMicroSIPContacts(_ url: URL?) {
        guard let session = microSIPImport, session.report == nil else { return }
        loadMicroSIPPreview(ini: session.iniURL, contacts: url)
    }

    /// `Contacts.xml` in the same folder, whatever its capitalisation (Windows does not care).
    static func contactsFile(next ini: URL) -> URL? {
        let folder = ini.deletingLastPathComponent()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.first { $0.lowercased() == "contacts.xml" }.map { folder.appendingPathComponent($0) }
    }

    private func loadMicroSIPPreview(ini: URL, contacts: URL?) {
        let outcome: MicroSIPImportSession.Outcome
        do {
            let plan = try MicroSIPImport.read(ini: ini, contacts: contacts)
            outcome = .preview(MicroSIPImport.merge(plan, existingAccounts: accounts, existingContacts: self.contacts))
        } catch let error as MicroSIPImport.ReadError {
            outcome = .failed(error)
        } catch {
            outcome = .failed(.iniUnreadable)
        }
        if microSIPImport == nil {
            microSIPImport = MicroSIPImportSession(iniURL: ini, contactsURL: contacts, outcome: outcome)
        } else {
            microSIPImport?.iniURL = ini
            microSIPImport?.contactsURL = contacts
            microSIPImport?.outcome = outcome
        }
    }

    func cancelMicroSIPImport() { microSIPImport = nil }

    // MARK: - Writing

    /// Saves what the preview shows. Accounts go in switched off and without a password (nothing is written to
    /// the Keychain), with their caller names stored like the editor stores them; contacts go through the
    /// contact store and `contacts` is refreshed from it. The session turns into the report.
    func applyMicroSIPImport() {
        guard let session = microSIPImport, session.report == nil, case let .preview(merge) = session.outcome, !merge.isEmpty else { return }
        do {
            try MicroSIPImport.apply(merge, accounts: accountStore, contacts: contactStore)
        } catch {
            report(error)
            return
        }
        // Keep the order the list has now, then the new accounts in file order.
        var order = accounts.map { $0.id.raw.uuidString }
        for a in merge.accounts {
            let id = a.config.id
            if !order.contains(id.raw.uuidString) { order.append(id.raw.uuidString) }
            setCallerName(a.callerName, for: id)
        }
        prefs.set(order, forKey: "accountOrder")
        var pending = (prefs.stringArray(forKey: "accountsNeedingPassword") ?? [])
        pending += merge.accounts.map { $0.config.id.raw.uuidString }
        prefs.set(pending, forKey: "accountsNeedingPassword")
        loadStores()
        syncPresenceSubscriptions()
        let report = MicroSIPImportSession.Report(
            accounts: merge.accounts.map { $0.config.displayName }, contacts: merge.contacts.count,
            firstAccount: merge.accounts.first?.config.id)
        microSIPImport?.report = report
        AppLog.app.info("MicroSIP import: \(report.accounts.count) accounts, \(report.contacts) contacts")
        showBanner(L.importDoneBanner(accounts: report.accounts.count, contacts: report.contacts), isError: false, seconds: 8)
    }

    /// The sheet's last step: closes it and, when accounts came in, opens the editor of the first one.
    func finishMicroSIPImport(openEditor: Bool) {
        let first = microSIPImport?.report?.firstAccount
        microSIPImport = nil
        guard openEditor, let first else { return }
        settingsSelectedAccount = first
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(450))      // the sheet has to be gone before the next one can open
            self.settingsEditor = AccountEditorRequest(accountID: first)
        }
    }

    // MARK: - Accounts without a password

    func accountNeedsPassword(_ id: AccountID) -> Bool { accountsNeedingPassword.contains(id) }

    /// A password was typed for the account (or the account is gone): it no longer needs one.
    func clearNeedsPassword(_ id: AccountID) {
        guard accountsNeedingPassword.contains(id) else { return }
        accountsNeedingPassword.remove(id)
        prefs.set(accountsNeedingPassword.map { $0.raw.uuidString }, forKey: "accountsNeedingPassword")
    }
}
