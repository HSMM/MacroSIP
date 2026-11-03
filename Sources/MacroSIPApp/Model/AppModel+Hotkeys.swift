import Foundation
import MacroSIPCore

/// Global hotkeys (Settings › Calls): answer, hang up, mute from any app. The combinations and the on/off
/// switch live in `AppSettings.hotkeys`; `Platform/GlobalHotkeys.swift` registers them with the system.
/// A press does what the matching button does, by the same `AppModel` action.
extension AppModel {
    func startHotkeys() {
        guard globalHotkeys == nil else { return }
        globalHotkeys = GlobalHotkeys { [weak self] action in self?.handleHotkey(action) }
        applyHotkeys()
    }

    func stopHotkeys() {
        globalHotkeys?.stop()
        globalHotkeys = nil
        hotkeyFailures = [:]
    }

    /// Brings the system's registrations in line with the settings. Demo and mock launches register nothing
    /// (unless a demo check asks for it), so a screenshot run never takes keys from the person using the Mac;
    /// nothing is registered either while a recorder listens for a new combination.
    func applyHotkeys() {
        guard let globalHotkeys else { return }
        let allowed = !(launch.isDemo || isMockEngine) || hotkeysInDemo
        let wanted = allowed && !hotkeyRecording ? settings.hotkeys.active : [:]
        let failures = globalHotkeys.apply(wanted)
        if !hotkeyRecording { hotkeyFailures = failures }
    }

    /// The switch in Settings. The first time on, the three fields are filled with the defaults.
    func setHotkeysEnabled(_ on: Bool) {
        hotkeyIssues = [:]
        updateSettings { $0.hotkeys.setEnabled(on) }
    }

    /// A combination from the recorder (nil clears the field). A refused one is kept in `hotkeyIssues`
    /// for the row to explain, and the old combination stays.
    func setHotkey(_ combo: HotkeyCombo?, for action: HotkeyAction) {
        var issue: HotkeyIssue?
        updateSettings { issue = $0.hotkeys.assign(combo, to: action) }
        hotkeyIssues[action] = issue
        hotkeyFailures[action] = nil
        applyHotkeys()      // retries the combination even when the settings did not change
    }

    func setHotkeyRecording(_ on: Bool) {
        guard hotkeyRecording != on else { return }
        hotkeyRecording = on
        applyHotkeys()
    }

    /// What the call list looks like to a hotkey.
    var hotkeyCallState: HotkeyCallState {
        HotkeyCallState(ringing: ringingCalls.map(\.id), current: currentCall?.id, conferenceLegs: conferenceCalls.count)
    }

    func handleHotkey(_ action: HotkeyAction) {
        switch HotkeyEffect.resolve(action, hotkeyCallState) {
        case .none: break
        case let .answer(id): answer(id)
        case let .decline(id): decline(id)
        case let .hangUp(id): hangup(id)
        case .endConference: endConference()
        case .toggleMute: toggleMuteCurrent()
        }
    }
}
