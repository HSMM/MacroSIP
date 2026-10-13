import AppKit

extension AppModel {
    /// A call that is ringing, being set up, connected or on hold. Updates wait for these to end
    /// (ADR 0013), and quitting asks first.
    var hasLiveCalls: Bool { calls.contains(where: \.isLive) }

    /// Asks before quitting would end calls. `true` when there is no call or the user confirms.
    func confirmQuitIfCallsAreLive() -> Bool {
        guard hasLiveCalls else { return true }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L.quitDuringCallTitle
        alert.informativeText = L.quitDuringCallMessage
        alert.addButton(withTitle: L.quitDuringCallConfirm)
        alert.addButton(withTitle: L.commonCancel)
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }
}
