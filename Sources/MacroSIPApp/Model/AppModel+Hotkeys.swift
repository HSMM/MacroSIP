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
        let wanted = allowed && hotkeyListening == nil ? settings.hotkeys.active : [:]
        let failures = globalHotkeys.apply(wanted)
        if hotkeyListening == nil { hotkeyFailures = failures }
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

    /// A recorder starts or stops listening. One row listens at a time: a click on another row hands over, and the
    /// first row's late "stopped" then changes nothing, so the hotkeys stay off until no row listens.
    func setHotkeyListening(_ on: Bool, for action: HotkeyAction) {
        let new = on ? action : (hotkeyListening == action ? nil : hotkeyListening)
        guard new != hotkeyListening else { return }
        hotkeyListening = new
        applyHotkeys()
    }

    /// The app or the window lost the keyboard: whatever row listens stops, and the hotkeys work again.
    func stopHotkeyListening() {
        if let action = hotkeyListening { setHotkeyListening(false, for: action) }
    }

    /// What the call list looks like to a hotkey.
    var hotkeyCallState: HotkeyCallState {
        HotkeyCallState(ringing: ringingCalls.map(\.id), current: currentCall?.id, conferenceLegs: conferenceCalls.map(\.id))
    }

    func handleHotkey(_ action: HotkeyAction) {
        let effect = HotkeyEffect.resolve(action, hotkeyCallState)
        guard effect != .none, hotkeyPresses.accept(action, at: ProcessInfo.processInfo.systemUptime) else { return }
        switch effect {
        case .none: break
        case let .answer(id): answer(id)
        case let .decline(id): decline(id)
        case let .hangUp(id): hangup(id)
        case .endConference: endConference()
        case .toggleMute: toggleMuteCurrent()
        }
    }
}
