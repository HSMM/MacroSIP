import Foundation

/// Import of accounts and contacts from MicroSIP (`MicroSIP.ini`, `Contacts.xml`).
///
/// Three steps, the first two pure (nothing is written):
/// 1. `read(ini:contacts:)` parses the files into a `Plan`.
/// 2. `merge(_:existingAccounts:existingContacts:)` sorts the plan into what is new and what is a duplicate.
/// 3. `apply(_:accounts:contacts:)` saves the new items through the app's stores.
///
/// Passwords are never read: MicroSIP encrypts them with a key built into the program, and the parser drops
/// the `password` keys before anything is stored. Imported accounts are disabled until the user types a password.
/// Caller names have no field in `AccountConfig`; the app keeps them next to the account (`Account.callerName`).
public enum MicroSIPImport {
    /// Files larger than this are refused.
    public static let maxFileSize = 10 * 1024 * 1024

    // MARK: Plan

    /// One account of the INI file, mapped but not yet compared with the existing accounts.
    public struct Account: Equatable, Sendable {
        /// `enabled` is false and `isDefaultOutgoing` is false; `merge` decides the default.
        public var config: AccountConfig
        /// The INI key `displayName` (the name sent as caller name); empty when not set.
        public var callerName: String
        /// The account `[Settings] accountId` points at.
        public var isActiveInSource: Bool
        /// The INI section, e.g. "Account2".
        public var section: String
    }

    public enum Warning: Equatable, Hashable, Sendable {
        case accountSkippedMissingUsername(section: String)
        case accountSkippedMissingDomain(section: String)
        /// The value is read as UDP.
        case unknownTransport(section: String, value: String)
        /// The value is read as SRTP disabled.
        case unknownSRTP(section: String, value: String)
        /// The account has a dialing prefix or dial plan, which MacroSIP does not have.
        case dialRulesNotImported(section: String)
        /// The Contacts.xml that was named does not exist.
        case contactsFileNotFound
        case contactsFileUnreadable
        case contactsFileTooLarge
        case contactsFileMalformed
        /// Contacts without a number (MicroSIP ignores them too).
        case contactsSkippedWithoutNumber(count: Int)
        /// Entries that came from a server directory (`directory="1"`).
        case contactsSkippedFromDirectory(count: Int)
    }

    public struct Plan: Equatable, Sendable {
        public var accounts: [Account]
        public var contacts: [Contact]
        public var warnings: [Warning]
    }

    public enum ReadError: Error, Equatable, Sendable {
        case iniNotFound
        case iniUnreadable
        case iniTooLarge(bytes: Int)
        /// The file has no `[AccountN]` section.
        case noAccountSections
    }

    // MARK: Merge

    public enum AccountSkipReason: Equatable, Sendable {
        case duplicateOfExisting
        case duplicateInFile
    }

    public enum ContactSkipReason: Equatable, Sendable {
        case duplicateOfExisting
        case duplicateInFile
    }

    public struct SkippedAccount: Equatable, Sendable {
        public var account: Account
        public var reason: AccountSkipReason
    }

    public struct SkippedContact: Equatable, Sendable {
        public var contact: Contact
        public var reason: ContactSkipReason
    }

    public struct Merge: Equatable, Sendable {
        /// To be saved. Disabled; at most one has `isDefaultOutgoing`, and only when there were no accounts before.
        public var accounts: [Account]
        public var skippedAccounts: [SkippedAccount]
        public var contacts: [Contact]
        public var skippedContacts: [SkippedContact]
        /// The plan's warnings.
        public var warnings: [Warning]

        public var isEmpty: Bool { accounts.isEmpty && contacts.isEmpty }
    }

    // MARK: Reading

    /// Reads the INI and, when given, the contacts file. A contacts file that is missing, too large or
    /// malformed does not fail the import; it adds a warning.
    public static func read(ini: URL, contacts: URL? = nil) throws -> Plan {
        let fm = FileManager.default
        guard fm.fileExists(atPath: ini.path) else { throw ReadError.iniNotFound }
        let iniData: Data
        switch loadFile(ini) {
        case let .data(d): iniData = d
        case .tooLarge(let n): throw ReadError.iniTooLarge(bytes: n)
        case .unreadable: throw ReadError.iniUnreadable
        }
        var contactsData: Data?
        var extra: [Warning] = []
        if let contacts {
            if !fm.fileExists(atPath: contacts.path) {
                extra.append(.contactsFileNotFound)
            } else {
                switch loadFile(contacts) {
                case let .data(d): contactsData = d
                case .tooLarge: extra.append(.contactsFileTooLarge)
                case .unreadable: extra.append(.contactsFileUnreadable)
                }
            }
        }
        var plan = try plan(iniData: iniData, contactsData: contactsData)
        plan.warnings += extra
        return plan
    }

    /// The same from bytes already in memory (size is not checked here).
    public static func plan(iniData: Data, contactsData: Data? = nil) throws -> Plan {
        let ini = INIFile(text: decodeText(iniData))
        let (accounts, warnings) = accounts(from: ini)
        guard ini.sections.contains(where: { accountNumber($0.name) != nil }) else { throw ReadError.noAccountSections }
        var plan = Plan(accounts: accounts, contacts: [], warnings: warnings)
        if let contactsData {
            switch ContactsXML.parse(contactsData) {
            case let .success(entries):
                var noNumber = 0, directory = 0
                for e in entries {
                    if e.isDirectory { directory += 1; continue }
                    guard let c = contact(from: e) else { noNumber += 1; continue }
                    plan.contacts.append(c)
                }
                if noNumber > 0 { plan.warnings.append(.contactsSkippedWithoutNumber(count: noNumber)) }
                if directory > 0 { plan.warnings.append(.contactsSkippedFromDirectory(count: directory)) }
            case .failure:
                plan.warnings.append(.contactsFileMalformed)
            }
        }
        return plan
    }

    private enum Loaded { case data(Data), tooLarge(Int), unreadable }

    private static func loadFile(_ url: URL) -> Loaded {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber else { return .unreadable }
        if size.intValue > maxFileSize { return .tooLarge(size.intValue) }
        guard let data = try? Data(contentsOf: url) else { return .unreadable }
        return data.count > maxFileSize ? .tooLarge(data.count) : .data(data)
    }

    // MARK: Merging

    /// Sorts the plan into new items and duplicates. An account is a duplicate when username and domain
    /// (domain case-insensitive) match an existing account or an earlier one in the file; a contact when its
    /// default number matches a number of an existing or earlier contact (`Contact.hasNumber`).
    public static func merge(_ plan: Plan, existingAccounts: [AccountConfig], existingContacts: [Contact]) -> Merge {
        func key(_ a: AccountConfig) -> String {
            a.username.trimmingCharacters(in: .whitespaces) + "@" + a.domain.trimmingCharacters(in: .whitespaces).lowercased()
        }
        var seen = Set(existingAccounts.map(key))
        var fresh: [Account] = []
        var skippedAccounts: [SkippedAccount] = []
        var inFile = Set<String>()
        for a in plan.accounts {
            let k = key(a.config)
            if inFile.contains(k) {
                skippedAccounts.append(SkippedAccount(account: a, reason: .duplicateInFile))
            } else if seen.contains(k) {
                skippedAccounts.append(SkippedAccount(account: a, reason: .duplicateOfExisting))
            } else {
                fresh.append(a)
            }
            inFile.insert(k)
            seen.insert(k)
        }
        if existingAccounts.isEmpty, !fresh.isEmpty {
            fresh[fresh.firstIndex { $0.isActiveInSource } ?? 0].config.isDefaultOutgoing = true
        }

        var known = existingContacts
        var accepted: [Contact] = []
        var skippedContacts: [SkippedContact] = []
        for c in plan.contacts {
            let number = c.number
            if existingContacts.contains(where: { $0.hasNumber(number) }) {
                skippedContacts.append(SkippedContact(contact: c, reason: .duplicateOfExisting))
            } else if known.contains(where: { $0.hasNumber(number) }) {
                skippedContacts.append(SkippedContact(contact: c, reason: .duplicateInFile))
            } else {
                accepted.append(c)
                known.append(c)
            }
        }
        return Merge(accounts: fresh, skippedAccounts: skippedAccounts, contacts: accepted,
                     skippedContacts: skippedContacts, warnings: plan.warnings)
    }

    /// Saves the new accounts and contacts. Passwords and caller names are not handled here: the accounts have
    /// no password (they are disabled), and the caller names are the caller's to store (`Account.callerName`).
    public static func apply(_ merge: Merge, accounts: AccountStore, contacts: ContactStore) throws {
        for a in merge.accounts { try accounts.upsert(a.config) }
        try contacts.upsert(contentsOf: merge.contacts)
    }

    // MARK: Account mapping

    static func accountNumber(_ section: String) -> Int? {
        let s = section.lowercased()
        guard s.hasPrefix("account"), let n = Int(s.dropFirst(7)), n > 0 else { return nil }
        return n
    }

    private static func accounts(from ini: INIFile) -> ([Account], [Warning]) {
        let active = ini.value("settings", "accountid").flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } ?? 0
        var warnings: [Warning] = []
        var out: [Account] = []
        let numbered = ini.sections.compactMap { s in accountNumber(s.name).map { ($0, s) } }.sorted { $0.0 < $1.0 }
        for (number, section) in numbered {
            let name = section.name
            func v(_ key: String) -> String { section.values[key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
            let username = v("username")
            guard !username.isEmpty else { warnings.append(.accountSkippedMissingUsername(section: name)); continue }
            let server = normalizeAddress(v("server"))
            var domain = normalizeAddress(v("domain"))
            if domain.isEmpty { domain = hostPart(server) }
            guard !domain.isEmpty else { warnings.append(.accountSkippedMissingDomain(section: name)); continue }

            let transport: TransportKind
            switch v("transport").lowercased() {
            case "", "udp": transport = .udp
            case "tcp": transport = .tcp
            case "tls": transport = .tls
            default:
                transport = .udp
                warnings.append(.unknownTransport(section: name, value: v("transport")))
            }
            let srtp: SRTPMode
            switch v("srtp").lowercased() {
            case "": srtp = .disabled
            case "optional": srtp = .optional
            case "mandatory": srtp = .mandatory
            default:
                srtp = .disabled
                warnings.append(.unknownSRTP(section: name, value: v("srtp")))
            }
            if !v("dialingprefix").isEmpty || !v("dialplan").isEmpty { warnings.append(.dialRulesNotImported(section: name)) }

            let proxy = normalizeAddress(v("proxy"))
            let authID = v("authid")
            let voicemail = v("voicemailnumber")
            var interval = 300
            if let n = Int(v("registerrefresh")) { interval = n <= 0 ? 300 : (n <= 10 ? 10 : n) }
            let label = v("label")

            let config = AccountConfig(
                displayName: label.isEmpty ? "\(username)@\(domain)" : label,
                username: username,
                domain: domain,
                registrar: (!server.isEmpty && server.lowercased() != domain.lowercased()) ? server : nil,
                outboundProxy: proxy.isEmpty ? nil : proxy,
                authID: (!authID.isEmpty && authID != username) ? authID : nil,
                transport: transport,
                srtp: srtp,
                enabled: false,
                registerWithServer: !server.isEmpty,   // MicroSIP sends no REGISTER without a server
                registrationInterval: interval,
                publishPresence: v("publish") == "1",
                voicemailNumber: voicemail.isEmpty ? nil : voicemail)
            out.append(Account(config: config, callerName: v("displayname"), isActiveInSource: number == active, section: name))
        }
        return (out, warnings)
    }

    /// "sip:host:5060;transport=tcp" becomes "host:5060": no scheme, no brackets, no parameters, port kept.
    /// The engine adds the scheme, the transport and `lr` itself.
    static func normalizeAddress(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("<"), s.hasSuffix(">") { s = String(s.dropFirst().dropLast()) }
        for scheme in ["sips:", "sip:"] where s.lowercased().hasPrefix(scheme) {
            s.removeFirst(scheme.count)
            break
        }
        if let semi = s.firstIndex(of: ";") { s = String(s[..<semi]) }
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// The host of "host:port" (IPv6 literals in brackets keep them).
    static func hostPart(_ address: String) -> String {
        var s = address
        if let at = s.lastIndex(of: "@") { s = String(s[s.index(after: at)...]) }
        if s.hasPrefix("["), let close = s.firstIndex(of: "]") { return String(s[...close]) }
        return String(s.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
    }

    // MARK: Contact mapping

    private static func contact(from e: ContactsXML.Entry) -> Contact? {
        let number = e.number
        guard !number.isEmpty else { return nil }
        var first = e.firstName, last = e.lastName
        if first.isEmpty && last.isEmpty { (first, last) = Contact.splitName(e.name) }

        var numbers = [PhoneNumber(label: label(for: number), value: number, isDefault: true)]
        for (value, label) in [(e.phone, PhoneLabel.work), (e.mobile, PhoneLabel.mobile)] where !value.isEmpty {
            let key = Contact.normalize(value)
            if !numbers.contains(where: { Contact.normalize($0.value) == key }) {
                numbers.append(PhoneNumber(label: label, value: value))
            }
        }
        let place = [e.address, e.city, [e.state, e.zip].filter { !$0.isEmpty }.joined(separator: " ")]
            .filter { !$0.isEmpty }.joined(separator: ", ")
        let notes = [e.comment, e.info, place].filter { !$0.isEmpty }.joined(separator: "\n")
        return Contact(firstName: first, lastName: last, numbers: numbers, email: e.email, notes: notes,
                       subscribePresence: e.presence)
    }

    /// A SIP address is labelled `.sip`; a plain number `.other`, as the 26.1 migration does.
    private static func label(for number: String) -> PhoneLabel {
        let l = number.lowercased()
        return (l.hasPrefix("sip:") || l.hasPrefix("sips:") || l.contains("@")) ? .sip : .other
    }

    // MARK: Text decoding

    /// UTF-16 with or without BOM, UTF-8 with or without BOM, else the Windows Cyrillic code page
    /// (Latin-1 if even that fails). A leading BOM is removed.
    static func decodeText(_ data: Data) -> String {
        let b = [UInt8](data.prefix(4))
        if b.count >= 2, b[0] == 0xFF, b[1] == 0xFE { return String(data: data.dropFirst(2), encoding: .utf16LittleEndian) ?? "" }
        if b.count >= 2, b[0] == 0xFE, b[1] == 0xFF { return String(data: data.dropFirst(2), encoding: .utf16BigEndian) ?? "" }
        if b.count >= 3, b[0] == 0xEF, b[1] == 0xBB, b[2] == 0xBF, let s = String(data: data.dropFirst(3), encoding: .utf8) { return s }
        if b.count >= 4, b[1] == 0, b[3] == 0, b[0] != 0, b[2] != 0 { return String(data: data, encoding: .utf16LittleEndian) ?? "" }
        if b.count >= 4, b[0] == 0, b[2] == 0, b[1] != 0, b[3] != 0 { return String(data: data, encoding: .utf16BigEndian) ?? "" }
        return String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .windowsCP1251)
            ?? String(data: data, encoding: .isoLatin1) ?? ""
    }
}

/// A parsed INI: section and key names lower-cased. Password keys are dropped while reading.
struct INIFile {
    struct Section { var name: String; var values: [String: String] }
    private(set) var sections: [Section] = []
    private var current: Int?

    /// Keys that never leave the parser.
    private static let secret: Set<String> = ["password", "passwordsize"]

    init(text: String) {
        for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix(";") { continue }
            if line.hasPrefix("[") {
                guard let close = line.firstIndex(of: "]") else { continue }
                let name = line[line.index(after: line.startIndex)..<close].trimmingCharacters(in: .whitespaces)
                if let i = sections.firstIndex(where: { $0.name.lowercased() == name.lowercased() }) {
                    // A repeated section continues the first one, like GetPrivateProfileString.
                    current = i
                } else {
                    sections.append(Section(name: name, values: [:]))
                    current = sections.count - 1
                }
                continue
            }
            guard let cur = current, let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            guard !key.isEmpty, !Self.secret.contains(key) else { continue }
            sections[cur].values[key] = Self.unquoted(line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces))
        }
    }

    /// GetPrivateProfileString removes one pair of surrounding quotes.
    private static func unquoted(_ value: String) -> String {
        guard value.count >= 2, let first = value.first, first == value.last, first == "\"" || first == "'" else { return value }
        return String(value.dropFirst().dropLast())
    }

    func value(_ section: String, _ key: String) -> String? {
        sections.first { $0.name.lowercased() == section }?.values[key]
    }
}

/// Contacts.xml: `<contacts><contact name= number= .../></contacts>`.
enum ContactsXML {
    struct Entry {
        var name = "", number = "", firstName = "", lastName = "", phone = "", mobile = "", email = ""
        var address = "", city = "", state = "", zip = "", comment = "", info = ""
        var presence = false, isDirectory = false
    }

    struct Malformed: Error {}

    static func parse(_ data: Data) -> Result<[Entry], Malformed> {
        // A document type declaration can define entities; MicroSIP files have none.
        let head = String(decoding: data.prefix(64 * 1024), as: UTF8.self).lowercased()
        if head.contains("<!doctype") || head.contains("<!entity") { return .failure(Malformed()) }
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        let delegate = Delegate()
        parser.delegate = delegate
        guard parser.parse(), delegate.sawRoot else { return .failure(Malformed()) }
        return .success(delegate.entries)
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var entries: [Entry] = []
        var sawRoot = false

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                    attributes a: [String: String]) {
            if name == "contacts" { sawRoot = true }
            guard name == "contact" else { return }
            func v(_ k: String) -> String { a[k]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
            entries.append(Entry(
                name: v("name"), number: v("number"), firstName: v("firstname"), lastName: v("lastname"),
                phone: v("phone"), mobile: v("mobile"), email: v("email"), address: v("address"), city: v("city"),
                state: v("state"), zip: v("zip"), comment: v("comment"), info: v("info"),
                presence: v("presence") == "1", isDirectory: v("directory") == "1"))
        }
    }
}
