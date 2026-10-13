import Foundation
import os
import Testing
@testable import MacroSIPCore

@Suite("Directory feeds and matching")
struct DirectoryParsingTests {
    let source = UUID()

    // MARK: CSV

    @Test func csvWithRecognisedHeaders() throws {
        let csv = "\u{FEFF}" + #"""
        First Name,Last Name,Number,Mobile,E-mail,Company
        Anna,Ivanova,"+7 (495) 123-45-67",+7 916 000-11-22,anna@example.com,"Example, Inc."
        Boris,,101,,,
        ,,,,,
        "Quote ""Q""",Person,"202, 203",,,
        No,Number,,,,
        """#
        let list = try DirectoryFeedParser.parseCSV(Data(csv.utf8), sourceID: source)
        #expect(list.count == 3)
        let anna = list[0]
        #expect(anna.displayName == "Anna Ivanova")
        #expect(anna.organization == "Example, Inc.")
        #expect(anna.email == "anna@example.com")
        #expect(anna.numbers == [PhoneNumber(label: .work, value: "+7 (495) 123-45-67", isDefault: true),
                                 PhoneNumber(label: .mobile, value: "+7 916 000-11-22")])
        #expect(anna.sourceKind == .url && anna.sourceID == source)
        #expect(list[1].displayName == "Boris" && list[1].numbers.map(\.value) == ["101"])
        #expect(list[2].displayName == "Quote \"Q\" Person")
        #expect(list[2].numbers.map(\.value) == ["202", "203"])
        #expect(Set(list.map(\.id)).count == 3)
    }

    @Test func csvSemicolonsAndConfiguredColumns() throws {
        let csv = "Who;Ext;Dept\r\nSales queue;500;Sales\r\nSupport;\"600\";Help desk\r\n"
        let map = URLFieldMap(name: "who", number: "EXT", organization: "Dept")
        let list = try DirectoryFeedParser.parseCSV(Data(csv.utf8), columns: map, sourceID: source)
        #expect(list.map(\.displayName) == ["Sales queue", "Support"])
        #expect(list.map { $0.numbers[0].value } == ["500", "600"])
        #expect(list[1].organization == "Help desk")
    }

    @Test func csvWithoutNumberColumnFails() {
        #expect(throws: DirectoryError.self) {
            try DirectoryFeedParser.parseCSV(Data("name,email\nA,a@x\n".utf8), sourceID: source)
        }
    }

    @Test func csvQuotedLineBreak() throws {
        let csv = "name,number\n\"Two\nLines\",100\nNext,200"
        let list = try DirectoryFeedParser.parseCSV(Data(csv.utf8), sourceID: source)
        #expect(list.map(\.displayName) == ["Two\nLines", "Next"])
    }

    // MARK: JSON

    @Test func jsonArrayWithRecognisedKeys() throws {
        let json = #"""
        [{"id": 7, "name": "Anna Ivanova", "phone": "+7 495 1234567", "mobile": 79160001122, "email": "a@x"},
         {"first_name": "Boris", "last_name": "Petrov", "ext": "101"},
         {"name": "No number"}]
        """#
        let list = try DirectoryFeedParser.parseJSON(Data(json.utf8), sourceID: source)
        #expect(list.count == 2)
        #expect(list[0].id == "id-7")
        #expect(list[0].numbers.map(\.value) == ["+7 495 1234567", "79160001122"])
        #expect(list[0].numbers.map(\.label) == [.work, .mobile])
        #expect(list[1].displayName == "Boris Petrov")
    }

    @Test func jsonKeyPathsAndItemsPath() throws {
        let json = #"{"meta": {"n": 1}, "data": {"people": [{"person": {"display": "Carol"}, "phones": [{"v": "300"}, {"v": "301"}], "org": {"title": "Ops"}}]}}"#
        var cfg = URLConfig(format: .json)
        cfg.jsonItemsPath = "data.people"
        cfg.jsonPaths = URLFieldMap(name: "person.display", number: "phones.0.v", mobile: "phones.1.v", organization: "org.title")
        let list = try DirectoryFeedParser.parse(Data(json.utf8), config: cfg, sourceID: source)
        #expect(list.count == 1)
        #expect(list[0].displayName == "Carol")
        #expect(list[0].numbers.map(\.value) == ["300", "301"])
        #expect(list[0].organization == "Ops")
    }

    @Test func jsonObjectRootFindsTheArray() throws {
        let json = #"{"contacts": [{"name": "Dan", "number": "400"}]}"#
        let list = try DirectoryFeedParser.parseJSON(Data(json.utf8), sourceID: source)
        #expect(list.map(\.displayName) == ["Dan"])
        #expect(throws: DirectoryError.self) { try DirectoryFeedParser.parseJSON(Data("nope".utf8), sourceID: source) }
    }

    // MARK: Matching

    @Test func numberNormalisation() {
        #expect(DirectoryNumber.digits("+7 (495) 123-45-67") == "74951234567")
        #expect(DirectoryNumber.digits("sip:+74951234567@pbx.example.com") == "74951234567")
        #expect(DirectoryNumber.matches("+7 (495) 123-45-67", "84951234567"))
        #expect(DirectoryNumber.matches("+7 (495) 123-45-67", "1234567"))
        #expect(DirectoryNumber.matches("sip:101@pbx", "101"))
        #expect(!DirectoryNumber.matches("101", "1101"))
        #expect(!DirectoryNumber.matches("+7 495 123-45-67", "+7 495 123-45-68"))
        #expect(!DirectoryNumber.matches("", ""))
        #expect(!DirectoryNumber.matches("123456", "0123456"))
    }

    @Test func indexSearchAndLookup() {
        let e = { (id: String, name: String, org: String?, nums: [String]) in
            DirectoryEntry(id: id, sourceID: source, sourceKind: .url, displayName: name,
                           numbers: nums.map { PhoneNumber(value: $0) }, organization: org)
        }
        let idx = DirectoryIndex([
            e("1", "Maria Hanna", nil, ["300"]),
            e("2", "Anna Ivanova", "Example", ["+7 (495) 123-45-67"]),
            e("3", "Ann Smith", nil, ["101"]),
            e("4", "Bob", "Annex Ltd", ["102"]),
        ])
        // Names starting with the text come before matches inside a word.
        #expect(idx.search("ann", limit: 10).map(\.id) == ["2", "3", "4", "1"])
        #expect(idx.search("ann", limit: 2).map(\.id) == ["2", "3"])
        #expect(idx.search("example", limit: 5).map(\.id) == ["2"])
        #expect(idx.search("1234", limit: 5).map(\.id) == ["2"])          // digits ignore dashes
        #expect(idx.search("495) 123", limit: 5).map(\.id) == ["2"])
        #expect(idx.search("10", limit: 5).map(\.id) == ["3", "4"])
        #expect(idx.search(" ", limit: 5).isEmpty)
        #expect(idx.lookup("+74951234567")?.id == "2")
        #expect(idx.lookup("sip:101@pbx.example.com")?.id == "3")
        #expect(idx.lookup("103") == nil)
    }

    @Test func entryBecomesContact() {
        let entry = DirectoryEntry(id: "x", sourceID: source, sourceKind: .ldap, displayName: "Anna Maria Ivanova",
                                   numbers: [PhoneNumber(label: .work, value: "101"), PhoneNumber(label: .mobile, value: "+7 916")],
                                   organization: "Example", email: "a@x")
        let c = entry.makeContact(imported: true, note: "Imported from Company LDAP")
        #expect(c.firstName == "Anna Maria" && c.lastName == "Ivanova")
        #expect(c.organization == "Example" && c.email == "a@x")
        #expect(c.defaultNumber?.value == "101")
        #expect(c.notes == "Imported from Company LDAP" && c.importedFrom == source)
        #expect(entry.makeContact().importedFrom == nil)         // "Add to Contacts" makes a card of the user's own
    }
}

@Suite("URL directory source")
struct URLDirectoryProviderTests {
    final class FakeServer: Sendable {
        struct State {
            var requests: [URLRequest] = []
            var responses: [(Int, String, [String: String])] = []
        }
        let state = OSAllocatedUnfairLock<State>(uncheckedState: State())

        func enqueue(_ status: Int, _ body: String = "", headers: [String: String] = [:]) {
            state.withLockUnchecked { $0.responses.append((status, body, headers)) }
        }
        var requests: [URLRequest] { state.withLockUnchecked { $0.requests } }

        var fetch: URLDirectoryProvider.Fetch {
            { [self] request in
                let (status, body, headers) = try state.withLockUnchecked { s -> (Int, String, [String: String]) in
                    s.requests.append(request)
                    guard !s.responses.isEmpty else { throw URLError(.cannotConnectToHost) }
                    return s.responses.removeFirst()
                }
                let http = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)
                return (Data(body.utf8), http)
            }
        }
    }

    final class Clock: Sendable {
        let date = OSAllocatedUnfairLock(initialState: Date(timeIntervalSince1970: 1_000_000))
        func advance(_ s: TimeInterval) { date.withLock { $0 += s } }
        var now: @Sendable () -> Date { { [date] in date.withLock { $0 } } }
    }

    let csv = "name,number\nAnna Ivanova,+7 495 123-45-67\nBoris,101\n"

    func source(refresh: Int = 60) -> DirectorySource {
        DirectorySource(kind: .url, name: "Phone list", url: URLConfig(url: "https://example.com/phones.csv", format: .csv, refreshMinutes: refresh))
    }

    @Test func cachesAndRevalidates() async throws {
        let server = FakeServer(), clock = Clock()
        server.enqueue(200, csv, headers: ["ETag": "\"v1\"", "Last-Modified": "Mon, 12 Oct 2026 10:00:00 GMT"])
        let p = URLDirectoryProvider(source: source(), fetch: server.fetch, now: clock.now)
        #expect(try await p.search("anna", limit: 5).map(\.displayName) == ["Anna Ivanova"])
        #expect(try await p.lookup(number: "101")?.displayName == "Boris")
        #expect(server.requests.count == 1)                     // second call served from memory

        clock.advance(61 * 60)
        server.enqueue(304)
        #expect(try await p.search("bor", limit: 5).count == 1)
        #expect(server.requests.count == 2)
        let conditional = server.requests[1]
        #expect(conditional.value(forHTTPHeaderField: "If-None-Match") == "\"v1\"")
        #expect(conditional.value(forHTTPHeaderField: "If-Modified-Since") == "Mon, 12 Oct 2026 10:00:00 GMT")

        // A failed refresh keeps the old copy.
        clock.advance(61 * 60)
        #expect(try await p.search("anna", limit: 5).count == 1)
        #expect(server.requests.count == 3)
    }

    @Test func testAndErrors() async throws {
        let server = FakeServer()
        server.enqueue(500)
        let p = URLDirectoryProvider(source: source(), fetch: server.fetch)
        await #expect(throws: DirectoryError.http(500)) { try await p.search("anna", limit: 5) }
        server.enqueue(200, csv)
        #expect(try await p.test() == .connected(entries: 2))
        server.enqueue(200, csv)
        #expect(try await p.allEntries().count == 2)
        #expect(server.requests.count == 3)
    }

    @Test func rejectsOtherSchemes() async {
        let p = URLDirectoryProvider(source: DirectorySource(kind: .url, url: URLConfig(url: "ftp://x/y.csv")), fetch: FakeServer().fetch)
        await #expect(throws: DirectoryError.self) { try await p.test() }
    }
}
