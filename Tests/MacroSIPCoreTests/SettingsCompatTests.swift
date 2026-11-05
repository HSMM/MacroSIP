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

    @Test func recordingSettingsWithoutLayoutDecodeAsMono() throws {
        let old = try JSONDecoder().decode(RecordingSettings.self, from: Data(#"{"recordAllCalls":true}"#.utf8))
        #expect(old.recordAllCalls && old.layout == .mono)
        var s = AppSettings()
        #expect(s.recording.layout == .mono)
        s.recording.layout = .stereoSplit
        let back = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(s))
        #expect(back.recording.layout == .stereoSplit)
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

    @Test func audioSettingsWithoutVolumesDecodeAsDefaults() throws {
        let old = try JSONDecoder().decode(AudioSettings.self, from: Data(#"{"inputDeviceName":"USB Headset","ringtone":{"builtIn":{}}}"#.utf8))
        #expect(old.inputDeviceName == "USB Headset")
        #expect(old.ringtoneVolume == 1 && old.callSpeakerVolume == 1 && old.callMicrophoneVolume == 1 && old.followNewDevices)
        let wild = try JSONDecoder().decode(AudioSettings.self, from: Data(#"{"ringtoneVolume":7,"callSpeakerVolume":-3,"callMicrophoneVolume":1.5}"#.utf8))
        #expect(wild.ringtoneVolume == 1 && wild.callSpeakerVolume == 0 && wild.callMicrophoneVolume == 1.5)
    }

    /// Older files have one built-in ringtone (`{"builtIn":{}}`): it is Classic. The melody is stored inside
    /// `builtIn`, so older builds still read `builtIn` (and `file` keeps its old shape); an unknown melody is
    /// Classic and a broken value leaves the rest of the audio settings alone.
    @Test func ringtoneChoiceDecodesOldAndNewShapes() throws {
        func audio(_ ringtone: String) throws -> AudioSettings {
            try JSONDecoder().decode(AudioSettings.self, from: Data(#"{"inputDeviceName":"Mic","ringtone":\#(ringtone)}"#.utf8))
        }
        #expect(try audio(#"{"builtIn":{}}"#).ringtone == .builtIn(.classic))
        #expect(try audio(#"{"builtIn":{"melody":"soft"}}"#).ringtone == .builtIn(.soft))
        #expect(try audio(#"{"builtIn":{"melody":"chimes"}}"#).ringtone == .builtIn(.classic))
        #expect(try audio(#"{"file":{"_0":"file:\/\/\/tmp\/r.m4a"}}"#).ringtone == .file(URL(fileURLWithPath: "/tmp/r.m4a")))
        let broken = try audio(#"{"file":{"_0":42}}"#)
        #expect(broken.ringtone == .builtIn(.classic) && broken.inputDeviceName == "Mic")
        #expect(try audio(#""classic""#).ringtone == .builtIn(.classic))
        #expect(try JSONDecoder().decode(AudioSettings.self, from: Data("{}".utf8)).ringtone == .builtIn(.classic))
        #expect(AudioSettings().ringtone == .builtIn(.classic) && RingtoneChoice.default == .builtIn(.classic))

        for choice in [RingtoneChoice.builtIn(.digital), .builtIn(.classic), .file(URL(fileURLWithPath: "/tmp/r.aiff"))] {
            var s = AppSettings()
            s.audio.ringtone = choice
            let data = try JSONEncoder().encode(s)
            #expect(try JSONDecoder().decode(AppSettings.self, from: data).audio.ringtone == choice)
        }
        let digital = try JSONEncoder().encode(RingtoneChoice.builtIn(.digital))
        #expect(String(decoding: digital, as: UTF8.self) == #"{"builtIn":{"melody":"digital"}}"#)

        // What a build from before the melodies makes of the new shapes.
        enum OldChoice: Codable, Equatable { case builtIn, file(URL) }
        #expect(try JSONDecoder().decode(OldChoice.self, from: digital) == .builtIn)
        let file = try JSONEncoder().encode(RingtoneChoice.file(URL(fileURLWithPath: "/tmp/r.aiff")))
        #expect(try JSONDecoder().decode(OldChoice.self, from: file) == .file(URL(fileURLWithPath: "/tmp/r.aiff")))
    }

    @Test func codecOptionsDefaultsAndRoundTrip() throws {
        let old = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"callLogLimit":50}"#.utf8))
        #expect(old.codecOptions.opusFEC && !old.codecOptions.opusDTX && old.callLogLimit == 50)
        var s = AppSettings()
        s.codecOptions = CodecOptions(opusFEC: false, opusDTX: true)
        s.audio.callSpeakerVolume = 1.4
        s.audio.followNewDevices = false
        let back = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(s))
        #expect(back.codecOptions == s.codecOptions && back.audio == s.audio)
    }
}

@Suite("26.1 calls, timed DND, recordings")
struct Calls261Tests {
    @Test func oldGeneralSettingsHaveNoDNDEndAndNoFrontSwitch() throws {
        let g = try JSONDecoder().decode(GeneralSettings.self, from: Data(#"{"doNotDisturb":true}"#.utf8))
        #expect(g.doNotDisturb && g.doNotDisturbUntil == nil && !g.bringToFrontOnIncoming)
        let old = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"callLogLimit":50}"#.utf8))
        #expect(old.callOptions == CallOptions())
    }

    @Test func newSettingsRoundTrip() throws {
        var s = AppSettings()
        let end = Date(timeIntervalSince1970: 1_800_000_000)
        s.general.doNotDisturb = true
        s.general.doNotDisturbUntil = end
        s.general.bringToFrontOnIncoming = true
        let back = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(s))
        #expect(back.general == s.general && back.callOptions == s.callOptions)
    }

    @Test func callLogEntryRecordingURLIsOptional() throws {
        let url = URL(fileURLWithPath: "/tmp/2026-10-10 14.52 Alesia (in).m4a")
        let e = CallLogEntry(direction: .incoming, remoteNumber: "102", accountID: AccountID(), recordingURL: url)
        let data = try JSONEncoder().encode(e)
        #expect(try JSONDecoder().decode(CallLogEntry.self, from: data).recordingURL == url)
        var obj = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        obj["recordingURL"] = nil
        #expect(try JSONDecoder().decode(CallLogEntry.self, from: JSONSerialization.data(withJSONObject: obj)).recordingURL == nil)
    }

    @Test func recordingFileNamesParseBack() throws {
        let tz = TimeZone(identifier: "Europe/Moscow")!
        let date = Date(timeIntervalSince1970: 1_791_643_920)
        let name = RecordingFileName.make(date: date, remote: "Alesia Kazlouskaya", direction: .outgoing, timeZone: tz)
        let p = try #require(RecordingFileName.parse(name, timeZone: tz))
        #expect(p.remote == "Alesia Kazlouskaya" && p.direction == .outgoing)
        #expect(abs(p.date.timeIntervalSince(date)) < 60)
        let second = try #require(RecordingFileName.parse("2026-10-10 14.52 Bob (in) 2.m4a", timeZone: tz))
        #expect(second.remote == "Bob" && second.direction == .incoming)
        #expect(RecordingFileName.parse("notes.m4a") == nil && RecordingFileName.parse("2026-10-10 14.52 Bob.m4a") == nil)
    }

    @Test func recordingMatchesTheEntryByTimeDirectionAndName() throws {
        let tz = TimeZone.current
        let start = Date(timeIntervalSince1970: 1_791_643_800)       // on a minute boundary
        let entry = CallLogEntry(direction: .incoming, remoteNumber: "102", remoteDisplayName: "Alesia", accountID: AccountID(),
                                 startedAt: start, duration: 240)
        func file(_ offset: TimeInterval, _ remote: String, _ dir: CallDirection) -> URL {
            URL(fileURLWithPath: "/r/" + RecordingFileName.make(date: start.addingTimeInterval(offset), remote: remote, direction: dir, timeZone: tz))
        }
        let right = file(60, "Alesia", .incoming)
        let files = [file(60, "Alesia", .outgoing), file(600, "Alesia", .incoming), file(30, "Someone", .incoming), right]
        #expect(RecordingFileName.Index(files: files, timeZone: tz).match(entry, name: "Alesia") == right)
        #expect(RecordingFileName.Index(files: [files[0], files[1]], timeZone: tz).match(entry, name: "Alesia") == nil)
        // A file of another party in the same minute is never taken, however close.
        #expect(RecordingFileName.Index(files: [files[2]], timeZone: tz).match(entry, name: "Alesia") == nil)
        // Two entries, two files, one of them contested: each file goes to one entry, the closest pair first.
        let second = CallLogEntry(direction: .incoming, remoteNumber: "102", remoteDisplayName: "Alesia", accountID: AccountID(),
                                  startedAt: start.addingTimeInterval(60), duration: 120)
        let early = file(0, "Alesia", .incoming)
        let both = RecordingFileName.Index(files: [early, right], timeZone: tz)
            .assign([(entry, "Alesia"), (second, "Alesia")])
        #expect(both[entry.id] == early && both[second.id] == right)
        let missed = CallLogEntry(direction: .missed, remoteNumber: "102", accountID: AccountID(), startedAt: start)
        #expect(RecordingFileName.Index(files: [file(0, "Alesia", .incoming)], timeZone: tz).match(missed, name: "Alesia") != nil)
    }

    @Test func callLogStoreSetsTheRecording() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("macrosip-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = CallLogStore(directory: dir)
        let e = try store.append(CallLogEntry(direction: .outgoing, remoteNumber: "1", accountID: AccountID()))
        let url = URL(fileURLWithPath: "/tmp/x.m4a")
        try store.setRecording(url, for: e.id)
        #expect(store.all().first?.recordingURL == url)
        try store.setRecording(nil, for: e.id)
        #expect(store.all().first?.recordingURL == nil)
    }
}

@Suite("Text messages are opt-in (#8)")
struct MessagesSwitchTests {
    @Test func offByDefaultAndForOldFiles() throws {
        #expect(!AppSettings().general.messagesEnabled)
        #expect(!GeneralSettings().messagesEnabled)
        let old = try JSONDecoder().decode(GeneralSettings.self, from: Data(#"{"doNotDisturb":true}"#.utf8))
        #expect(old.doNotDisturb && !old.messagesEnabled)
        let file = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"callLogLimit":50}"#.utf8))
        #expect(!file.general.messagesEnabled)
        let wrongType = try JSONDecoder().decode(GeneralSettings.self, from: Data(#"{"messagesEnabled":"yes"}"#.utf8))
        #expect(!wrongType.messagesEnabled)
    }

    @Test func switchRoundTrips() throws {
        var s = AppSettings()
        s.general.messagesEnabled = true
        let back = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(s))
        #expect(back.general.messagesEnabled && back == s)
    }
}
