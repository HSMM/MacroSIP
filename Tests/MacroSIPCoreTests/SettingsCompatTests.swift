import Testing
import Foundation
@testable import MacroSIPCore

@Suite("Settings and log compatibility")
struct SettingsCompatTests {
    @Test func generalSettingsWithoutPresenceStatusDecode() throws {
        let json = #"{"launchAtLogin":true,"handleURLSchemes":true,"askBeforeCallingFromURL":true,"keepRunningInMenuBar":true,"showDockIcon":false,"doNotDisturb":true}"#
        let g = try JSONDecoder().decode(GeneralSettings.self, from: Data(json.utf8))
        #expect(g.launchAtLogin && g.doNotDisturb && !g.showDockIcon)
        #expect(g.presenceStatus == .available)
    }

    @Test func presenceStatusRoundTrips() throws {
        var s = AppSettings()
        s.general.presenceStatus = .away
        let back = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(s))
        #expect(back.general.presenceStatus == .away)
    }

    @Test func callLogEntryWithoutNoteDecodes() throws {
        let e = CallLogEntry(direction: .missed, remoteNumber: "100", accountID: AccountID(), note: "Rejected: call limit")
        let data = try JSONEncoder().encode(e)
        #expect(try JSONDecoder().decode(CallLogEntry.self, from: data).note == "Rejected: call limit")
        var obj = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        obj["note"] = nil
        let old = try JSONSerialization.data(withJSONObject: obj)
        #expect(try JSONDecoder().decode(CallLogEntry.self, from: old).note == nil)
    }
}
