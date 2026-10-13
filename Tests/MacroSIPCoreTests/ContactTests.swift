import Foundation
import Testing
import CoreGraphics
import ImageIO
@testable import MacroSIPCore

@Suite struct ContactTests {
    private func decode(_ json: String) throws -> Contact {
        try JSONDecoder().decode(Contact.self, from: Data(json.utf8))
    }

    private let id = "6F9619FF-8B86-D011-B42D-00C04FC964FF"

    // MARK: migration from 26.1

    @Test func oldNameAndNumberMigrate() throws {
        let c = try decode(#"{"id":"\#(id)","name":"Anna Maria Ivanova","number":"+7 495 123-45-67","subscribePresence":true,"createdAt":0}"#)
        #expect(c.firstName == "Anna Maria" && c.lastName == "Ivanova")
        #expect(c.numbers == [PhoneNumber(label: .other, value: "+7 495 123-45-67", isDefault: true)])
        #expect(c.subscribePresence && !c.isFavorite && c.photo == nil && c.email.isEmpty && c.notes.isEmpty)
        #expect(c.displayName == "Anna Maria Ivanova")
    }

    @Test func oneWordNameIsFirstName() throws {
        let c = try decode(#"{"id":"\#(id)","name":"Reception","number":"100","createdAt":0}"#)
        #expect(c.firstName == "Reception" && c.lastName.isEmpty)
        #expect(c.displayName == "Reception")
    }

    @Test func importedFromSurvivesARoundTripAndIsOptional() throws {
        let source = UUID()
        let c = Contact(firstName: "Anna", numbers: [PhoneNumber(value: "101", isDefault: true)], importedFrom: source)
        let data = try JSONEncoder().encode(c)
        #expect(try JSONDecoder().decode(Contact.self, from: data).importedFrom == source)
        let plain = try JSONDecoder().decode(Contact.self, from: JSONEncoder().encode(Contact(name: "B", number: "1")))
        #expect(plain.importedFrom == nil)
    }

    @Test func oldContactWithoutNumberHasNone() throws {
        let c = try decode(#"{"id":"\#(id)","name":"Nobody","number":"","createdAt":0}"#)
        #expect(c.numbers.isEmpty && c.defaultNumber == nil)
    }

    @Test func newFormatRoundTripsWithoutThePhoto() throws {
        var c = Contact(firstName: "A", lastName: "B", organization: "O",
                        numbers: [PhoneNumber(label: .work, value: "1", isDefault: true), PhoneNumber(label: .mobile, value: "2")],
                        email: "a@b.c", notes: "n", isFavorite: true, photo: Data([1, 2, 3]), subscribePresence: true)
        let data = try JSONEncoder().encode(c)
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(obj["photo"] == nil)                       // photos are files (ContactStore)
        c.photo = nil
        #expect(try JSONDecoder().decode(Contact.self, from: data) == c)
    }

    @Test func missingDefaultFallsToFirstNumber() throws {
        let c = try decode(#"{"id":"\#(id)","numbers":[{"label":"home","value":"5","isDefault":false},{"label":"work","value":"6","isDefault":false}],"createdAt":0}"#)
        #expect(c.defaultNumber?.value == "5" && c.numbers[0].isDefault)
    }

    @Test func storeReadsOldFileAndWritesNew() throws {
        try withTempDir { dir in
            let old = #"[{"id":"\#(id)","name":"Bob Smith","number":"sip:bob@host","preferredAccountID":null,"subscribePresence":false,"createdAt":"2026-01-01T00:00:00Z"}]"#
            try old.write(to: dir.appendingPathComponent("contacts.json"), atomically: true, encoding: .utf8)
            let s = ContactStore(directory: dir)
            #expect(s.all().first?.firstName == "Bob")
            try s.upsert(s.all()[0])
            let text = try String(contentsOf: dir.appendingPathComponent("contacts.json"), encoding: .utf8)
            #expect(text.contains("firstName") && text.contains("\"numbers\""))
        }
    }

    // MARK: display name

    @Test func displayName() {
        func name(_ f: String, _ l: String, _ o: String = "", _ n: [PhoneNumber] = []) -> String {
            Contact(firstName: f, lastName: l, organization: o, numbers: n).displayName
        }
        #expect(name("Alesia", "Kazlouskaya") == "Alesia Kazlouskaya")
        #expect(name("Alesia", "") == "Alesia")
        #expect(name("", "Kazlouskaya") == "Kazlouskaya")
        #expect(name("", "", "Example Ltd", [PhoneNumber(value: "102", isDefault: true)]) == "Example Ltd")
        #expect(name("", "", "", [PhoneNumber(value: "1"), PhoneNumber(value: "102", isDefault: true)]) == "102")
        #expect(name("  ", "", "", []) == "")
    }

    // MARK: numbers

    @Test func defaultAndOrder() {
        let c = Contact(numbers: [PhoneNumber(label: .work, value: "1"), PhoneNumber(label: .mobile, value: "2", isDefault: true), PhoneNumber(label: .home, value: "3")])
        #expect(c.defaultNumber?.value == "2")
        #expect(c.numbersDefaultFirst.map(\.value) == ["2", "1", "3"])
        #expect(c.normalizedNumber == "2")
    }

    @Test func numberMatchingIgnoresSpacesDashesAndBrackets() {
        let c = Contact(firstName: "A", numbers: [
            PhoneNumber(label: .work, value: "+7 (495) 123-45-67", isDefault: true),
            PhoneNumber(label: .mobile, value: "8 912 555-01-23"),
            PhoneNumber(label: .sip, value: "sip:Alesia@pbx.example.com"),
        ])
        #expect(c.allNormalizedNumbers == ["+74951234567", "89125550123", "alesia"])
        #expect(c.hasNumber("+74951234567"))
        #expect(c.hasNumber("89125550123"))
        #expect(c.hasNumber("8-912-555-01-23"))
        #expect(c.hasNumber("alesia"))
        #expect(c.hasNumber("sip:ALESIA@PBX.example.com"))
        #expect(!c.hasNumber("sip:alesia@other.host"))
        #expect(!c.hasNumber("") && !c.hasNumber("999"))
    }

    @Test func storeFindsAndSearchesThroughAnyNumber() throws {
        try withTempDir { dir in
            let s = ContactStore(directory: dir)
            let alesia = Contact(firstName: "Alesia", lastName: "Kazlouskaya", organization: "Example Ltd",
                                 numbers: [PhoneNumber(label: .work, value: "102", isDefault: true), PhoneNumber(label: .mobile, value: "+375 29 555-01-42")])
            let andrei = Contact(firstName: "Andrei", numbers: [PhoneNumber(value: "101", isDefault: true)])
            try s.upsert(alesia); try s.upsert(andrei)
            #expect(s.find(byNumber: "+375295550142")?.id == alesia.id)
            #expect(s.find(byNumber: "102")?.id == alesia.id)
            #expect(s.find(byNumber: "101")?.id == andrei.id)
            #expect(s.find(byNumber: "103") == nil)
            #expect(s.search("375 29").map(\.id) == [alesia.id])
            #expect(s.search("kazl").map(\.id) == [alesia.id])
            #expect(s.search("example").map(\.id) == [alesia.id])
            #expect(s.search("an").map(\.id) == [andrei.id])
            let log = CallLogStore(directory: dir, contacts: s)
            let hit = try log.append(CallLogEntry(direction: .incoming, remoteNumber: "+375 (29) 555-01-42", accountID: AccountID()))
            #expect(hit.contactID == alesia.id)
        }
    }

    // MARK: sort

    private func people() -> [Contact] {
        [
            Contact(firstName: "Zoya", lastName: "Abramova"),
            Contact(firstName: "Anna", lastName: "Zhuk"),
            Contact(firstName: "bob", lastName: "Morozov"),
            Contact(firstName: "", lastName: "", organization: "Help Desk"),
            Contact(firstName: "", lastName: "", numbers: [PhoneNumber(value: "+49 30 123456", isDefault: true)]),
            Contact(firstName: "Reception"),
        ]
    }

    @Test func sortByFirstName() {
        let sorted = Contact.sorted(people(), by: .firstName)
        // a bare number sorts before the letters; the list view puts its "#" section last
        #expect(sorted.map(\.displayName) == ["+49 30 123456", "Anna Zhuk", "bob Morozov", "Help Desk", "Reception", "Zoya Abramova"])
        #expect(sorted.map { $0.sectionLetter(.firstName) } == ["#", "A", "B", "H", "R", "Z"])
    }

    @Test func sortByLastName() {
        let sorted = Contact.sorted(people(), by: .lastName)
        // names are still shown "First Last"
        #expect(sorted.map(\.displayName) == ["+49 30 123456", "Zoya Abramova", "Help Desk", "bob Morozov", "Reception", "Anna Zhuk"])
        #expect(sorted.map { $0.sectionLetter(.lastName) } == ["#", "A", "H", "M", "R", "Z"])
    }

    @Test func sameKeyOrdersByTheOtherName() {
        let list = [Contact(firstName: "Anna", lastName: "Zhuk"), Contact(firstName: "Anna", lastName: "Abramova")]
        #expect(Contact.sorted(list, by: .firstName).map(\.lastName) == ["Abramova", "Zhuk"])
    }

    @Test func sortKeyFallsBack() {
        let onlyFirst = Contact(firstName: "Reception")
        #expect(onlyFirst.sortKey(.lastName) == "Reception" && onlyFirst.sectionLetter(.lastName) == "R")
        let onlyLast = Contact(lastName: "Zhuk")
        #expect(onlyLast.sortKey(.firstName) == "Zhuk")
    }

    @Test func sortSettingDefaultsAndRoundTrips() throws {
        #expect(GeneralSettings().contactSort == .firstName)
        var g = GeneralSettings(); g.contactSort = .lastName
        let back = try JSONDecoder().decode(GeneralSettings.self, from: JSONEncoder().encode(g))
        #expect(back.contactSort == .lastName)
        let old = try JSONDecoder().decode(GeneralSettings.self, from: Data("{}".utf8))
        #expect(old.contactSort == .firstName)
    }

    // MARK: photo

    @Test func photoIsCroppedToASmallSquareJPEG() throws {
        let w = 800, h = 400
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let jpeg = try #require(ContactPhoto.jpeg(from: ctx.makeImage()!))
        #expect(jpeg.starts(with: [0xFF, 0xD8]) && jpeg.count < 30_000)
        let src = try #require(CGImageSourceCreateWithData(jpeg as CFData, nil))
        let img = try #require(CGImageSourceCreateImageAtIndex(src, 0, nil))
        #expect(img.width == 256 && img.height == 256)
        #expect(ContactPhoto.jpeg(from: Data([1, 2, 3])) == nil)
    }

    // MARK: lenient decoding

    @Test func unknownLabelAndMissingDefaultDecodeLeniently() throws {
        let c = try decode(#"{"id":"\#(id)","numbers":[{"label":"satellite","value":"1"},{"value":"2","isDefault":true}],"createdAt":0}"#)
        #expect(c.numbers.map(\.label) == [.other, .other])
        #expect(c.numbers.map(\.isDefault) == [false, true])
        #expect(c.defaultNumber?.value == "2")
    }

    @Test func brokenEntriesAreSkippedAndKept() throws {
        try withTempDir { dir in
            let good = #"{"id":"\#(id)","firstName":"Ok","numbers":[{"label":"work","value":"1","isDefault":true}],"createdAt":"2026-01-01T00:00:00Z"}"#
            let broken1 = #"{"id":"not-a-uuid","firstName":"Bad"}"#
            let broken2 = #"42"#
            let text = "[\(broken1),\(good),\(broken2)]"
            try text.write(to: dir.appendingPathComponent("contacts.json"), atomically: true, encoding: .utf8)
            let s = ContactStore(directory: dir)
            #expect(s.all().map(\.firstName) == ["Ok"])
            let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            let copy = try #require(files.first { $0.hasPrefix("contacts.damaged-") })
            #expect(try String(contentsOf: dir.appendingPathComponent(copy), encoding: .utf8) == text)
            // the cleaned file is stable: a second start finds nothing to skip
            _ = ContactStore(directory: dir)
            #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix("contacts.damaged-") }.count == 1)
        }
    }

    @Test func wholeFileThatIsNotAnArrayStillGoesToTheBrokenFile() throws {
        try withTempDir { dir in
            try #"{"oops":true}"#.write(to: dir.appendingPathComponent("contacts.json"), atomically: true, encoding: .utf8)
            #expect(ContactStore(directory: dir).all().isEmpty)
        }
    }

    // MARK: downgrade safety (26.1 reads name and number)

    @Test func encodingKeepsNameAndNumberFor261() throws {
        let c = Contact(firstName: "Alesia", lastName: "Kazlouskaya",
                        numbers: [PhoneNumber(label: .mobile, value: "2"), PhoneNumber(label: .work, value: "102", isDefault: true)])
        let obj = try JSONSerialization.jsonObject(with: JSONEncoder().encode(c)) as! [String: Any]
        #expect(obj["name"] as? String == "Alesia Kazlouskaya" && obj["number"] as? String == "102")
        // 26.1's Contact had exactly these keys and decoded them as required fields
        struct Old261: Decodable { var id: UUID; var name: String; var number: String; var subscribePresence: Bool; var createdAt: Date }
        let dec = JSONDecoder()
        let old = try dec.decode(Old261.self, from: JSONEncoder().encode(c))
        #expect(old.name == "Alesia Kazlouskaya" && old.number == "102")
        // and reads its own output again
        #expect(try JSONDecoder().decode(Contact.self, from: JSONEncoder().encode(c)) == c)
    }

    // MARK: photos live outside contacts.json

    @Test func photosAreStoredAsFilesAndMigrated() throws {
        try withTempDir { dir in
            let photo = Data([0xFF, 0xD8, 1, 2, 3])
            // a pre-release file with the photo inline
            let inline = #"[{"id":"\#(id)","firstName":"P","numbers":[],"photo":"\#(photo.base64EncodedString())","createdAt":"2026-01-01T00:00:00Z"}]"#
            try inline.write(to: dir.appendingPathComponent("contacts.json"), atomically: true, encoding: .utf8)
            let s = ContactStore(directory: dir)
            #expect(s.all().first?.photo == photo)
            let json = try String(contentsOf: dir.appendingPathComponent("contacts.json"), encoding: .utf8)
            #expect(!json.contains("\"photo\""))
            #expect(try Data(contentsOf: dir.appendingPathComponent("photos/\(id).jpg")) == photo)
            // a new start reads it from the file
            #expect(ContactStore(directory: dir).all().first?.photo == photo)
            // replace and remove
            var c = s.all()[0]
            c.photo = Data([0xFF, 0xD8, 9])
            try s.upsert(c)
            #expect(ContactStore(directory: dir).all().first?.photo == c.photo)
            c.photo = nil
            try s.upsert(c)
            #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("photos/\(id).jpg").path))
            try s.upsert(c)
            try s.remove(c.id)
            #expect(s.all().isEmpty)
        }
    }

    // MARK: matching a caller to a contact

    @Test func defaultNumberMatchWinsOverASecondaryOne() {
        let a = Contact(firstName: "Anna", numbers: [PhoneNumber(label: .work, value: "500", isDefault: true), PhoneNumber(label: .mobile, value: "101")])
        let b = Contact(firstName: "Boris", numbers: [PhoneNumber(label: .work, value: "101", isDefault: true)])
        #expect(Contact.find(number: "101", in: [a, b])?.id == b.id)
        #expect(Contact.findUnique(number: "101", in: [a, b])?.id == b.id)
        #expect(Contact.candidates(for: "101", in: [a, b]).map(\.id) == [b.id, a.id])
    }

    @Test func ambiguousNumberLeavesNoUniqueContact() {
        let a = Contact(firstName: "Anna", numbers: [PhoneNumber(value: "101", isDefault: true)])
        let b = Contact(firstName: "Boris", numbers: [PhoneNumber(value: "101", isDefault: true)])
        #expect(Contact.findUnique(number: "101", in: [a, b]) == nil)
        // for showing a name the same order is used wherever: by display name
        #expect(Contact.find(number: "101", in: [b, a])?.id == a.id)
        #expect(Contact.find(number: "101", in: [a, b])?.id == a.id)
        let c = Contact(firstName: "Cyril", numbers: [PhoneNumber(label: .home, value: "7"), PhoneNumber(label: .work, value: "9", isDefault: true)])
        let d = Contact(firstName: "Dina", numbers: [PhoneNumber(label: .home, value: "7"), PhoneNumber(label: .work, value: "8", isDefault: true)])
        #expect(Contact.findUnique(number: "7", in: [c, d]) == nil)
    }

    @Test func callLogLeavesAmbiguousCallsUnlinked() throws {
        try withTempDir { dir in
            let contacts = ContactStore(directory: dir)
            let a = Contact(firstName: "Anna", numbers: [PhoneNumber(value: "101", isDefault: true)])
            let b = Contact(firstName: "Boris", numbers: [PhoneNumber(value: "101", isDefault: true)])
            let c = Contact(firstName: "Cyril", numbers: [PhoneNumber(value: "202", isDefault: true)])
            for x in [a, b, c] { try contacts.upsert(x) }
            let log = CallLogStore(directory: dir, contacts: contacts)
            #expect(try log.append(CallLogEntry(direction: .incoming, remoteNumber: "101", accountID: AccountID())).contactID == nil)
            #expect(try log.append(CallLogEntry(direction: .incoming, remoteNumber: "202", accountID: AccountID())).contactID == c.id)
        }
    }

    @Test func sipDomainCountsWhenBothSidesHaveOne() {
        let c = Contact(firstName: "Bob", numbers: [PhoneNumber(label: .sip, value: "sip:bob@pbx.example.com;transport=tls", isDefault: true)])
        #expect(c.hasNumber("bob"))                           // a caller without a domain
        #expect(c.hasNumber("sip:bob@PBX.example.com"))
        #expect(c.hasNumber("bob@pbx.example.com:5060"))
        #expect(!c.hasNumber("sip:bob@other.example.org"))
        let plain = Contact(firstName: "Bob", numbers: [PhoneNumber(value: "bob", isDefault: true)])
        #expect(plain.hasNumber("sip:bob@anywhere"))          // the contact has no domain to compare
    }

    @Test func numberNormalisationOnlyForQueriesWithoutLetters() {
        let c = Contact(firstName: "Anna", numbers: [PhoneNumber(value: "+7 (495) 123-45-67", isDefault: true)])
        #expect(c.matches(query: "495 123"))
        #expect(c.matches(query: "+74951234567"))
        #expect(!c.matches(query: "x495"))                     // letters: plain text match only
        let sip = Contact(firstName: "Bob", numbers: [PhoneNumber(label: .sip, value: "sip:Bob@host", isDefault: true)])
        #expect(sip.matches(query: "bob@host"))
        #expect(!sip.matches(query: "bob@other"))
        #expect(Contact(firstName: "Z").matches(query: "  "))
    }

    // MARK: speed

    @Test func searchingFiveHundredContactsIsFast() {
        var list: [Contact] = []
        for i in 0..<500 {
            list.append(Contact(
                firstName: "First\(i)", lastName: "Last\(i * 7)", organization: i % 5 == 0 ? "Example Ltd" : "",
                numbers: [PhoneNumber(label: .work, value: "+7 495 \(100 + i)-\(10 + i % 80)-00", isDefault: true),
                          PhoneNumber(label: .mobile, value: "8 912 555-\(1000 + i)")],
                email: "p\(i)@example.com", notes: String(repeating: "note ", count: 20)))
        }
        var best = Double.infinity
        var found = 0
        for _ in 0..<5 {
            let t0 = DispatchTime.now().uptimeNanoseconds
            found = Contact.search(list, query: "495 100").count + Contact.search(list, query: "last35").count
                + Contact.search(list, query: "example").count
            best = min(best, Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6 / 3)
        }
        #expect(found > 0)
        // Three searches of 500 cards take about 1 ms each on Apple Silicon; a shared Intel CI runner measured 11 ms.
        // The bound only has to catch a regression to per-query allocation or a quadratic pass.
        #expect(best < 50, "one search took \(best) ms")
        let t0 = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<5 { _ = Contact.find(number: "+74951234500", in: list) }
        // About 1 ms here; the Intel CI runner measured 99 ms under load, so only a gross regression fails this.
        #expect(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6 / 5 < 500)
    }
}
