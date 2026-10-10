import SwiftUI
import AppKit

/// Re-runs `apply` whenever an `@Observable` value it reads changes.
@MainActor
func observeContinuously(_ apply: @escaping @MainActor () -> Void) {
    withObservationTracking {
        apply()
    } onChange: {
        Task { @MainActor in observeContinuously(apply) }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: StatusItemController?
    private let model = AppModel.shared
    private var lastURL: (URL, Date)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.applyActivationPolicy()
        installFallbackIconIfNeeded()
        CallNotifications.shared.setup()
        statusItem = StatusItemController(model: model)

        observeContinuously { [model] in
            let n = model.missedUnseen
            NSApp.dockTile.badgeLabel = n > 0 ? "\(n)" : nil
        }
        observeContinuously { [weak self] in self?.statusItem?.refresh() }
        observeContinuously { [model] in model.refreshIncomingPresentation() }

        // The window state decides between floating panel and in-window call panel.
        let nc = NotificationCenter.default
        let names: [Notification.Name] = [
            NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
            NSApplication.didHideNotification, NSApplication.didUnhideNotification,
            NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
            NSWindow.didChangeOcclusionStateNotification, NSWindow.willCloseNotification,
        ]
        for name in names {
            nc.addObserver(forName: name, object: nil, queue: .main) { [model] note in
                let isPanel = note.object is FloatingCallPanel
                MainActor.assumeIsolated { if !isPanel { model.refreshIncomingPresentation() } }
            }
        }
        Task { await model.bootstrap() }
    }

    /// The project has no .icns yet; draw one so the Dock and notifications do not show a blank icon.
    private func installFallbackIconIfNeeded() {
        guard Bundle.main.url(forResource: "AppIcon", withExtension: "icns") == nil else { return }
        let renderer = ImageRenderer(content: AppIconView(size: 512).padding(32))
        renderer.scale = 2
        if let image = renderer.nsImage { NSApp.applicationIconImage = image }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !model.settings.general.keepRunningInMenuBar
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { model.showMainWindow() }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { @MainActor in
            await model.shutdown()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if let (last, at) = lastURL, last == url, Date().timeIntervalSince(at) < 1 { continue }
            lastURL = (url, Date())
            model.handleURL(url)
        }
    }
}

/// Captures the hosting NSWindow of the main window and fixes its size.
struct MainWindowAccessor: NSViewRepresentable {
    let model: AppModel

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { [weak view] in configure(view?.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { [weak nsView] in configure(nsView?.window) }
    }

    private func configure(_ window: NSWindow?) {
        guard let window, model.mainWindow !== window else { return }
        model.mainWindow = window
        window.standardWindowButton(.zoomButton)?.isEnabled = false
        window.collectionBehavior.insert(.fullScreenNone)
        window.isRestorable = false
        #if DEBUG
        if model.launch.demoState == "incoming-hidden" { window.orderOut(nil) }
        #endif
    }
}
