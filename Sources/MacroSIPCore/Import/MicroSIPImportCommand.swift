import Foundation

/// `MacroSIP --import-microsip <MicroSIP.ini> [--contacts <Contacts.xml>] [--data-dir <dir>] [--dry-run]`: the import
/// for scripts and MDM, shared by the app binary and `macrosip-cli`. Runs without UI, Keychain or engine and writes
/// through the same stores as the app. Exit codes: 0 done, 1 refused or failed, 2 wrong arguments.
public enum MicroSIPImportCommand {
    public struct Arguments: Equatable, Sendable {
        public var ini: URL
        public var contacts: URL?
        public var dataDirectory: URL?
        public var dryRun = false
    }

    /// What differs between the callers. Core has no UI imports, so the running-app check comes from outside.
    public struct Environment {
        /// The name shown in the usage line.
        public var program: String
        /// Another process of the app is running (see `isOtherProcess`).
        public var isAppRunning: () -> Bool
        /// The app's own data directory; nothing is created by asking for it.
        public var appDataDirectory: URL
        /// The app's preferences. Only touched for an import into `appDataDirectory`.
        public var defaults: () -> UserDefaults?
        public var output: (String) -> Void
        public var errorOutput: (String) -> Void

        public init(program: String, isAppRunning: @escaping () -> Bool,
                    appDataDirectory: URL = JSONStore<[Contact]>.appSupportLocation(),
                    defaults: @escaping () -> UserDefaults? = MicroSIPImportCommand.appDefaults,
                    output: @escaping (String) -> Void = { print($0) },
                    errorOutput: @escaping (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }) {
            self.program = program
            self.isAppRunning = isAppRunning
            self.appDataDirectory = appDataDirectory
            self.defaults = defaults
            self.output = output
            self.errorOutput = errorOutput
        }
    }

    /// The command line asks for the import.
    public static func isRequested(_ arguments: [String]) -> Bool {
        arguments.contains("--import-microsip")
    }

    /// One of these processes of the app is not this one.
    public static func isOtherProcess(among pids: [Int32], current: Int32) -> Bool {
        pids.contains { $0 != current }
    }

    /// The defaults of `com.hsmm.macrosip`: inside the app that domain is `.standard` (a suite cannot carry the
    /// main bundle's own identifier), any other process reaches it as a suite.
    public static func appDefaults() -> UserDefaults? {
        Bundle.main.bundleIdentifier == Product.bundleIdentifier ? .standard : UserDefaults(suiteName: Product.bundleIdentifier)
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

    /// Runs the import and returns the exit code. A dry run writes nothing at all.
    public static func run(_ args: [String], _ env: Environment) -> Int32 {
        guard let a = parse(args) else {
            env.errorOutput("usage: \(env.program) --import-microsip <MicroSIP.ini> [--contacts <Contacts.xml>] [--data-dir <dir>] [--dry-run]")
            return 2
        }
        let plan: MicroSIPImport.Plan
        do { plan = try MicroSIPImport.read(ini: a.ini, contacts: a.contacts) }
        catch let e as MicroSIPImport.ReadError { env.errorOutput(message(e, a.ini)); return 1 }
        catch { env.errorOutput("cannot import: \(error)"); return 1 }

        let dir = a.dataDirectory ?? env.appDataDirectory
        let usesAppData = dir.standardizedFileURL.path == env.appDataDirectory.standardizedFileURL.path
        if !a.dryRun, usesAppData, env.isAppRunning() {
            env.errorOutput("MacroSIP is running and would overwrite the import. Quit MacroSIP and run the command again.")
            return 1
        }

        // Read first, with no side effects: a damaged store is reported and left for the user, never moved aside.
        let existingAccounts: [AccountConfig], existingContacts: [Contact]
        do {
            existingAccounts = try AccountStore.read(directory: dir)
            existingContacts = try ContactStore.read(directory: dir)
        } catch {
            env.errorOutput("cannot read the existing data in \(dir.path), left as it is: \(error.localizedDescription)")
            return 1
        }
        let merge = MicroSIPImport.merge(plan, existingAccounts: existingAccounts, existingContacts: existingContacts)
        if a.dryRun {
            report(merge, dryRun: true, dir: dir, usesAppData: usesAppData, env)
            return 0
        }

        do { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        catch { env.errorOutput("cannot create \(dir.path): \(error.localizedDescription)"); return 1 }
        let saved = MicroSIPImport.save(merge, accounts: AccountStore(directory: dir), contacts: ContactStore(directory: dir))
        if usesAppData, let defaults = env.defaults() {
            MicroSIPImport.recordSaved(saved.accounts, in: defaults)
            defaults.synchronize()      // this process exits right away
        }
        if let error = saved.error {
            env.errorOutput("cannot save: \(error.localizedDescription). Saved before the error: "
                            + "\(saved.accounts.count) account(s), \(saved.contacts) contact(s).")
            return 1
        }
        report(merge, dryRun: false, dir: dir, usesAppData: usesAppData, env)
        return 0
    }

    private static func report(_ m: MicroSIPImport.Merge, dryRun: Bool, dir: URL, usesAppData: Bool, _ env: Environment) {
        let out = env.output
        out(dryRun ? "Dry run, nothing was written." : "Import done. Data directory: \(dir.path)")
        out("Accounts: \(m.accounts.count) \(dryRun ? "to import" : "imported"), \(m.skippedAccounts.count) skipped")
        for a in m.accounts {
            out("  + \(a.config.displayName) (\(a.config.username)@\(a.config.domain))\(a.config.isDefaultOutgoing ? " [default outgoing]" : "")")
        }
        for s in m.skippedAccounts {
            out("  - \(s.account.config.displayName): \(s.reason == .duplicateOfExisting ? "already exists" : "repeated in the file")")
        }
        out("Contacts: \(m.contacts.count) \(dryRun ? "to import" : "imported"), \(m.skippedContacts.count) skipped")
        for s in m.skippedContacts {
            let why = s.reason == .duplicateOfExisting ? "number already in Contacts" : "number repeated in the file"
            out("  - \(s.contact.displayName) (\(s.contact.number)): \(why)")
        }
        for w in m.warnings { out("Warning: \(describe(w))") }
        guard !m.accounts.isEmpty else { return }
        if m.accounts.contains(where: { MicroSIPImport.needsPassword($0.config) }) {
            out("Imported accounts are disabled. Open each one in MacroSIP, type its password and turn it on.")
        } else {
            out("Imported accounts are disabled. Turn them on in MacroSIP.")
        }
        if !usesAppData {
            out("Note: not the app's own data directory, so caller names and password marks are not stored.")
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
        case let .tooManyAccounts(limit): return "too many accounts in the file, only the first \(limit) are read"
        case let .tooManyContacts(limit): return "too many contacts in the file, only the first \(limit) are read"
        }
    }

    private static func message(_ e: MicroSIPImport.ReadError, _ ini: URL) -> String {
        switch e {
        case .iniNotFound: return "\(ini.path) does not exist"
        case .iniUnreadable: return "\(ini.path) cannot be read"
        case let .iniTooLarge(n): return "\(ini.path) is too large (\(n) bytes, the limit is \(MicroSIPImport.maxINIFileSize))"
        case .noAccountSections: return "\(ini.path) has no [Account1], [Account2], ... section; is it a MicroSIP.ini?"
        }
    }
}
