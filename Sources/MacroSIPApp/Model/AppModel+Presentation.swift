import SwiftUI
import AppKit
import ServiceManagement
import MacroSIPCore

extension AppModel {
    // MARK: - Windows

    var mainWindowIsFrontmost: Bool {
        guard let w = mainWindow else { return false }
        return NSApp.isActive && !NSApp.isHidden && w.isVisible && !w.isMiniaturized && w.occlusionState.contains(.visible)
    }

    func showMainWindow() {
        if NSApp.activationPolicy() != .regular && settings.general.showDockIcon { applyActivationPolicy() }
        NSApp.activate(ignoringOtherApps: true)
        if let w = mainWindow {
            if w.isMiniaturized { w.deminiaturize(nil) }
            w.makeKeyAndOrderFront(nil)
        } else if let w = NSApp.windows.first(where: { $0.title == L.mainTitle }) {
            w.makeKeyAndOrderFront(nil)
        }
    }

    /// "Bring the main window to the front on an incoming call": the window is ordered in front without
    /// activating the app, so the keystrokes of whatever the user is typing in stay where they are. If the
    /// window is not the key window of the active app, keys that act on calls (keypad digits, Return in the
    /// call log, Return to answer) are ignored until the user clicks into the window.
    func bringMainWindowForward() {
        guard let w = mainWindow ?? NSApp.windows.first(where: { $0.title == L.mainTitle }) else { return }
        let alreadyKey = NSApp.isActive && w.isKeyWindow
        if w.isMiniaturized { w.deminiaturize(nil) }
        w.orderFrontRegardless()
        guard !alreadyKey else { return }
        incomingKeyGuard = true
        if clickMonitor == nil {
            clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                MainActor.assumeIsolated {
                    if let self, self.incomingKeyGuard, event.window === self.mainWindow { self.incomingKeyGuard = false }
                }
                return event
            }
        }
    }

    func openSettings(tab: SettingsTab? = nil, account: AccountID? = nil) {
        if let tab { settingsTab = tab }
        if let account { settingsSelectedAccount = account }
        NSApp.activate(ignoringOtherApps: true)
        if let open = openSettingsAction { open() }
        else { NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) }
    }

    func applyActivationPolicy() {
        let wanted: NSApplication.ActivationPolicy = settings.general.showDockIcon ? .regular : .accessory
        guard NSApp.activationPolicy() != wanted else { return }
        NSApp.setActivationPolicy(wanted)
        if wanted == .regular { NSApp.activate(ignoringOtherApps: true) }
    }

    private var canUseLoginItem: Bool { Bundle.main.bundleURL.pathExtension == "app" && !launch.isDemo }

    /// Registers or unregisters `SMAppService.mainApp` to match the setting. If macOS refuses, the
    /// switch goes back to the real state and the reason is shown in the pane.
    func applyLaunchAtLogin() {
        guard canUseLoginItem else { return }
        let service = SMAppService.mainApp
        let want = settings.general.launchAtLogin
        var failure: String?
        do {
            switch (want, service.status) {
            case (true, .enabled), (true, .requiresApproval), (false, .notRegistered), (false, .notFound): break
            case (true, _): try service.register(); AppLog.app.info("login item registered")
            case (false, _): try service.unregister(); AppLog.app.info("login item unregistered")
            }
        } catch {
            failure = L.launchAtLoginFailed(describe(error))
            AppLog.app.error("login item \(want ? "register" : "unregister") failed: \(describe(error))")
        }
        syncLoginItemStatus()
        loginItemError = failure
    }

    /// Makes the setting show what macOS really has (the user can remove the item in System Settings).
    func syncLoginItemStatus() {
        guard canUseLoginItem else { return }
        let status = SMAppService.mainApp.status
        loginItemNeedsApproval = status == .requiresApproval
        let registered = status == .enabled || status == .requiresApproval
        if settings.general.launchAtLogin != registered {
            updateSettings { $0.general.launchAtLogin = registered }
        }
    }

    func openLoginItemsSettings() { SMAppService.openSystemSettingsLoginItems() }

    // MARK: - Incoming presentation

    /// Floating panel and notification only when the main window is not visible or not frontmost;
    /// otherwise the call shows inside the main window.
    func refreshIncomingPresentation() {
        guard let call = incomingCall else {
            IncomingCallPanelController.shared.hide()
            CallNotifications.shared.removeAll()
            presentedIncoming = []
            return
        }
        // With "Bring the main window to the front" on, the panel appears in addition to the window.
        if mainWindowIsFrontmost && !settings.general.bringToFrontOnIncoming {
            IncomingCallPanelController.shared.hide()
            CallNotifications.shared.remove(call.id)
        } else {
            IncomingCallPanelController.shared.show(model: self)
            if !presentedIncoming.contains(call.id), !mainWindowIsFrontmost {
                presentedIncoming.insert(call.id)
                CallNotifications.shared.post(for: call, model: self)
            }
        }
    }

    func dismissIncomingPresentation(for id: CallID) {
        CallNotifications.shared.remove(id)
        presentedIncoming.remove(id)
        refreshIncomingPresentation()
    }
}
