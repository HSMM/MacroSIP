import Foundation
import Testing
@testable import MacroSIPCore

@Suite struct StoreTests {
    func acct(_ name: String, def: Bool = false) -> AccountConfig {
        AccountConfig(displayName: name, username: name, domain: "h", isDefaultOutgoing: def)
    }

    @Test func enabledAndRegisterFlagsRoundTripAndLegacyMigrates() throws {
        var a = acct("a")
        #expect(a.registers)
        a.registerWithServer = false
        #expect(!a.registers && a.enabled)
        a.registerWithServer = true
        a.enabled = false
        #expect(!a.registers)
        let back = try JSONDecoder().decode(AccountConfig.self, from: JSONEncoder().encode(a))
        #expect(back == a)
        // Before `registerWithServer`, enabled == false meant "outgoing only".
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(a)) as! [String: Any]
        legacy["registerWithServer"] = nil
        let old = try JSONDecoder().decode(AccountConfig.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(old.enabled && !old.registerWithServer)
    }

    @Test func defaultOutgoingInvariant() throws {
        try withTempDir { dir in
            let s = AccountStore(directory: dir)
            let a = acct("a"), b = acct("b"), c = acct("c", def: true)
            try s.upsert(a)
            #expect(s.all().filter(\.isDefaultOutgoing).map(\.id) == [a.id])  // first becomes default
            try s.upsert(b)
            try s.upsert(c)
            #expect(s.all().filter(\.isDefaultOutgoing).map(\.id) == [c.id])
            try s.setDefaultOutgoing(b.id)
            #expect(s.all().filter(\.isDefaultOutgoing).map(\.id) == [b.id])
            try s.remove(b.id)
            #expect(s.all().filter(\.isDefaultOutgoing).count == 1)
            try s.remove(a.id); try s.remove(c.id)
            #expect(s.all().isEmpty)
        }
    }

    @Test func upsertReplaces() throws {
        try withTempDir { dir in
            let s = AccountStore(directory: dir)
            var a = acct("a"); try s.upsert(a)
            a.displayName = "Renamed"; try s.upsert(a)
            #expect(s.all().count == 1 && s.all()[0].displayName == "Renamed")
        }
    }

    @Test func contactSearchAndFind() throws {
        try withTempDir { dir in
            let s = ContactStore(directory: dir)
            let alice = Contact(name: "Alice", number: "+7 495 123-45-67")
            let bob = Contact(name: "Bob", number: "sip:Bob@host")
            try s.upsert(alice); try s.upsert(bob)
            #expect(s.search("ALI").map(\.id) == [alice.id])
            #expect(s.search("74951234567").map(\.id) == [alice.id])
            #expect(s.search("(495) 123").map(\.id) == [alice.id])
            #expect(s.search("bob@host").map(\.id) == [bob.id])
            #expect(s.search("").count == 2)
            #expect(s.find(byNumber: "+74951234567")?.id == alice.id)
            #expect(s.find(byNumber: "bob")?.id == bob.id)
            #expect(s.find(byNumber: "sip:bob@other") == nil)          // both have a domain and they differ
            #expect(s.find(byNumber: "sip:BOB@host")?.id == bob.id)
            #expect(s.find(byNumber: "999") == nil)
            try s.remove(alice.id)
            #expect(s.all().count == 1)
        }
    }

    @Test func callLogTrimAndOrder() throws {
        try withTempDir { dir in
            let acc = AccountID()
            let s = CallLogStore(directory: dir, limit: { 3 })
            for i in 0..<5 {
                try s.append(CallLogEntry(direction: .outgoing, remoteNumber: "\(i)", accountID: acc,
                                          startedAt: Date(timeIntervalSince1970: Double(i))))
            }
            #expect(s.all().map(\.remoteNumber) == ["4", "3", "2"])
            let id = s.all()[0].id
            try s.remove(id)
            #expect(s.all().count == 2)
            try s.clear()
            #expect(s.all().isEmpty)
        }
    }

    @Test func callLogResolvesContact() throws {
        try withTempDir { dir in
            let contacts = ContactStore(directory: dir)
            let alice = Contact(name: "Alice", number: "+7 495 123-45-67")
            try contacts.upsert(alice)
            let s = CallLogStore(directory: dir, contacts: contacts)
            let hit = try s.append(CallLogEntry(direction: .incoming, remoteNumber: "+74951234567", accountID: AccountID()))
            let miss = try s.append(CallLogEntry(direction: .missed, remoteNumber: "555", accountID: AccountID()))
            #expect(hit.contactID == alice.id)
            #expect(miss.contactID == nil)
            #expect(s.all().first { $0.id == hit.id }?.contactID == alice.id)
        }
    }

    @Test func settingsRoundTrip() throws {
        try withTempDir { dir in
            let s = SettingsStore(directory: dir)
            #expect(s.load() == .default)
            var v = AppSettings.default
            v.audio.ringtone = .file(URL(fileURLWithPath: "/tmp/r.wav"))
            v.audio.inputDeviceName = "Mic"
            v.general.language = "ru"
            v.enabledCodecs.remove("PCMA/8000/1")
            try s.save(v)
            #expect(s.load() == v)
            #expect(AppSettings.default.callLogLimit == 1000)
            #expect(AppSettings.default.general.keepRunningInMenuBar)
        }
    }
}
