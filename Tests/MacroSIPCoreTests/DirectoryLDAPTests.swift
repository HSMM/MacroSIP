import Foundation
import Network
import os
import Testing
@testable import MacroSIPCore

/// The libldap-backed LDAP source against an in-process server that speaks the subset of LDAPv3 the
/// provider uses: simple bind, search (and/or/not, equality, substrings, present), unbind; StartTLS is refused.
@Suite("LDAP directory source")
struct DirectoryLDAPTests {
    static let base = "dc=example,dc=com"
    static let reader = "cn=reader,dc=example,dc=com"

    static let entries: [FakeLDAPServer.Entry] = [
        .init(dn: base, attrs: ["objectClass": ["domain"], "dc": ["example"]]),
        .init(dn: "uid=anna,ou=people,\(base)", attrs: [
            "cn": ["Anna Ivanova"], "sn": ["Ivanova"], "telephoneNumber": ["+7 (495) 123-45-67"],
            "mobile": ["+7 916 000-11-22"], "mail": ["anna@example.com"], "o": ["Example"],
        ]),
        .init(dn: "uid=boris,ou=people,\(base)", attrs: ["cn": ["Boris Petrov"], "sn": ["Petrov"], "telephoneNumber": ["101"]]),
        .init(dn: "uid=nophone,ou=people,\(base)", attrs: ["cn": ["Anna NoPhone"], "sn": ["NoPhone"]]),
        .init(dn: "uid=star,ou=people,\(base)", attrs: ["cn": ["Star*Name"], "telephoneNumber": ["202"]]),
    ]

    func provider(_ server: FakeLDAPServer, bindDN: String = "", password: String? = nil, startTLS: Bool = false,
                  timeout: TimeInterval = 3) -> LDAPDirectoryProvider {
        let cfg = LDAPConfig(server: "ldap://127.0.0.1", port: Int(server.port), startTLS: startTLS, baseDN: Self.base, bindDN: bindDN)
        return LDAPDirectoryProvider(source: DirectorySource(kind: .ldap, name: "Company", ldap: cfg), timeout: timeout,
                                     password: { password })
    }

    @Test func searchMapsAttributes() async throws {
        let server = try await FakeLDAPServer(entries: Self.entries)
        defer { server.stop() }
        let p = provider(server)
        let found = try await p.search("anna", limit: 5)
        #expect(found.count == 1)                              // "Anna NoPhone" has no number
        let anna = try #require(found.first)
        #expect(anna.id == "uid=anna,ou=people,\(Self.base)")
        #expect(anna.displayName == "Anna Ivanova")
        #expect(anna.sourceKind == .ldap)
        #expect(anna.numbers == [PhoneNumber(label: .work, value: "+7 (495) 123-45-67", isDefault: true),
                                 PhoneNumber(label: .mobile, value: "+7 916 000-11-22")])
        #expect(anna.organization == "Example" && anna.email == "anna@example.com")
        #expect(try await p.search("1234567", limit: 5).map(\.displayName) == ["Anna Ivanova"])
        #expect(server.filters.contains("(|(cn=*anna*)(sn=*anna*)(telephoneNumber=*anna*))"))
    }

    @Test func typedTextIsEscaped() async throws {
        let server = try await FakeLDAPServer(entries: Self.entries)
        defer { server.stop() }
        #expect(try await provider(server).search("*", limit: 5).map(\.displayName) == ["Star*Name"])
        #expect(try await provider(server).search("a)(cn=", limit: 5).isEmpty)
    }

    @Test func lookupNormalisesNumbers() async throws {
        let server = try await FakeLDAPServer(entries: Self.entries)
        defer { server.stop() }
        let p = provider(server)
        #expect(try await p.lookup(number: "+74951234567")?.displayName == "Anna Ivanova")
        #expect(try await p.lookup(number: "sip:84951234567@pbx.example.com")?.displayName == "Anna Ivanova")
        #expect(try await p.lookup(number: "79160001122")?.displayName == "Anna Ivanova")
        #expect(try await p.lookup(number: "101")?.displayName == "Boris Petrov")
        #expect(try await p.lookup(number: "1101") == nil)
        #expect(try await p.lookup(number: "abc") == nil)
    }

    @Test func bindAndTest() async throws {
        let server = try await FakeLDAPServer(entries: Self.entries, users: [Self.reader: "secret"])
        defer { server.stop() }
        let ok = provider(server, bindDN: Self.reader, password: "secret")
        #expect(try await ok.test() == .connected(entries: 3))
        #expect(server.binds.contains(Self.reader))
        let bad = provider(server, bindDN: Self.reader, password: "wrong")
        await #expect(throws: DirectoryError.invalidCredentials) { try await bad.test() }
        #expect(try await ok.allEntries().count == 3)
    }

    @Test func refusedStartTLSFails() async throws {
        let server = try await FakeLDAPServer(entries: Self.entries)
        defer { server.stop() }
        await #expect(throws: DirectoryError.self) { try await provider(server, startTLS: true).search("anna", limit: 5) }
    }

    @Test func silentServerTimesOut() async throws {
        let server = try await FakeLDAPServer(entries: Self.entries, silent: true)
        defer { server.stop() }
        let start = Date()
        await #expect(throws: DirectoryError.self) { try await provider(server, timeout: 0.5).search("anna", limit: 5) }
        #expect(Date().timeIntervalSince(start) < 3)
    }

    /// Two requests may run at a time; a third that is cancelled while it waits for its turn is never sent and
    /// returns at once (the two in flight end with the deadline).
    @Test func cancelledRequestWaitingForItsTurnIsNotStarted() async throws {
        let server = try await FakeLDAPServer(entries: Self.entries, silent: true)
        defer { server.stop() }
        let p = provider(server, timeout: 2)
        let blockers = (0..<2).map { _ in Task { try await p.search("anna", limit: 5) } }
        try? await Task.sleep(for: .milliseconds(150))
        let start = Date()
        let waiting = Task { try await p.search("anna", limit: 5) }
        try? await Task.sleep(for: .milliseconds(100))
        waiting.cancel()
        let result = await waiting.result
        #expect(Date().timeIntervalSince(start) < 1)
        guard case .failure(let e as DirectoryError) = result else { Issue.record("a cancelled search did not fail with DirectoryError"); return }
        #expect(e == .cancelled)
        for b in blockers { _ = await b.result }
    }

    @Test func unreachableServer() async throws {
        let p = LDAPDirectoryProvider(source: DirectorySource(kind: .ldap, ldap: LDAPConfig(server: "ldap://127.0.0.1:1")),
                                      timeout: 1, password: { nil })
        await #expect(throws: DirectoryError.self) { try await p.test() }
    }

    @Test func endpointsAndFilters() throws {
        #expect(try LDAPClient.endpoint(server: "ldap.example.com", port: nil).uri == "ldap://ldap.example.com")
        #expect(try LDAPClient.endpoint(server: " ldap.example.com ", port: 1389).uri == "ldap://ldap.example.com:1389")
        let s = try LDAPClient.endpoint(server: "LDAPS://dc1.corp.local:3269/dc=corp", port: 636)
        #expect(s.uri == "ldaps://dc1.corp.local:3269" && s.isLDAPS)
        #expect(throws: DirectoryError.self) { try LDAPClient.endpoint(server: "http://x", port: nil) }
        #expect(throws: DirectoryError.self) { try LDAPClient.endpoint(server: "", port: nil) }
        #expect(LDAPFilter.escape("a*(b)\\c") == "a\\2a\\28b\\29\\5cc")
        #expect(LDAPFilter.substitute("cn=*%s*", query: "x") == "(cn=*x*)")
        #expect(LDAPFilter.substitute("", query: "x") == "(|(cn=*x*)(sn=*x*)(telephoneNumber=*x*))")
    }
}

// MARK: - Fake server

final class FakeLDAPServer: @unchecked Sendable {
    struct Entry: Sendable {
        var dn: String
        var attrs: [String: [String]]
        func values(_ type: String) -> [String] {
            attrs.first { $0.key.caseInsensitiveCompare(type) == .orderedSame }?.value ?? []
        }
    }

    let port: UInt16
    private let listener: NWListener
    private let queue: DispatchQueue
    private let entries: [Entry]
    private let users: [String: String]
    private let silent: Bool
    private let log = OSAllocatedUnfairLock<(filters: [String], binds: [String])>(initialState: ([], []))

    var filters: [String] { log.withLock { $0.filters } }
    var binds: [String] { log.withLock { $0.binds } }

    init(entries: [Entry], users: [String: String] = [:], silent: Bool = false) async throws {
        self.entries = entries
        self.users = users
        self.silent = silent
        let queue = DispatchQueue(label: "fake-ldap")
        self.queue = queue
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: params)
        self.listener = listener
        let once = OSAllocatedUnfairLock(initialState: false)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: if once.withLock({ let was = $0; $0 = true; return !was }) { cont.resume() }
                case .failed(let e): if once.withLock({ let was = $0; $0 = true; return !was }) { cont.resume(throwing: e) }
                default: break
                }
            }
            listener.newConnectionHandler = { _ in }
            listener.start(queue: queue)
        }
        port = listener.port?.rawValue ?? 0
        listener.newConnectionHandler = { [self] conn in accept(conn) }
    }

    func stop() { listener.cancel() }

    private func accept(_ c: NWConnection) {
        c.start(queue: queue)
        receive(c, [])
    }

    private func receive(_ c: NWConnection, _ pending: [UInt8]) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [self] data, _, done, error in
            var buf = pending + (data.map { [UInt8]($0) } ?? [])
            while let (msg, end) = BER.parse(buf, 0) {
                buf.removeFirst(end)
                if !silent { handle(msg, c) }
            }
            if done || error != nil { c.cancel(); return }
            receive(c, buf)
        }
    }

    private func send(_ c: NWConnection, _ id: BER, _ op: [UInt8]) {
        c.send(content: Data(BER.tlv(0x30, BER.tlv(0x02, id.bytes) + op)), completion: .contentProcessed { _ in })
    }

    private static func result(_ tag: UInt8, _ code: UInt8, _ text: String = "") -> [UInt8] {
        BER.tlv(tag, BER.tlv(0x0A, [code]) + BER.string("") + BER.string(text))
    }

    private func handle(_ msg: BER, _ c: NWConnection) {
        let parts = msg.children
        guard parts.count >= 2 else { return }
        let id = parts[0], op = parts[1]
        switch op.tag {
        case 0x60:                                                  // BindRequest
            let p = op.children
            let dn = p[1].text, pw = p[2].text
            log.withLock { $0.binds.append(dn) }
            let ok = dn.isEmpty || users[dn] == pw
            send(c, id, Self.result(0x61, ok ? 0 : 49, ok ? "" : "invalid credentials"))
        case 0x63:                                                  // SearchRequest
            let p = op.children
            let base = p[0].text, scope = p[1].int, sizeLimit = p[3].int, filter = p[6]
            let requested = p[7].children.map(\.text)
            log.withLock { $0.filters.append(Self.describe(filter)) }
            let inScope = entries.filter { e in
                scope == 0 ? e.dn.caseInsensitiveCompare(base) == .orderedSame
                    : (base.isEmpty || e.dn.lowercased().hasSuffix(base.lowercased()))
            }
            let hits = inScope.filter { Self.eval(filter, $0) }
            let sent = sizeLimit > 0 ? Array(hits.prefix(sizeLimit)) : hits
            for e in sent {
                let names = requested.isEmpty ? Array(e.attrs.keys) : requested.filter { $0 != "1.1" }
                var attrs: [UInt8] = []
                for n in names {
                    let v = e.values(n)
                    if !v.isEmpty { attrs += BER.tlv(0x30, BER.string(n) + BER.tlv(0x31, v.flatMap(BER.string))) }
                }
                send(c, id, BER.tlv(0x64, BER.string(e.dn) + BER.tlv(0x30, attrs)))
            }
            send(c, id, Self.result(0x65, sent.count < hits.count ? 4 : 0))
        case 0x77:                                                  // ExtendedRequest (StartTLS)
            send(c, id, Self.result(0x78, 2, "StartTLS is not supported"))
        case 0x42:                                                  // UnbindRequest
            c.cancel()
        default:
            break
        }
    }

    // MARK: Filters

    private static func normal(_ type: String, _ v: String) -> String {
        let t = type.lowercased(), s = v.lowercased()
        // telephoneNumberMatch: spaces and hyphens are insignificant.
        if t == "telephonenumber" || t == "mobile" { return s.filter { $0 != " " && $0 != "-" } }
        return s
    }

    static func eval(_ f: BER, _ e: Entry) -> Bool {
        switch f.tag {
        case 0xA0: return f.children.allSatisfy { eval($0, e) }
        case 0xA1: return f.children.contains { eval($0, e) }
        case 0xA2: return !eval(f.children[0], e)
        case 0xA3:
            let c = f.children, type = c[0].text
            return e.values(type).contains { normal(type, $0) == normal(type, c[1].text) }
        case 0xA4:
            let c = f.children, type = c[0].text
            return e.values(type).contains { v in
                var rest = Substring(normal(type, v))
                for s in c[1].children {
                    let piece = normal(type, s.text)
                    switch s.tag {
                    case 0x80: guard rest.hasPrefix(piece) else { return false }; rest = rest.dropFirst(piece.count)
                    case 0x81: guard let r = rest.range(of: piece) else { return false }; rest = rest[r.upperBound...]
                    case 0x82: guard rest.hasSuffix(piece) else { return false }; rest = ""
                    default: return false
                    }
                }
                return true
            }
        case 0x87:
            let type = f.text
            return type.lowercased() == "objectclass" || !e.values(type).isEmpty
        default:
            return false
        }
    }

    /// RFC 4515 text of a filter, for assertions.
    static func describe(_ f: BER) -> String {
        switch f.tag {
        case 0xA0: return "(&" + f.children.map(describe).joined() + ")"
        case 0xA1: return "(|" + f.children.map(describe).joined() + ")"
        case 0xA2: return "(!" + describe(f.children[0]) + ")"
        case 0xA3: return "(\(f.children[0].text)=\(f.children[1].text))"
        case 0xA4:
            let c = f.children
            var s = ""
            var last: UInt8 = 0
            for p in c[1].children {
                if p.tag != 0x80 { s += "*" }
                s += p.text
                last = p.tag
            }
            if last != 0x82 { s += "*" }
            return "(\(c[0].text)=\(s))"
        case 0x87: return "(\(f.text)=*)"
        default: return "(?)"
        }
    }
}

/// Just enough BER for LDAP: definite lengths, one-byte tags.
struct BER: Sendable {
    var tag: UInt8
    var bytes: [UInt8]

    /// The element starting at `start`, and the index after it; nil when incomplete.
    static func parse(_ b: [UInt8], _ start: Int) -> (BER, Int)? {
        guard b.count >= start + 2 else { return nil }
        var i = start + 1
        var len = Int(b[i]); i += 1
        if len & 0x80 != 0 {
            let n = len & 0x7F
            guard b.count >= i + n else { return nil }
            len = 0
            for _ in 0..<n { len = len << 8 | Int(b[i]); i += 1 }
        }
        guard b.count >= i + len else { return nil }
        return (BER(tag: b[start], bytes: Array(b[i..<(i + len)])), i + len)
    }

    var children: [BER] {
        var out: [BER] = []
        var i = 0
        while let (e, next) = BER.parse(bytes, i) { out.append(e); i = next }
        return out
    }

    var text: String { String(decoding: bytes, as: UTF8.self) }
    var int: Int { bytes.reduce(0) { $0 << 8 | Int($1) } }

    static func length(_ n: Int) -> [UInt8] {
        if n < 0x80 { return [UInt8(n)] }
        var v = n, out: [UInt8] = []
        while v > 0 { out.insert(UInt8(v & 0xFF), at: 0); v >>= 8 }
        return [0x80 | UInt8(out.count)] + out
    }

    static func tlv(_ tag: UInt8, _ content: [UInt8]) -> [UInt8] { [tag] + length(content.count) + content }
    static func string(_ s: String) -> [UInt8] { tlv(0x04, Array(s.utf8)) }
}
