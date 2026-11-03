import Testing
import Foundation
@testable import MacroSIPCore

@Suite("Global hotkeys")
struct HotkeyTests {
    private func call(_ n: Int32) -> CallID { CallID(raw: n, serial: UInt64(n)) }

    @Test func oldSettingsDecodeAsOff() throws {
        let s = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"callLogLimit":50}"#.utf8))
        #expect(s.hotkeys == HotkeySettings())
        #expect(!s.hotkeys.enabled && s.hotkeys.active.isEmpty)
        let h = try JSONDecoder().decode(HotkeySettings.self, from: Data(#"{"enabled":true}"#.utf8))
        #expect(h.enabled && h.answer == nil && !h.prefilled)
    }

    @Test func settingsRoundTrip() throws {
        var s = AppSettings()
        s.hotkeys.setEnabled(true)
        s.hotkeys.mute = nil
        let back = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(s))
        #expect(back.hotkeys == s.hotkeys)
        #expect(back.hotkeys.answer == .defaultAnswer && back.hotkeys.mute == nil)
    }

    @Test func garbageInOneFieldKeepsTheRest() throws {
        let json = #"{"enabled":true,"answer":"x","hangUp":{"keyCode":4,"modifiers":6},"prefilled":true}"#
        let h = try JSONDecoder().decode(HotkeySettings.self, from: Data(json.utf8))
        #expect(h.enabled && h.answer == nil && h.hangUp == .defaultHangUp)
    }

    @Test func firstTimeOnPrefillsAndLaterDoesNot() {
        var h = HotkeySettings()
        h.setEnabled(true)
        #expect(h.answer?.display == "⌃⌥A" && h.hangUp?.display == "⌃⌥H" && h.mute?.display == "⌃⌥M")
        h.assign(nil, to: .hangUp)
        h.setEnabled(false)
        h.setEnabled(true)
        #expect(h.hangUp == nil)
        #expect(h.answer == .defaultAnswer)
    }

    @Test func displayOrderAndNames() {
        #expect(HotkeyCombo(keyCode: 0, modifiers: [.command, .shift, .option, .control]).display == "⌃⌥⇧⌘A")
        #expect(HotkeyCombo(keyCode: 122, modifiers: .command).display == "⌘F1")
        #expect(HotkeyCombo(keyCode: 49, modifiers: .control).display == "⌃Space")
        #expect(HotkeyCombo(keyCode: 126, modifiers: [.control, .option]).display == "⌃⌥↑")
    }

    @Test func needsCommandControlOrOption() {
        #expect(HotkeyCombo(keyCode: 0, modifiers: []).issue == .needsModifier)
        #expect(HotkeyCombo(keyCode: 0, modifiers: .shift).issue == .needsModifier)
        #expect(HotkeyCombo(keyCode: 0, modifiers: [.shift, .option]).issue == nil)
        #expect(HotkeyCombo(keyCode: 11, modifiers: .command).issue == nil)
        #expect(HotkeyCombo(keyCode: 200, modifiers: .command).issue == .unsupportedKey)
    }

    @Test func menuShortcutsAreRefused() {
        #expect(HotkeyCombo(keyCode: 2, modifiers: .command).issue == .usedByMenu)               // ⌘D
        #expect(HotkeyCombo(keyCode: 46, modifiers: [.command, .shift]).issue == .usedByMenu)    // ⇧⌘M
        #expect(HotkeyCombo(keyCode: 18, modifiers: .command).issue == .usedByMenu)              // ⌘1
        #expect(HotkeyCombo(keyCode: 2, modifiers: [.command, .option]).issue == .usedByMenu)    // ⌥⌘D
        #expect(HotkeyCombo(keyCode: 2, modifiers: [.command, .option, .shift]).issue == nil)
    }

    @Test func sameCombinationOnTwoActionsIsRefused() {
        var h = HotkeySettings()
        h.setEnabled(true)
        let before = h
        #expect(h.assign(.defaultAnswer, to: .mute) == .duplicate(of: .answer))
        #expect(h == before)
        #expect(h.assign(.defaultMute, to: .mute) == nil)              // its own combination again is fine
        #expect(h.assign(HotkeyCombo(keyCode: 0, modifiers: []), to: .mute) == .needsModifier)
        #expect(h.assign(nil, to: .answer) == nil && h.answer == nil)
        #expect(h.assign(.defaultAnswer, to: .hangUp) == nil && h.hangUp == .defaultAnswer)   // free now that Answer is cleared
    }

    @Test func activeSkipsOffAndInvalid() {
        var h = HotkeySettings(enabled: false, answer: .defaultAnswer)
        #expect(h.active.isEmpty)
        h.enabled = true
        h.hangUp = HotkeyCombo(keyCode: 4, modifiers: .shift)       // hand-edited
        h.mute = .defaultAnswer                                     // repeated
        #expect(h.active == [.answer: .defaultAnswer])
    }

    @Test func answerTakesTheOldestRingingCall() {
        let s = HotkeyCallState(ringing: [call(1), call(2)], current: call(9))
        #expect(HotkeyEffect.resolve(.answer, s) == .answer(call(1)))
        #expect(HotkeyEffect.resolve(.answer, HotkeyCallState(ringing: [], current: call(9))) == .none)
    }

    @Test func hangUpEndsCurrentThenDeclinesRinging() {
        #expect(HotkeyEffect.resolve(.hangUp, HotkeyCallState(ringing: [call(2)], current: call(9))) == .hangUp(call(9)))
        #expect(HotkeyEffect.resolve(.hangUp, HotkeyCallState(ringing: [call(2), call(3)], current: nil)) == .decline(call(2)))
        #expect(HotkeyEffect.resolve(.hangUp, HotkeyCallState(ringing: [], current: nil)) == .none)
        #expect(HotkeyEffect.resolve(.hangUp, HotkeyCallState(ringing: [], current: call(9), conferenceLegs: [call(9), call(1), call(2)])) == .endConference)
        #expect(HotkeyEffect.resolve(.hangUp, HotkeyCallState(ringing: [], current: call(9), conferenceLegs: [call(9)])) == .hangUp(call(9)))
    }

    /// A consultation or a new call placed from a conference: the held legs stay.
    @Test func hangUpEndsConferenceOnlyWhenTheCurrentCallIsALeg() {
        let legs = [call(1), call(2)]
        #expect(HotkeyEffect.resolve(.hangUp, HotkeyCallState(ringing: [], current: call(3), conferenceLegs: legs)) == .hangUp(call(3)))
        #expect(HotkeyEffect.resolve(.hangUp, HotkeyCallState(ringing: [], current: call(1), conferenceLegs: legs)) == .endConference)
        #expect(HotkeyEffect.resolve(.hangUp, HotkeyCallState(ringing: [call(4)], current: nil, conferenceLegs: [])) == .decline(call(4)))
    }

    @Test func repeatsWithinHalfASecondCountOnce() {
        var f = HotkeyPressFilter()
        func accept(_ action: HotkeyAction, _ now: TimeInterval) -> Bool { f.accept(action, at: now) }
        let answers = [accept(.hangUp, 100), accept(.hangUp, 100.2),
                       accept(.mute, 100.3),            // per action
                       accept(.hangUp, 100.6),          // the window slides: a held key stays one press
                       accept(.hangUp, 101.2)]
        #expect(answers == [true, false, true, false, true])
    }

    @Test func oldPressesAreStale() {
        #expect(!HotkeyPressFilter.isStale(age: 0))
        #expect(!HotkeyPressFilter.isStale(age: 1))
        #expect(HotkeyPressFilter.isStale(age: 1.1))
    }

    @Test func recorderSwallowsRepeatsOfTheRecordedKey() {
        var k = HotkeyRecorderKeys()
        var v = k.keyDown(keyCode: 12, isRepeat: true, listening: true)
        #expect(v == .swallow && !k.isHolding)                              // held since before the click
        v = k.keyDown(keyCode: 12, isRepeat: false, listening: true)
        #expect(v == .record && k.isHolding)
        v = k.keyDown(keyCode: 12, isRepeat: true, listening: false)
        #expect(v == .swallow)                                              // ⌘Q held: must not reach the menu
        v = k.keyDown(keyCode: 13, isRepeat: true, listening: false)
        #expect(v == .pass && !k.isHolding)                                 // another key: not ours

        var up = HotkeyRecorderKeys()
        _ = up.keyDown(keyCode: 12, isRepeat: false, listening: true)
        up.keyUp(keyCode: 12)
        #expect(!up.isHolding)
        v = up.keyDown(keyCode: 12, isRepeat: false, listening: false)
        #expect(v == .pass)                                                 // a new press is the user's
    }

    @Test func menuShortcutsOfTheCallAndContactViews() {
        for (code, name) in [(47, "⌘."), (36, "⌘↩"), (14, "⌘E"), (51, "⌘⌫")] {
            #expect(HotkeyCombo(keyCode: code, modifiers: .command).issue == .usedByMenu, "\(name)")
        }
    }

    /// Every `.keyboardShortcut` and `keyEquivalent` literal with ⌘, ⌃ or ⌥ in the app's sources is in `menuShortcuts`.
    @Test func menuShortcutsListEveryShortcutInTheSources() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/MacroSIPApp")
        let named = ["return": 36, "delete": 51, "upArrow": 126, "downArrow": 125, "escape": 53, "tab": 48, "space": 49,
                     "leftArrow": 123, "rightArrow": 124]
        func code(_ key: String) -> Int? {
            HotkeyCombo.keyNames.first { $0.value == key.uppercased() }?.key
        }
        let shortcut = try NSRegularExpression(pattern: #"\.keyboardShortcut\((?:"([^"]+)"|\.(\w+))(?:, modifiers: ([^)]+))?\)"#)
        let item = try NSRegularExpression(pattern: #"keyEquivalent: "([^"]+)""#)
        func modifiers(_ text: String) -> HotkeyModifiers {
            var m: HotkeyModifiers = []
            if text.contains(".command") { m.insert(.command) }
            if text.contains(".control") { m.insert(.control) }
            if text.contains(".option") { m.insert(.option) }
            if text.contains(".shift") { m.insert(.shift) }
            return m
        }
        var found = 0
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
        while let url = files?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            let all = NSRange(text.startIndex..., in: text)
            func group(_ m: NSTextCheckingResult, _ i: Int) -> String? { Range(m.range(at: i), in: text).map { String(text[$0]) } }
            for m in shortcut.matches(in: text, range: all) {
                let mods = modifiers(group(m, 3) ?? ".command")     // SwiftUI's default is ⌘
                guard mods.hasCommandControlOrOption else { continue }
                guard let key = group(m, 1).flatMap(code) ?? group(m, 2).flatMap({ named[$0] }) else {
                    if group(m, 2) == "defaultAction" || group(m, 2) == "cancelAction" { continue }
                    Issue.record("unknown key in \(url.lastPathComponent): \(group(m, 0) ?? "")")
                    continue
                }
                found += 1
                #expect(HotkeyCombo.menuShortcuts.contains(HotkeyCombo(keyCode: key, modifiers: mods)),
                        "\(url.lastPathComponent): \(group(m, 0) ?? "") is missing from menuShortcuts")
            }
            for m in item.matches(in: text, range: all) {
                guard let key = group(m, 1).flatMap(code) else { continue }
                found += 1
                #expect(HotkeyCombo.menuShortcuts.contains(HotkeyCombo(keyCode: key, modifiers: .command)),     // NSMenuItem's default is ⌘
                        "\(url.lastPathComponent): \(group(m, 0) ?? "") is missing from menuShortcuts")
            }
        }
        #expect(found > 10)
    }

    @Test func muteNeedsACall() {
        #expect(HotkeyEffect.resolve(.mute, HotkeyCallState(ringing: [call(2)], current: nil)) == .none)
        #expect(HotkeyEffect.resolve(.mute, HotkeyCallState(ringing: [], current: call(9))) == .toggleMute)
    }
}
