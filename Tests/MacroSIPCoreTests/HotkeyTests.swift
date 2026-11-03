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
        #expect(HotkeyEffect.resolve(.hangUp, HotkeyCallState(ringing: [], current: call(9), conferenceLegs: 3)) == .endConference)
        #expect(HotkeyEffect.resolve(.hangUp, HotkeyCallState(ringing: [], current: call(9), conferenceLegs: 1)) == .hangUp(call(9)))
    }

    @Test func muteNeedsACall() {
        #expect(HotkeyEffect.resolve(.mute, HotkeyCallState(ringing: [call(2)], current: nil)) == .none)
        #expect(HotkeyEffect.resolve(.mute, HotkeyCallState(ringing: [], current: call(9))) == .toggleMute)
    }
}
