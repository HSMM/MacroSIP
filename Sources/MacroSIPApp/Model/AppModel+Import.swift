import AppKit
import MacroSIPCore

/// The Import from MicroSIP sheet: which file, what it contains, and what was done.
struct MicroSIPImportSession: Identifiable {
    enum Outcome: Sendable {
        /// The files are being read, off the main actor.
        case loading
        case preview(MicroSIPImport.Merge)
        case failed(MicroSIPImport.ReadError)
    }

    /// What an import did.
    struct Report: Equatable {
        struct Account: Equatable {
            var name: String
            var needsPassword: Bool
        }
        var accounts: [Account]         // in file order
        var contacts: Int
        var firstAccount: AccountID?    // the first that needs a password: its editor opens next
    }

    let id = UUID()
    var iniURL: URL
    /// nil = no contacts file (found none, or the user chose none).
    var contactsURL: URL?
    var outcome: Outcome
    var report: Report?
    /// Why (some of) the import could not be saved; shown in the sheet.
    var saveError: String?
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

    /// Opens the sheet at once and reads the files off the main actor: a crafted file must not freeze the app.
    private func loadMicroSIPPreview(ini: URL, contacts: URL?) {
        microSIPLoad?.cancel()
        if microSIPImport == nil {
            microSIPImport = MicroSIPImportSession(iniURL: ini, contactsURL: contacts, outcome: .loading)
        } else {
            microSIPImport?.iniURL = ini
            microSIPImport?.contactsURL = contacts
            microSIPImport?.outcome = .loading
        }
        let existingAccounts = accounts, existingContacts = self.contacts
        microSIPLoad = Task { @MainActor [weak self] in
            let outcome = await Task.detached(priority: .userInitiated) {
                Self.microSIPPreview(ini: ini, contacts: contacts, accounts: existingAccounts, existingContacts: existingContacts)
            }.value
            guard !Task.isCancelled else { return }
            self?.microSIPImport?.outcome = outcome
        }
    }

    private nonisolated static func microSIPPreview(ini: URL, contacts: URL?, accounts: [AccountConfig],
                                                    existingContacts: [Contact]) -> MicroSIPImportSession.Outcome {
        do {
            let plan = try MicroSIPImport.read(ini: ini, contacts: contacts)
            return .preview(MicroSIPImport.merge(plan, existingAccounts: accounts, existingContacts: existingContacts))
        } catch let error as MicroSIPImport.ReadError {
            return .failed(error)
        } catch {
            return .failed(.iniUnreadable)
        }
    }

    /// Awaits the read started by `beginMicroSIPImport` or `setMicroSIPContacts`.
    func waitForMicroSIPPreview() async { await microSIPLoad?.value }

    func cancelMicroSIPImport() {
        microSIPLoad?.cancel()
        microSIPImport = nil
    }

    // MARK: - Writing

    /// Saves what the preview shows. Accounts go in switched off and without a password (nothing is written to
    /// the Keychain); contacts go through the contact store. Flags and caller names follow what was really saved, the
    /// lists are reloaded from the stores, and a failure is shown: in the sheet, which stays on the preview when
    /// nothing was saved and otherwise turns into the report. `contactsTo` is a seam for the self-check.
    func applyMicroSIPImport(contactsTo store: ContactStore? = nil) {
        guard let session = microSIPImport, session.report == nil, case let .preview(merge) = session.outcome, !merge.isEmpty else { return }
        let saved = MicroSIPImport.save(merge, accounts: accountStore, contacts: store ?? contactStore)
        // Keep the order the list has now, then the new accounts in file order.
        MicroSIPImport.recordSaved(saved.accounts, in: prefs, order: accounts.map { $0.id.raw.uuidString })
        loadStores()
        syncPresenceSubscriptions()
        if let error = saved.error {
            report(error)
            microSIPImport?.saveError = L.importErrorSave(describe(error))
            if saved.accounts.isEmpty && saved.contacts == 0 { return }
        }
        let report = MicroSIPImportSession.Report(
            accounts: saved.accounts.map { .init(name: $0.config.displayName, needsPassword: MicroSIPImport.needsPassword($0.config)) },
            contacts: saved.contacts,
            firstAccount: saved.accounts.first { MicroSIPImport.needsPassword($0.config) }?.config.id)
        microSIPImport?.report = report
        AppLog.app.info("MicroSIP import: \(report.accounts.count) accounts, \(report.contacts) contacts")
        if saved.error == nil {
            showBanner(L.importDoneBanner(accounts: report.accounts.count, contacts: report.contacts), isError: false, seconds: 8)
        }
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
        prefs.set(accountsNeedingPassword.map { $0.raw.uuidString }, forKey: MicroSIPImport.PreferenceKey.accountsNeedingPassword)
    }
}
