import Foundation
import Testing
@testable import MacroSIPCore

@Suite struct MicroSIPImportTests {
    static let ini = """
    ; MicroSIP settings
    [Settings]\r
    accountId=2\r
    Unknown=whatever\r
    [Account1]\r
    label=Офис\r
    server=sip.example.com:5070\r
    proxy=sip:proxy.example.com:5061;transport=tls\r
    domain=example.com\r
    username=1001\r
    password=SECRETCIPHERTEXT123\r
    passwordSize=20\r
    authID=auth1001\r
    displayName=Иван\r
    transport=TLS\r
    SRTP=mandatory\r
    registerRefresh=120\r
    voicemailNumber=*97\r
    publish=1\r
    ICE=1\r
    futureKey=1\r
    [Account2]\r
    server=pbx.example.org\r
    username=2002\r
    authID=2002\r
    """

    func plan(_ text: String, contacts: String? = nil) throws -> MicroSIPImport.Plan {
        try MicroSIPImport.plan(iniData: Data(text.utf8), contactsData: contacts.map { Data($0.utf8) })
    }

    // MARK: accounts

    @Test func mapsAccountFields() throws {
        let p = try plan(Self.ini)
        #expect(p.accounts.count == 2)
        let a = p.accounts[0]
        #expect(a.config.displayName == "Офис")
        #expect(a.callerName == "Иван")
        #expect(a.config.username == "1001" && a.config.domain == "example.com")
        #expect(a.config.registrar == "sip.example.com:5070")
        #expect(a.config.outboundProxy == "proxy.example.com:5061")
        #expect(a.config.authID == "auth1001")
        #expect(a.config.transport == .tls && a.config.srtp == .mandatory)
        #expect(a.config.registrationInterval == 120)
        #expect(a.config.voicemailNumber == "*97")
        #expect(a.config.publishPresence)
        #expect(!a.config.enabled && !a.config.isDefaultOutgoing)
        #expect(!a.isActiveInSource && p.accounts[1].isActiveInSource)
    }

    @Test func missingDomainFallsBackToServerHostAndLabelToUserAtDomain() throws {
        let b = try plan(Self.ini).accounts[1].config
        #expect(b.domain == "pbx.example.org")
        #expect(b.registrar == nil)
        #expect(b.authID == nil)            // equals username
        #expect(b.displayName == "2002@pbx.example.org")
        #expect(b.transport == .udp && b.srtp == .disabled && b.registrationInterval == 300)
        let c = try plan("[Account1]\nusername=1\nserver=sip:host.example:5080;transport=tcp\n").accounts[0].config
        #expect(c.domain == "host.example" && c.registrar == "host.example:5080")
    }

    @Test func quotedValuesLoseTheirQuotes() throws {
        let p = try plan("[Account1]\nusername=\"1001\"\ndomain='example.com'\nlabel=\"Офис\"\n")
        #expect(p.accounts[0].config.username == "1001")
        #expect(p.accounts[0].config.domain == "example.com")
        #expect(p.accounts[0].config.displayName == "Офис")
    }

    @Test func accountWithoutServerDoesNotRegister() throws {
        let noServer = try plan("[Account1]\nusername=1001\ndomain=example.com\n")
        #expect(noServer.accounts[0].config.registerWithServer == false)
        let withServer = try plan("[Account1]\nusername=1001\nserver=example.com\n")
        #expect(withServer.accounts[0].config.registerWithServer == true)
    }

    @Test func transportAndSRTPMapping() throws {
        func one(_ extra: String) throws -> (AccountConfig, [MicroSIPImport.Warning]) {
            let p = try plan("[Account1]\nusername=1\ndomain=d\n\(extra)\n")
            return (p.accounts[0].config, p.warnings)
        }
        #expect(try one("transport=tcp").0.transport == .tcp)
        #expect(try one("transport=udp").0.transport == .udp)
        #expect(try one("srtp=optional").0.srtp == .optional)
        #expect(try one("srtp=").0.srtp == .disabled)
        let bad = try one("transport=ws\nsrtp=dtls")
        #expect(bad.0.transport == .udp && bad.0.srtp == .disabled)
        #expect(bad.1 == [.unknownTransport(section: "Account1", value: "ws"), .unknownSRTP(section: "Account1", value: "dtls")])
        #expect(try one("dialPlan=x").1 == [.dialRulesNotImported(section: "Account1")])
    }

    @Test func registerRefreshLimits() throws {
        func interval(_ v: String) throws -> Int {
            try plan("[Account1]\nusername=1\ndomain=d\nregisterRefresh=\(v)\n").accounts[0].config.registrationInterval
        }
        #expect(try interval("0") == 300)
        #expect(try interval("-5") == 300)
        #expect(try interval("abc") == 300)
        // Clamped to the range the account editor accepts.
        #expect(try interval("1") == 60)
        #expect(try interval("10") == 60)
        #expect(try interval("11") == 60)
        #expect(try interval("59") == 60)
        #expect(try interval("60") == 60)
        #expect(try interval("3600") == 3600)
        #expect(try interval("3601") == 3600)
    }

    @Test func userinfoIsStrippedFromAddresses() throws {
        #expect(MicroSIPImport.normalizeAddress("sip:user:secret@host.example:5070;transport=tcp") == "host.example:5070")
        #expect(MicroSIPImport.normalizeAddress("user@host.example") == "host.example")
        #expect(MicroSIPImport.normalizeAddress("<sips:u:p@[::1]:5061>") == "[::1]:5061")
        #expect(MicroSIPImport.normalizeAddress("host.example:5070") == "host.example:5070")
        let c = try plan("[Account1]\nusername=1\nserver=sip:user:secret@srv.example:5070\nproxy=a:hidden@edge.example\ndomain=b:hush@dom.example\n").accounts[0].config
        #expect(c.registrar == "srv.example:5070" && c.outboundProxy == "edge.example" && c.domain == "dom.example")
        let dump = String(decoding: try JSONEncoder().encode(c), as: UTF8.self)
        #expect(!dump.contains("secret") && !dump.contains("hidden") && !dump.contains("hush"))
    }

    @Test func accountsWithoutUsernameOrDomainAreSkipped() throws {
        let p = try plan("[Account1]\ndomain=d\n[Account2]\nusername=2\n[Account3]\nusername=3\ndomain=d\n")
        #expect(p.accounts.map(\.config.username) == ["3"])
        #expect(p.warnings == [.accountSkippedMissingUsername(section: "Account1"), .accountSkippedMissingDomain(section: "Account2")])
    }

    @Test func passwordNeverInThePlan() throws {
        let p = try plan(Self.ini)
        let dump = String(reflecting: p)
        #expect(!dump.contains("SECRETCIPHERTEXT123"))
        #expect(!dump.lowercased().contains("password"))
        let json = String(decoding: try JSONEncoder().encode(p.accounts.map(\.config)), as: UTF8.self)
        #expect(!json.contains("SECRETCIPHERTEXT123"))
    }

    @Test func caseInsensitiveNamesAndSectionOrder() throws {
        let p = try plan("[SETTINGS]\nACCOUNTID=3\n[account10]\nUSERNAME=ten\nDOMAIN=d\n[ACCOUNT3]\nUserName=three\ndomain=d\n")
        #expect(p.accounts.map(\.config.username) == ["three", "ten"])
        #expect(p.accounts[0].isActiveInSource)
    }

    // MARK: encodings

    @Test func everyEncoding() throws {
        let text = "[Account1]\r\nlabel=Приём\r\nusername=1001\r\ndomain=example.com\r\n"
        let utf16le = Data([0xFF, 0xFE]) + text.data(using: .utf16LittleEndian)!
        let utf16be = Data([0xFE, 0xFF]) + text.data(using: .utf16BigEndian)!
        let noBOM16 = text.data(using: .utf16LittleEndian)!
        let utf8 = Data(text.utf8)
        let utf8BOM = Data([0xEF, 0xBB, 0xBF]) + utf8
        let cp1251 = text.data(using: .windowsCP1251)!
        for (name, data) in [("utf16le", utf16le), ("utf16be", utf16be), ("utf16 no BOM", noBOM16),
                             ("utf8", utf8), ("utf8 BOM", utf8BOM), ("cp1251", cp1251)] {
            let p = try MicroSIPImport.plan(iniData: data)
            #expect(p.accounts.first?.config.displayName == "Приём", "\(name)")
            #expect(p.accounts.first?.config.username == "1001", "\(name)")
        }
    }

    // MARK: errors and limits

    @Test func readErrors() throws {
        try withTempDir { dir in
            let missing = dir.appendingPathComponent("none.ini")
            #expect(throws: MicroSIPImport.ReadError.iniNotFound) { try MicroSIPImport.read(ini: missing) }

            let noAccounts = dir.appendingPathComponent("a.ini")
            try "[Settings]\naccountId=0\n".write(to: noAccounts, atomically: true, encoding: .utf8)
            #expect(throws: MicroSIPImport.ReadError.noAccountSections) { try MicroSIPImport.read(ini: noAccounts) }

            let big = dir.appendingPathComponent("big.ini")
            try Data(count: MicroSIPImport.maxFileSize + 1).write(to: big)
            #expect(throws: MicroSIPImport.ReadError.iniTooLarge(bytes: MicroSIPImport.maxFileSize + 1)) {
                try MicroSIPImport.read(ini: big)
            }
            // A directory exists but cannot be read as a file.
            #expect(throws: MicroSIPImport.ReadError.iniUnreadable) { try MicroSIPImport.read(ini: dir) }
        }
    }

    @Test func iniOverOneMegabyteIsRefused() throws {
        try withTempDir { dir in
            let big = dir.appendingPathComponent("big.ini")
            try Data(count: MicroSIPImport.maxINIFileSize + 1).write(to: big)
            #expect(throws: MicroSIPImport.ReadError.iniTooLarge(bytes: MicroSIPImport.maxINIFileSize + 1)) {
                try MicroSIPImport.read(ini: big)
            }
        }
    }

    /// A crafted file at the size limit stays quick and is cut at the caps with a typed warning.
    @Test func craftedFilesAreCappedAndFast() throws {
        var ini = ""
        for i in 1...25_000 { ini += "[Account\(i)]\nusername=u\(i)\ndomain=d\n" }
        #expect(ini.utf8.count <= MicroSIPImport.maxINIFileSize)
        let clock = ContinuousClock()
        var xml = "<contacts>"
        for i in 0..<25_000 { xml += "<contact name=\"N\(i)\" number=\"\(1_000_000 + i)\"/>" }
        xml += "</contacts>"
        let existing = (0..<20_000).map { Contact(name: "E\($0)", number: "\(5_000_000 + $0)") }
        var p: MicroSIPImport.Plan?
        var m: MicroSIPImport.Merge?
        let elapsed = try clock.measure {
            p = try plan(ini, contacts: xml)
            if let p { m = MicroSIPImport.merge(p, existingAccounts: [], existingContacts: existing) }
        }
        let result = try #require(p)
        #expect(result.accounts.count == MicroSIPImport.maxAccounts)
        #expect(result.contacts.count == MicroSIPImport.maxContacts)
        #expect(result.warnings.contains(.tooManyAccounts(limit: MicroSIPImport.maxAccounts)))
        #expect(result.warnings.contains(.tooManyContacts(limit: MicroSIPImport.maxContacts)))
        #expect(m?.contacts.count == MicroSIPImport.maxContacts)
        #expect(elapsed < .seconds(30), "took \(elapsed)")
    }

    /// The fast merge gives the answers `Contact.hasNumber` gives.
    @Test func mergeAgreesWithHasNumber() throws {
        let existing = [
            Contact(firstName: "A", lastName: "", numbers: [PhoneNumber(label: .other, value: "+7 (495) 111", isDefault: true),
                                                            PhoneNumber(label: .sip, value: "sip:200@a.example")]),
            Contact(name: "B", number: "sip:300"),
        ]
        let numbers = ["+7495111", "sip:200@a.example", "sip:200@b.example", "200", "200@a.example", "sip:300@c.example", "300", "400", "sip:500@x", "sip:500@y", "500"]
        let xml = "<contacts>" + numbers.enumerated().map { "<contact name=\"N\($0.offset)\" number=\"\($0.element)\"/>" }.joined() + "</contacts>"
        let p = try plan(Self.ini, contacts: xml)
        let m = MicroSIPImport.merge(p, existingAccounts: [], existingContacts: existing)
        var known: [Contact] = []
        var expected: [MicroSIPImport.ContactSkipReason?] = []
        for c in p.contacts {
            if existing.contains(where: { $0.hasNumber(c.number) }) { expected.append(.duplicateOfExisting) }
            else if known.contains(where: { $0.hasNumber(c.number) }) { expected.append(.duplicateInFile) }
            else { expected.append(nil); known.append(c) }
        }
        #expect(m.contacts.map(\.number) == known.map(\.number))
        #expect(m.skippedContacts.map(\.reason) == expected.compactMap { $0 })
    }

    @Test func contactsFileProblemsKeepAccounts() throws {
        try withTempDir { dir in
            let ini = dir.appendingPathComponent("MicroSIP.ini")
            try Self.ini.write(to: ini, atomically: true, encoding: .utf8)
            let missing = try MicroSIPImport.read(ini: ini, contacts: dir.appendingPathComponent("Contacts.xml"))
            #expect(missing.accounts.count == 2 && missing.warnings.contains(.contactsFileNotFound))

            let bad = dir.appendingPathComponent("bad.xml")
            try "<contacts><contact number=\"1\"".write(to: bad, atomically: true, encoding: .utf8)
            let malformed = try MicroSIPImport.read(ini: ini, contacts: bad)
            #expect(malformed.accounts.count == 2 && malformed.contacts.isEmpty && malformed.warnings.contains(.contactsFileMalformed))

            let big = dir.appendingPathComponent("big.xml")
            try Data(count: MicroSIPImport.maxFileSize + 1).write(to: big)
            let large = try MicroSIPImport.read(ini: ini, contacts: big)
            #expect(large.accounts.count == 2 && large.warnings.contains(.contactsFileTooLarge))
        }
    }

    @Test func externalEntitiesAreRefused() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE contacts [<!ENTITY x SYSTEM "file:///etc/hosts">]>
        <contacts><contact name="&x;" number="1"/></contacts>
        """
        let p = try plan(Self.ini, contacts: xml)
        #expect(p.contacts.isEmpty && p.warnings.contains(.contactsFileMalformed))
    }

    /// The guard sees the whole file, however it is encoded and wherever the declaration is.
    @Test func doctypeIsFoundAnywhereInAnyEncoding() throws {
        let doctype = "<!DOCTYPE contacts [<!ENTITY x \"y\">]>"
        let body = "<contacts><contact name=\"A\" number=\"1\"/></contacts>"
        let longComment = "<!--" + String(repeating: "x", count: 100_000) + "-->"
        let late = "<?xml version=\"1.0\"?>" + longComment + doctype + body
        let utf16 = "<?xml version=\"1.0\" encoding=\"UTF-16\"?>" + doctype + body
        for (name, data) in [("after a long comment", Data(late.utf8)),
                             ("UTF-16 with BOM", Data([0xFF, 0xFE]) + utf16.data(using: .utf16LittleEndian)!),
                             ("UTF-16 big endian", Data([0xFE, 0xFF]) + utf16.data(using: .utf16BigEndian)!),
                             ("UTF-16 without BOM", utf16.data(using: .utf16LittleEndian)!)] {
            let p = try MicroSIPImport.plan(iniData: Data(Self.ini.utf8), contactsData: data)
            #expect(p.contacts.isEmpty && p.warnings.contains(.contactsFileMalformed), "\(name)")
        }
    }

    @Test func contactsParseInEveryEncodingWhateverTheDeclarationSays() throws {
        let xml = "<?xml version=\"1.0\" encoding=\"%@\"?>\n<contacts><contact name=\"Пётр\" number=\"1\"/></contacts>"
        for (name, data) in [("UTF-8", Data(String(format: xml, "UTF-8").utf8)),
                             ("UTF-16 BOM", Data([0xFF, 0xFE]) + String(format: xml, "UTF-16").data(using: .utf16LittleEndian)!),
                             ("windows-1251", String(format: xml, "windows-1251").data(using: .windowsCP1251)!)] {
            let p = try MicroSIPImport.plan(iniData: Data(Self.ini.utf8), contactsData: data)
            #expect(p.contacts.first?.firstName == "Пётр", "\(name)")
        }
    }

    // MARK: contacts

    static let xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <contacts>
    <contact name="Anna Maria Ivanova" number="101" phone="+7 495 111" mobile="+7 495 111" email="a@x.y" comment="Boss" info="VIP" address="Main 1" city="Minsk" state="MN" zip="220000" presence="1" directory="0"/>
    <contact name="Борис" number="sip:b@host" firstname="" lastname="" phone="102" mobile="103"/>
    <contact firstname="Carl" lastname="Gauss" number="104"/>
    <contact name="Dir" number="105" directory="1"/>
    <contact name="Nobody" number=""/>
    </contacts>
    """

    @Test func contactMapping() throws {
        let p = try plan(Self.ini, contacts: Self.xml)
        #expect(p.contacts.count == 3)
        let a = p.contacts[0]
        #expect(a.firstName == "Anna Maria" && a.lastName == "Ivanova")
        #expect(a.numbers == [PhoneNumber(label: .other, value: "101", isDefault: true),
                              PhoneNumber(label: .work, value: "+7 495 111")])   // mobile equals phone: once
        #expect(a.email == "a@x.y" && a.subscribePresence)
        #expect(a.notes == "Boss\nVIP\nMain 1, Minsk, MN 220000")
        let b = p.contacts[1]
        #expect(b.firstName == "Борис" && b.lastName == "")
        #expect(b.numbers.map(\.label) == [.sip, .work, .mobile])
        #expect(!b.subscribePresence)
        #expect(p.contacts[2].displayName == "Carl Gauss")
        #expect(p.warnings.contains(.contactsSkippedFromDirectory(count: 1)))
        #expect(p.warnings.contains(.contactsSkippedWithoutNumber(count: 1)))
    }

    // MARK: merge

    @Test func duplicatesInFileAndAgainstExisting() throws {
        let p = try plan("""
        [Account1]
        username=1
        domain=Example.COM
        [Account2]
        username=1
        domain=example.com
        [Account3]
        username=2
        domain=example.com
        """)
        let existing = [AccountConfig(displayName: "x", username: "2", domain: "EXAMPLE.com")]
        let m = MicroSIPImport.merge(p, existingAccounts: existing, existingContacts: [])
        #expect(m.accounts.map(\.config.username) == ["1"])
        #expect(m.skippedAccounts.map(\.reason) == [.duplicateInFile, .duplicateOfExisting])
    }

    @Test func defaultOutgoingOnlyWithoutAccounts() throws {
        let p = try plan(Self.ini)
        let empty = MicroSIPImport.merge(p, existingAccounts: [], existingContacts: [])
        #expect(empty.accounts.map(\.config.isDefaultOutgoing) == [false, true])      // Account2 is active
        let some = MicroSIPImport.merge(p, existingAccounts: [AccountConfig(displayName: "x", username: "x", domain: "x")],
                                        existingContacts: [])
        #expect(some.accounts.allSatisfy { !$0.config.isDefaultOutgoing })
        let noActive = try plan("[Settings]\naccountId=0\n[Account1]\nusername=1\ndomain=d\n[Account2]\nusername=2\ndomain=d\n")
        #expect(MicroSIPImport.merge(noActive, existingAccounts: [], existingContacts: []).accounts.map(\.config.isDefaultOutgoing) == [true, false])
    }

    @Test func contactDuplicatesUseNumberComparison() throws {
        let p = try plan(Self.ini, contacts: """
        <contacts><contact name="A" number="+7 (495) 123-45-67"/><contact name="B" number="+74951234567"/>
        <contact name="C" number="555"/></contacts>
        """)
        let existing = [Contact(name: "Old", number: "555")]
        let m = MicroSIPImport.merge(p, existingAccounts: [], existingContacts: existing)
        #expect(m.contacts.map(\.displayName) == ["A"])
        #expect(m.skippedContacts.map(\.reason) == [.duplicateInFile, .duplicateOfExisting])
    }

    // MARK: apply

    @Test func applyIsIdempotent() throws {
        try withTempDir { dir in
            let p = try plan(Self.ini, contacts: Self.xml)
            let accounts = AccountStore(directory: dir), contacts = ContactStore(directory: dir)
            let first = MicroSIPImport.merge(p, existingAccounts: accounts.all(), existingContacts: contacts.all())
            try MicroSIPImport.apply(first, accounts: accounts, contacts: contacts)
            #expect(accounts.all().count == 2 && contacts.all().count == 3)
            #expect(accounts.all().allSatisfy { !$0.enabled })
            #expect(accounts.defaultOutgoing()?.username == "2002")

            // A second read gives new ids but the same content.
            let again = try plan(Self.ini, contacts: Self.xml)
            let second = MicroSIPImport.merge(again, existingAccounts: accounts.all(), existingContacts: contacts.all())
            #expect(second.isEmpty)
            #expect(second.skippedAccounts.count == 2 && second.skippedContacts.count == 3)
            try MicroSIPImport.apply(second, accounts: accounts, contacts: contacts)
            #expect(accounts.all().count == 2 && contacts.all().count == 3)
        }
    }

    @Test func saveReportsWhatWasWrittenWhenContactsFail() throws {
        try withTempDir { dir in
            let accountsDir = dir.appendingPathComponent("a"), contactsDir = dir.appendingPathComponent("c")
            try FileManager.default.createDirectory(at: contactsDir, withIntermediateDirectories: true)
            let accounts = AccountStore(directory: accountsDir), contacts = ContactStore(directory: contactsDir)
            try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: contactsDir.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: contactsDir.path) }
            let m = MicroSIPImport.merge(try plan(Self.ini, contacts: Self.xml), existingAccounts: [], existingContacts: [])
            let saved = MicroSIPImport.save(m, accounts: accounts, contacts: contacts)
            #expect(saved.error != nil)
            #expect(saved.accounts.count == 2 && saved.contacts == 0)
            #expect(accounts.all().count == 2)
            #expect(accounts.defaultOutgoing()?.username == "2002")
        }
    }

    // MARK: preferences

    private func suite() -> (UserDefaults, String) {
        let name = "com.hsmm.macrosip.test.\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    @Test func recordSavedMarksOnlyAccountsThatRegister() throws {
        let (d, name) = suite()
        defer { d.removePersistentDomain(forName: name) }
        let p = try plan("[Account1]\nusername=1\nserver=a.example\ndisplayName=One\n[Account2]\nusername=2\ndomain=b.example\n")
        MicroSIPImport.recordSaved(p.accounts, in: d, order: ["old"])
        let ids = p.accounts.map { $0.config.id.raw.uuidString }
        #expect(d.stringArray(forKey: "accountsNeedingPassword") == [ids[0]])
        #expect(d.stringArray(forKey: "accountOrder") == ["old"] + ids)
        #expect(d.dictionary(forKey: "callerNames") as? [String: String] == [ids[0]: "One"])
        MicroSIPImport.recordSaved(p.accounts, in: d)                 // no duplicates, stored order kept
        #expect(d.stringArray(forKey: "accountsNeedingPassword") == [ids[0]])
        #expect(d.stringArray(forKey: "accountOrder") == ["old"] + ids)
    }

    // MARK: command

    private func env(_ home: URL, running: Bool = false, defaults: UserDefaults? = nil) -> (MicroSIPImportCommand.Environment, Lines) {
        let lines = Lines()
        return (.init(program: "test", isAppRunning: { running }, appDataDirectory: home, defaults: { defaults },
                      output: { lines.out.append($0) }, errorOutput: { lines.err.append($0) }), lines)
    }

    private final class Lines { var out: [String] = []; var err: [String] = [] }

    private func tree(_ dir: URL) -> [String: Data] {
        var out: [String: Data] = [:]
        let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)
        while let u = e?.nextObject() as? URL { out[u.path] = (try? Data(contentsOf: u)) ?? Data() }
        return out
    }

    @Test func dryRunWritesNothing() throws {
        try withTempDir { dir in
            let ini = dir.appendingPathComponent("MicroSIP.ini")
            try Self.ini.write(to: ini, atomically: true, encoding: .utf8)
            let missing = dir.appendingPathComponent("new/deep")
            let (e, lines) = env(missing)
            #expect(MicroSIPImportCommand.run(["x", "--import-microsip", ini.path, "--dry-run"], e) == 0)
            #expect(!FileManager.default.fileExists(atPath: missing.path))
            #expect(lines.out.first == "Dry run, nothing was written.")

            // An undecodable store is an error and is not renamed; a list with a damaged entry is not rewritten.
            let store = dir.appendingPathComponent("store")
            try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
            try Data("not json".utf8).write(to: store.appendingPathComponent("accounts.json"))
            let before = tree(store)
            let (e2, lines2) = env(store)
            #expect(MicroSIPImportCommand.run(["x", "--import-microsip", ini.path, "--dry-run"], e2) == 1)
            #expect(tree(store) == before)
            #expect(lines2.err.first?.contains("left as it is") == true)

            try FileManager.default.removeItem(at: store.appendingPathComponent("accounts.json"))
            try Data(#"[{"name":"A","number":"1"},{"bad":1}]"#.utf8).write(to: store.appendingPathComponent("contacts.json"))
            let before2 = tree(store)
            let (e3, _) = env(store)
            #expect(MicroSIPImportCommand.run(["x", "--import-microsip", ini.path, "--dry-run"], e3) == 0)
            #expect(tree(store) == before2)
        }
    }

    @Test func aRealRunRefusesADamagedStoreToo() throws {
        try withTempDir { dir in
            let ini = dir.appendingPathComponent("MicroSIP.ini")
            try Self.ini.write(to: ini, atomically: true, encoding: .utf8)
            let store = dir.appendingPathComponent("store")
            try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
            try Data("not json".utf8).write(to: store.appendingPathComponent("accounts.json"))
            let before = tree(store)
            let (e, _) = env(store)
            #expect(MicroSIPImportCommand.run(["x", "--import-microsip", ini.path], e) == 1)
            #expect(tree(store) == before)
        }
    }

    @Test func commandMarksAccountsInTheAppsOwnDirectory() throws {
        try withTempDir { dir in
            let ini = dir.appendingPathComponent("MicroSIP.ini")
            try Self.ini.write(to: ini, atomically: true, encoding: .utf8)
            let home = dir.appendingPathComponent("home")
            let (d, name) = suite()
            defer { d.removePersistentDomain(forName: name) }

            let (refused, lines) = env(home, running: true, defaults: d)
            #expect(MicroSIPImportCommand.run(["x", "--import-microsip", ini.path], refused) == 1)
            #expect(lines.err.first?.contains("is running") == true)
            #expect(!FileManager.default.fileExists(atPath: home.path))

            let (e, _) = env(home, defaults: d)
            #expect(MicroSIPImportCommand.run(["x", "--import-microsip", ini.path], e) == 0)
            let saved = AccountStore(directory: home).all()
            #expect(saved.count == 2)
            #expect(Set(d.stringArray(forKey: "accountsNeedingPassword") ?? []) == Set(saved.map { $0.id.raw.uuidString }))

            // Another directory: the preferences stay out of it, and it is allowed while the app runs.
            let other = dir.appendingPathComponent("other")
            let (d2, name2) = suite()
            defer { d2.removePersistentDomain(forName: name2) }
            let (e2, lines2) = env(home, running: true, defaults: d2)
            #expect(MicroSIPImportCommand.run(["x", "--import-microsip", ini.path, "--data-dir", other.path], e2) == 0)
            #expect(AccountStore(directory: other).all().count == 2)
            #expect(d2.stringArray(forKey: "accountsNeedingPassword") == nil)
            #expect(lines2.out.contains { $0.hasPrefix("Note:") })
        }
    }

    @Test func commandFailuresAndExitCodes() throws {
        withTempDir { dir in
            let (e, lines) = env(dir)
            #expect(MicroSIPImportCommand.run(["x", "--import-microsip"], e) == 2)
            #expect(lines.err.first?.hasPrefix("usage: test --import-microsip") == true)
            #expect(MicroSIPImportCommand.run(["x", "--import-microsip", "a.ini", "--bogus"], e) == 2)
            #expect(MicroSIPImportCommand.run(["x", "--import-microsip", dir.appendingPathComponent("none.ini").path], e) == 1)
        }
    }

    @Test func appDefaultsOutsideTheAppAreASuite() {
        #expect(MicroSIPImportCommand.appDefaults() !== UserDefaults.standard)
        #expect(MicroSIPImportCommand.isOtherProcess(among: [1, 2], current: 1))
        #expect(!MicroSIPImportCommand.isOtherProcess(among: [1], current: 1))
        #expect(!MicroSIPImportCommand.isOtherProcess(among: [], current: 1))
    }
}
