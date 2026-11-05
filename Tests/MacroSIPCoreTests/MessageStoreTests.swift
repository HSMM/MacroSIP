import Foundation
import Testing
@testable import MacroSIPCore

@Suite struct MessageStoreTests {
    let acct = AccountID()
    let t0 = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 + 86400).rounded())  // after any conversation created during the test

    func note(_ conv: UUID, _ dir: MessageDirection = .incoming, text: String = "hi", at: Date, state: MessageState = .sent) -> Message {
        Message(conversationID: conv, direction: dir, text: text, at: at, state: state)
    }

    @Test func conversationKeyedByNormalizedNumberAndAccount() throws {
        try withTempDir { dir in
            let s = MessageStore(directory: dir)
            let a = try s.conversation(account: acct, remoteNumber: "+375 29 123-45-67", remoteURI: "sip:a@h", displayName: nil)
            let b = try s.conversation(account: acct, remoteNumber: "+375291234567", remoteURI: "", displayName: nil)
            #expect(a.id == b.id && s.conversations().count == 1)
            _ = try s.conversation(account: AccountID(), remoteNumber: "+375291234567", remoteURI: "", displayName: nil)
            #expect(s.conversations().count == 2)
        }
    }

    @Test func uriAndNameUpdateOnlyWhenNonEmpty() throws {
        try withTempDir { dir in
            let s = MessageStore(directory: dir)
            _ = try s.conversation(account: acct, remoteNumber: "102", remoteURI: "sip:102@h", displayName: "Bob")
            let c = try s.conversation(account: acct, remoteNumber: "102", remoteURI: "", displayName: nil)
            #expect(c.remoteURI == "sip:102@h" && c.remoteDisplayName == "Bob")
            let d = try s.conversation(account: acct, remoteNumber: "102", remoteURI: "sip:102@h2", displayName: "Robert")
            #expect(d.remoteURI == "sip:102@h2" && d.remoteDisplayName == "Robert")
            #expect(s.conversations()[0] == d)
        }
    }

    @Test func contactResolvedThroughContactStore() throws {
        try withTempDir { dir in
            let contacts = ContactStore(directory: dir)
            let alice = Contact(name: "Alice", number: "+7 495 123-45-67")
            try contacts.upsert(alice)
            let s = MessageStore(directory: dir, contacts: contacts)
            let c = try s.conversation(account: acct, remoteNumber: "+74951234567", remoteURI: "", displayName: nil)
            #expect(c.contactID == alice.id)
            let other = try s.conversation(account: acct, remoteNumber: "999", remoteURI: "", displayName: nil)
            #expect(other.contactID == nil)
        }
    }

    @Test func appendBumpsActivityAndUnread() throws {
        try withTempDir { dir in
            let s = MessageStore(directory: dir)
            let c = try s.conversation(account: acct, remoteNumber: "1", remoteURI: "", displayName: nil)
            let later = t0.addingTimeInterval(1000)
            try s.append(note(c.id, at: later))
            try s.append(note(c.id, at: later.addingTimeInterval(5)))
            try s.append(note(c.id, .outgoing, at: later.addingTimeInterval(-100)))  // earlier: activity unchanged
            let stored = s.conversations()[0]
            #expect(stored.unread == 2 && s.unreadTotal == 2)
            #expect(stored.lastActivityAt == later.addingTimeInterval(5))
        }
    }

    @Test func markReadZeroesUnread() throws {
        try withTempDir { dir in
            let s = MessageStore(directory: dir)
            let a = try s.conversation(account: acct, remoteNumber: "1", remoteURI: "", displayName: nil)
            let b = try s.conversation(account: acct, remoteNumber: "2", remoteURI: "", displayName: nil)
            try s.append(note(a.id, at: t0)); try s.append(note(b.id, at: t0))
            #expect(s.unreadTotal == 2)
            try s.markRead(a.id)
            #expect(s.unreadTotal == 1)
            #expect(s.conversations().first { $0.id == a.id }?.unread == 0)
        }
    }

    @Test func orderingOfConversationsAndMessages() throws {
        try withTempDir { dir in
            let s = MessageStore(directory: dir)
            let a = try s.conversation(account: acct, remoteNumber: "1", remoteURI: "", displayName: nil)
            let b = try s.conversation(account: acct, remoteNumber: "2", remoteURI: "", displayName: nil)
            let m3 = note(a.id, text: "3", at: t0.addingTimeInterval(30))
            let m1 = note(a.id, text: "1", at: t0.addingTimeInterval(10))
            let m2a = note(a.id, text: "2a", at: t0.addingTimeInterval(20))
            let m2b = note(a.id, text: "2b", at: t0.addingTimeInterval(20))
            for m in [m3, m1, m2a, m2b] { try s.append(m) }
            try s.append(note(b.id, at: t0.addingTimeInterval(40)))
            #expect(s.messages(in: a.id).map(\.text) == ["1", "2a", "2b", "3"])
            #expect(s.conversations().map(\.id) == [b.id, a.id])
            #expect(s.allMessages().count == 5)
            #expect(s.messages(in: b.id).count == 1)
        }
    }

    @Test func limitDropsOldestAndPrunesEmptyConversations() throws {
        try withTempDir { dir in
            let s = MessageStore(directory: dir, limit: { 3 })
            let a = try s.conversation(account: acct, remoteNumber: "1", remoteURI: "", displayName: nil)
            let b = try s.conversation(account: acct, remoteNumber: "2", remoteURI: "", displayName: nil)
            try s.append(note(a.id, text: "a1", at: t0))
            try s.append(note(b.id, text: "b1", at: t0.addingTimeInterval(1)))
            try s.append(note(b.id, text: "b2", at: t0.addingTimeInterval(2)))
            try s.append(note(b.id, text: "b3", at: t0.addingTimeInterval(3)))
            #expect(s.allMessages().map(\.text) == ["b1", "b2", "b3"])
            #expect(s.conversations().map(\.id) == [b.id])
        }
    }

    @Test func updateChangesState() throws {
        try withTempDir { dir in
            let s = MessageStore(directory: dir)
            let c = try s.conversation(account: acct, remoteNumber: "1", remoteURI: "", displayName: nil)
            let m = try s.append(note(c.id, .outgoing, at: t0, state: .sending))
            try s.update(m.id) { $0.state = .failed; $0.failureCode = 404; $0.failureReason = "Not Found" }
            var got = s.messages(in: c.id)[0]
            #expect(got.state == .failed && got.failureCode == 404 && got.failureReason == "Not Found")
            try s.update(m.id) { $0.state = .sent; $0.failureCode = nil; $0.failureReason = nil }
            got = s.messages(in: c.id)[0]
            #expect(got.state == .sent && got.failureCode == nil)
            try s.update(UUID()) { $0.text = "x" }  // unknown id is ignored
        }
    }

    @Test func failInterruptedSends() throws {
        try withTempDir { dir in
            let s = MessageStore(directory: dir)
            let c = try s.conversation(account: acct, remoteNumber: "1", remoteURI: "", displayName: nil)
            let pending = try s.append(note(c.id, .outgoing, at: t0, state: .sending))
            let done = try s.append(note(c.id, .outgoing, at: t0.addingTimeInterval(1), state: .sent))
            try s.failInterruptedSends()
            let all = s.messages(in: c.id)
            #expect(all.first { $0.id == pending.id }.map { ($0.state, $0.failureCode, $0.failureReason) }! == (.failed, 0, "interrupted"))
            #expect(all.first { $0.id == done.id }?.state == .sent)
        }
    }

    @Test func removeMessageConversationAndClear() throws {
        try withTempDir { dir in
            let s = MessageStore(directory: dir)
            let a = try s.conversation(account: acct, remoteNumber: "1", remoteURI: "", displayName: nil)
            let b = try s.conversation(account: acct, remoteNumber: "2", remoteURI: "", displayName: nil)
            let m = try s.append(note(a.id, at: t0))
            try s.append(note(a.id, at: t0.addingTimeInterval(1)))
            try s.append(note(b.id, at: t0))
            try s.remove(message: m.id)
            #expect(s.messages(in: a.id).count == 1)
            try s.remove(conversation: a.id)
            #expect(s.conversations().map(\.id) == [b.id] && s.allMessages().count == 1)
            try s.clear()
            #expect(s.conversations().isEmpty && s.allMessages().isEmpty && s.unreadTotal == 0)
        }
    }

    @Test func persistsAcrossInstancesAndCyrillicRoundTrips() throws {
        try withTempDir { dir in
            let first = MessageStore(directory: dir)
            let c = try first.conversation(account: acct, remoteNumber: "102", remoteURI: "sip:102@h", displayName: "Иван")
            let m = try first.append(note(c.id, text: "Привет, мир", at: t0))
            let second = MessageStore(directory: dir)
            #expect(second.conversations() == [first.conversations()[0]])
            #expect(second.messages(in: c.id) == [m])
            #expect(second.unreadTotal == 1)
        }
    }

    @Test func decodesOlderFileWithoutOptionalFields() throws {
        try withTempDir { dir in
            let acctID = UUID(), conv = UUID(), mid = UUID()
            let json = """
            {"conversations":[{"id":"\(conv)","accountID":{"raw":"\(acctID)"},"remoteNumber":"102",
              "remoteURI":"sip:102@h","lastActivityAt":"2023-11-14T22:13:20Z","futureField":42}],
             "messages":[{"id":"\(mid)","conversationID":"\(conv)","direction":"incoming","text":"hey",
              "at":"2023-11-14T22:13:20Z","state":"sent","extra":true}]}
            """
            try Data(json.utf8).write(to: dir.appendingPathComponent("messages.json"))
            let s = MessageStore(directory: dir)
            let c = try #require(s.conversations().first)
            #expect(c.unread == 0 && c.remoteDisplayName == nil && c.contactID == nil && c.accountID.raw == acctID)
            let m = try #require(s.messages(in: conv).first)
            #expect(m.text == "hey" && m.failureCode == nil && m.failureReason == nil)
        }
    }

    @Test func damagedFileLeavesDefaultAndIsMovedAside() throws {
        try withTempDir { dir in
            try Data("{ not json".utf8).write(to: dir.appendingPathComponent("messages.json"))
            let s = MessageStore(directory: dir)
            #expect(s.conversations().isEmpty && s.allMessages().isEmpty)
            let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            #expect(files.contains { $0.hasPrefix("messages.broken-") })
            let c = try s.conversation(account: acct, remoteNumber: "1", remoteURI: "", displayName: nil)
            #expect(s.conversations().map(\.id) == [c.id])
        }
    }
}
