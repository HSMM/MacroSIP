import AppKit
import Foundation
import MacroSIPCore

/// `macrosip-cli --import-microsip <MicroSIP.ini> [--contacts <Contacts.xml>] [--data-dir <dir>] [--dry-run]`
/// Runs without the engine and writes through the same stores as the app.
enum ImportCommand {
    static let usage = "usage: macrosip-cli --import-microsip <MicroSIP.ini> [--contacts <Contacts.xml>] [--data-dir <dir>] [--dry-run]"

    struct Arguments {
        var ini: URL
        var contacts: URL?
        var dataDirectory: URL?
        var dryRun = false
    }

    static func parse(_ args: [String]) -> Arguments? {
        var ini: URL?, contacts: URL?, dir: URL?, dry = false
        var it = args.dropFirst().makeIterator()
        while let a = it.next() {
            switch a {
            case "--import-microsip": ini = it.next().map { URL(fileURLWithPath: $0) }
            case "--contacts": contacts = it.next().map { URL(fileURLWithPath: $0) }
            case "--data-dir": dir = it.next().map { URL(fileURLWithPath: $0, isDirectory: true) }
            case "--dry-run": dry = true
            default: return nil
            }
        }
        guard let ini else { return nil }
        return Arguments(ini: ini, contacts: contacts, dataDirectory: dir, dryRun: dry)
    }

    static func run(_ args: [String]) -> Int32 {
        guard let a = parse(args) else { fail(usage); return 2 }
        let plan: MicroSIPImport.Plan
        do { plan = try MicroSIPImport.read(ini: a.ini, contacts: a.contacts) }
        catch let e as MicroSIPImport.ReadError { fail(message(e, a.ini)); return 1 }
        catch { fail("cannot import: \(error)"); return 1 }

        let defaultDir = JSONStore<[Contact]>.appSupportDirectory()
        let dir = a.dataDirectory ?? defaultDir
        let usesAppData = dir.standardizedFileURL.path == defaultDir.standardizedFileURL.path
        if !a.dryRun, usesAppData, !NSRunningApplication.runningApplications(withBundleIdentifier: "com.hsmm.macrosip").isEmpty {
            fail("MacroSIP is running and would overwrite the import. Quit MacroSIP and run the command again.")
            return 1
        }
        do { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        catch { fail("cannot create \(dir.path): \(error.localizedDescription)"); return 1 }

        let accountStore = AccountStore(directory: dir)
        let contactStore = ContactStore(directory: dir)
        let merge = MicroSIPImport.merge(plan, existingAccounts: accountStore.all(), existingContacts: contactStore.all())
        if !a.dryRun {
            do {
                try MicroSIPImport.apply(merge, accounts: accountStore, contacts: contactStore)
                if usesAppData { rememberCallerNames(merge.accounts) }
            } catch { fail("cannot save: \(error.localizedDescription)"); return 1 }
        }
        report(merge, dryRun: a.dryRun, dir: dir)
        return 0
    }

    // The app keeps caller names and the account order in its preferences, not in accounts.json.
    private static func rememberCallerNames(_ accounts: [MicroSIPImport.Account]) {
        guard !accounts.isEmpty, let prefs = UserDefaults(suiteName: "com.hsmm.macrosip") else { return }
        var names = (prefs.dictionary(forKey: "callerNames") as? [String: String]) ?? [:]
        var order = prefs.stringArray(forKey: "accountOrder") ?? []
        for a in accounts {
            let id = a.config.id.raw.uuidString
            if !a.callerName.isEmpty { names[id] = a.callerName }
            if !order.contains(id) { order.append(id) }
        }
        prefs.set(names, forKey: "callerNames")
        prefs.set(order, forKey: "accountOrder")
    }

    private static func report(_ m: MicroSIPImport.Merge, dryRun: Bool, dir: URL) {
        print(dryRun ? "Dry run, nothing was written." : "Import done. Data directory: \(dir.path)")
        print("Accounts: \(m.accounts.count) \(dryRun ? "to import" : "imported"), \(m.skippedAccounts.count) skipped")
        for a in m.accounts {
            print("  + \(a.config.displayName) (\(a.config.username)@\(a.config.domain))\(a.config.isDefaultOutgoing ? " [default outgoing]" : "")")
        }
        for s in m.skippedAccounts {
            print("  - \(s.account.config.displayName): \(s.reason == .duplicateOfExisting ? "already exists" : "repeated in the file")")
        }
        print("Contacts: \(m.contacts.count) \(dryRun ? "to import" : "imported"), \(m.skippedContacts.count) skipped")
        for s in m.skippedContacts {
            let why = s.reason == .duplicateOfExisting ? "number already in Contacts" : "number repeated in the file"
            print("  - \(s.contact.displayName) (\(s.contact.number)): \(why)")
        }
        for w in m.warnings { print("Warning: \(describe(w))") }
        if !m.accounts.isEmpty {
            print("Imported accounts are disabled. Open each one in MacroSIP, type its password and turn it on.")
        }
    }

    private static func describe(_ w: MicroSIPImport.Warning) -> String {
        switch w {
        case let .accountSkippedMissingUsername(s): return "\(s) skipped: no username"
        case let .accountSkippedMissingDomain(s): return "\(s) skipped: no domain or server"
        case let .unknownTransport(s, v): return "\(s): unknown transport \"\(v)\", using UDP"
        case let .unknownSRTP(s, v): return "\(s): unknown SRTP mode \"\(v)\", using disabled"
        case let .dialRulesNotImported(s): return "\(s): dialing prefix and dial plan are not imported"
        case .contactsFileNotFound: return "the contacts file was not found, contacts not imported"
        case .contactsFileUnreadable: return "the contacts file cannot be read, contacts not imported"
        case .contactsFileTooLarge: return "the contacts file is larger than 10 MB, contacts not imported"
        case .contactsFileMalformed: return "the contacts file is not valid, contacts not imported"
        case let .contactsSkippedWithoutNumber(n): return "\(n) contact(s) without a number skipped"
        case let .contactsSkippedFromDirectory(n): return "\(n) directory entr\(n == 1 ? "y" : "ies") skipped"
        }
    }

    private static func message(_ e: MicroSIPImport.ReadError, _ ini: URL) -> String {
        switch e {
        case .iniNotFound: return "\(ini.path) does not exist"
        case .iniUnreadable: return "\(ini.path) cannot be read"
        case let .iniTooLarge(n): return "\(ini.path) is too large (\(n) bytes, the limit is \(MicroSIPImport.maxFileSize))"
        case .noAccountSections: return "\(ini.path) has no [Account1], [Account2], ... section; is it a MicroSIP.ini?"
        }
    }

    private static func fail(_ text: String) {
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }
}
