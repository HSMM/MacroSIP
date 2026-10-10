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

    func applyLaunchAtLogin() {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        do {
            if settings.general.launchAtLogin { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            showBanner(describe(error))
        }
    }

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
        if mainWindowIsFrontmost {
            IncomingCallPanelController.shared.hide()
            CallNotifications.shared.remove(call.id)
        } else {
            IncomingCallPanelController.shared.show(model: self)
            if !presentedIncoming.contains(call.id) {
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
