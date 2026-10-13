import Testing
import Foundation
@testable import MacroSIPCore

@Suite("Quick keys")
struct QuickKeyTests {
    private func tempDir() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("qk-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    @Test func defaultsAndOldSettingsFiles() throws {
        let s = AppSettings()
        #expect(s.quickKeys.show == .off && s.quickKeys.pickupCode == "*8" && s.quickKeys.keys.isEmpty)
        let old = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"callLogLimit":50}"#.utf8))
        #expect(old.quickKeys == QuickKeysSettings())
        let bad = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"quickKeys":{"show":"sideways","keys":[{"name":"A","type":"nope"}]}}"#.utf8))
        #expect(bad.quickKeys.show == .off && bad.quickKeys.keys.first?.type == .call && bad.quickKeys.keys.first?.name == "A")
    }

    @Test func settingsRoundTrip() throws {
        var s = AppSettings()
        s.quickKeys = QuickKeysSettings(show: .bottom, pickupCode: "**", keys: [
            QuickKey(name: "Reception", number: "100", type: .smartBlindTransfer, blf: true),
            QuickKey(name: "Pickup", number: "*8", type: .dtmf),
        ])
        let back = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(s))
        #expect(back.quickKeys == s.quickKeys)
        #expect(back.quickKeys.keys[0].type == .smartBlindTransfer)
    }

    @Test func listIsCappedAtTwelve() throws {
        var s = QuickKeysSettings()
        for i in 0..<12 {
            let added = s.add(QuickKey(name: "K\(i)", number: "\(i)"))
            #expect(added)
        }
        let overflow = s.add(QuickKey(name: "K12", number: "12"))
        #expect(!overflow)
        #expect(s.keys.count == 12)
        let many = (0..<20).map { QuickKey(name: "K\($0)", number: "\($0)") }
        #expect(QuickKeysSettings(keys: many).keys.count == 12)
        let json = try JSONEncoder().encode(QuickKeysSettings(keys: many))
        var obj = try #require(JSONSerialization.jsonObject(with: json) as? [String: Any])
        obj["keys"] = many.map { ["name": $0.name, "number": $0.number] }
        let decoded = try JSONDecoder().decode(QuickKeysSettings.self, from: JSONSerialization.data(withJSONObject: obj))
        #expect(decoded.keys.count == 12)
    }

    @Test func moveRemoveNormalize() {
        var s = QuickKeysSettings(keys: ["a", "b", "c", "d"].map { QuickKey(name: $0, number: $0) })
        s.move(from: 0, to: 2)
        #expect(s.keys.map(\.name) == ["b", "c", "a", "d"])
        s.move(from: 3, to: 0)
        #expect(s.keys.map(\.name) == ["d", "b", "c", "a"])
        s.move(from: 9, to: 0)
        #expect(s.keys.count == 4)
        s.remove(s.keys[1].id)
        #expect(s.keys.map(\.name) == ["d", "c", "a"])
        s.keys.append(QuickKey(name: "  ", number: " "))
        s.keys[0].number = ""
        s.keys[0].blf = true
        s.normalize()
        #expect(s.keys.map(\.name) == ["d", "c", "a"] && !s.keys[0].blf)
    }

    @Test func shortcutsFollowListOrder() {
        #expect(QuickKeysSettings.shortcutDigit(at: 0) == 1)
        #expect(QuickKeysSettings.shortcutDigit(at: 8) == 9)
        #expect(QuickKeysSettings.shortcutDigit(at: 9) == nil)
        #expect(QuickKeysSettings.shortcutDigit(at: 11) == nil)
    }

    private func account(_ domain: String = "pbx.example.com", transport: TransportKind = .udp) -> AccountConfig {
        AccountConfig(displayName: "Office", username: "1001", domain: domain, transport: transport)
    }

    @Test func pickupURI() {
        var s = QuickKeysSettings()
        let udp = account()
        #expect(s.pickupURI(for: QuickKey(name: "A", number: "101"), account: udp)?.uri == "sip:*8101@pbx.example.com")
        #expect(s.pickupURI(for: QuickKey(name: "A", number: "101"), account: udp)?.display == "*8101")
        #expect(s.pickupURI(for: QuickKey(name: "A", number: "sip:alice@pbx"), account: udp)?.uri == "sip:*8alice@pbx")
        #expect(s.pickupURI(for: QuickKey(name: "A", number: "sip:alice@pbx;transport=tcp"), account: udp)?.uri == "sip:*8alice@pbx;transport=tcp")
        #expect(s.pickupURI(for: QuickKey(name: "A", number: "101"), account: account(transport: .tls))?.uri == "sip:*8101@pbx.example.com;transport=tls")
        #expect(s.pickupURI(for: QuickKey(name: "A", number: "+7 (912) 555-01-23"), account: udp)?.uri == "sip:*8+79125550123@pbx.example.com")
        #expect(s.pickupURI(for: QuickKey(name: "Group", number: ""), account: udp)?.uri == "sip:*8@pbx.example.com")
        s.pickupCode = "**#"
        #expect(s.pickupURI(for: QuickKey(number: "101"), account: udp)?.uri == "sip:**%23101@pbx.example.com")
        s.pickupCode = "x*8 "          // only digits, * and # are dialled
        #expect(s.pickupURI(for: QuickKey(number: "101"), account: udp)?.uri == "sip:*8101@pbx.example.com")
        s.pickupCode = ""
        #expect(s.pickupURI(for: QuickKey(), account: udp) == nil)
        #expect(QuickKeysSettings.isValidPickupCode("*8") && QuickKeysSettings.isValidPickupCode("#12*"))
        #expect(!QuickKeysSettings.isValidPickupCode("") && !QuickKeysSettings.isValidPickupCode("*8a") && !QuickKeysSettings.isValidPickupCode("*8 "))
    }

    @Test func oneBrokenKeyDoesNotCostTheOthers() throws {
        let json = #"{"show":"right","keys":[{"name":"Good","number":"100"},{"id":"not-a-uuid","name":"Bad"},{"name":"Also good","number":"101","type":"dtmf"},5]}"#
        let s = try JSONDecoder().decode(QuickKeysSettings.self, from: Data(json.utf8))
        #expect(s.show == .right && s.keys.map(\.name) == ["Good", "Also good"] && s.keys[1].type == .dtmf)
        let app = try JSONDecoder().decode(AppSettings.self, from: Data(("{\"quickKeys\":" + json + "}").utf8))
        #expect(app.quickKeys.keys.count == 2)
    }

    @Test func presenceRegistryShares() {
        var r = PresenceRegistry()
        var c = r.setWatches(owner: "contacts", uris: ["sip:101@pbx.example.com;transport=tls", "sip:102@pbx.example.com"])
        #expect(c.subscribe.map(\.key) == ["101@pbx.example.com", "102@pbx.example.com"] && c.unsubscribe.isEmpty)
        // another spelling of 101 shares the subscription, 103 is new
        c = r.setWatches(owner: "keys", uris: ["101@PBX.example.com", " <sip:103@pbx.example.com> "])
        #expect(c.subscribe.map(\.key) == ["103@pbx.example.com"] && c.unsubscribe.isEmpty)
        #expect(r.owners(of: "sip:101@pbx.example.com") == ["contacts", "keys"] && r.count == 3)
        // asking again changes nothing (no re-subscribe)
        let again = r.setWatches(owner: "keys", uris: ["101@pbx.example.com", "sip:103@pbx.example.com"])
        #expect(again.isEmpty)
        // contacts drop 101: the keys still hold it; 102 goes
        c = r.setWatches(owner: "contacts", uris: [])
        #expect(c.subscribe.isEmpty && c.unsubscribe.map(\.key) == ["102@pbx.example.com"])
        #expect(r.isWatched("sip:101@pbx.example.com"))
        // the keys drop everything: 101 is unsubscribed with the spelling it was subscribed with
        c = r.setWatches(owner: "keys", uris: [])
        #expect(c.unsubscribe.map(\.key) == ["101@pbx.example.com", "103@pbx.example.com"])
        #expect(c.unsubscribe.first?.uri == "sip:101@pbx.example.com;transport=tls")
        #expect(r.count == 0)
    }

    @Test func presenceRegistryLogsAFailureOnce() {
        var r = PresenceRegistry()
        _ = r.setWatches(owner: "a", uris: ["sip:1@h"])
        let first = r.reportFailure(key: "1@h")
        let second = r.reportFailure(key: "1@h")
        let unknown = r.reportFailure(key: "unknown@h")
        #expect(first && !second && !unknown)
        r.reset()
        #expect(r.count == 0)
        _ = r.setWatches(owner: "a", uris: ["sip:1@h"])
        let afterReset = r.reportFailure(key: "1@h")
        #expect(afterReset)
    }

    @Test func typeBehaviour() {
        for t in QuickKeyType.allCases {
            if t.needsCall { #expect(t.idleAction == nil) } else { #expect(t.idleAction == .call) }
        }
        #expect(QuickKeyType.call.inCallAction == .call)
        #expect(QuickKeyType.dtmf.inCallAction == .sendDigits)
        #expect(QuickKeyType.smartBlindTransfer.inCallAction == .blindTransfer)
        #expect(QuickKeyType.smartAttendedTransfer.inCallAction == .attendedTransfer)
        #expect(QuickKeyType.smartConference.inCallAction == .conference)
        #expect(QuickKeyType.smartConference.isSmart && !QuickKeyType.conference.isSmart)
        #expect(QuickKeyType.allCases.count == 8)
    }

    @Test func dtmfDigits() {
        #expect(QuickKey(number: "*8 1-0 (1)#").dtmfDigits == "*81 01#".replacingOccurrences(of: " ", with: ""))
        #expect(QuickKey(number: "12ab").dtmfDigits == "12AB")
    }

    @Test func lineState() {
        #expect(QuickKeyLineState(presence: .available) == .available)
        #expect(QuickKeyLineState(presence: .away) == .available)
        #expect(QuickKeyLineState(presence: .dnd) == .busy)
        #expect(QuickKeyLineState(presence: .offline) == .unknown)
        #expect(QuickKeyLineState(presence: nil) == .unknown)
        #expect(QuickKeyLineState(presence: .available, ringing: true) == .ringing)
        #expect(QuickKeyLineState(presence: .dnd, ringing: true) == .ringing)
        #expect(QuickKeyLineState(presence: .offline, ringing: true) == .unknown)
        #expect(QuickKeyLineState(presence: .available, ringing: true, networkOnline: false) == .unknown)
    }

    @Test func storeNormalisesAndPersists() throws {
        let dir = tempDir()
        let store = QuickKeyStore(directory: dir)
        #expect(store.keys().isEmpty)
        let a = QuickKey(name: "A", number: "1", blf: true)
        let b = QuickKey(name: "B", number: "2")
        try store.upsert(a)
        try store.upsert(b)
        try store.upsert(QuickKey(name: "", number: " "))
        #expect(store.keys().map(\.name) == ["A", "B"])
        var a2 = a; a2.type = .dtmf
        try store.upsert(a2)
        try store.move(from: 1, to: 0)
        #expect(QuickKeyStore(directory: dir).keys().map(\.name) == ["B", "A"])
        #expect(store.keys()[1].type == .dtmf)
        try store.remove(b.id)
        #expect(store.keys().map(\.name) == ["A"])
        for i in 0..<20 { try store.upsert(QuickKey(name: "K\(i)", number: "\(i)")) }
        #expect(store.keys().count == 12)
    }
}
