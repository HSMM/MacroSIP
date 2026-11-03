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
        #expect(try interval("1") == 10)
        #expect(try interval("10") == 10)
        #expect(try interval("11") == 11)
        #expect(try interval("abc") == 300)
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
}
