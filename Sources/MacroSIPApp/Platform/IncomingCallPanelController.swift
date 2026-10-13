import SwiftUI
import AppKit

/// Non-activating, always-on-top panel for incoming calls (SCREENS.md 6.1). It never becomes key,
/// so it cannot steal keyboard focus from the app the user is typing in.
final class FloatingCallPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class IncomingCallPanelController: NSObject {
    static let shared = IncomingCallPanelController()

    private var panel: FloatingCallPanel?
    private var hosting: NSHostingView<AnyView>?
    private var movingProgrammatically = false
    private let originKey = "incomingPanelOrigin"

    var isVisible: Bool { panel?.isVisible ?? false }

    func show(model: AppModel) {
        let panel = self.panel ?? makePanel(model: model)
        resize(panel)
        if !panel.isVisible {
            place(panel, model: model)
            panel.orderFrontRegardless()
        }
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel(model: AppModel) -> FloatingCallPanel {
        let panel = FloatingCallPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 190),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.title = L.incomingAnswer
        let host = NSHostingView(rootView: AnyView(IncomingCallPanelView().environment(model)))
        panel.contentView = host
        hosting = host
        self.panel = panel
        NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveOrigin() }
        }
        return panel
    }

    private func resize(_ panel: FloatingCallPanel) {
        guard let hosting else { return }
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        guard size.width > 0, size.height > 0 else { return }
        var frame = panel.frame
        let newSize = NSSize(width: 300, height: size.height)
        frame.origin.y += frame.height - newSize.height       // keep the top edge in place
        frame.size = newSize
        movingProgrammatically = true
        panel.setFrame(frame, display: true)
        movingProgrammatically = false
    }

    private func place(_ panel: FloatingCallPanel, model: AppModel) {
        movingProgrammatically = true
        defer { movingProgrammatically = false }
        if let s = model.prefs.string(forKey: originKey) {
            let origin = NSPointFromString(s)
            let rect = NSRect(origin: origin, size: panel.frame.size)
            if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(rect) }) {
                panel.setFrameOrigin(origin)
                return
            }
        }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens[0]
        let vf = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: vf.midX - panel.frame.width / 2, y: vf.midY - panel.frame.height / 2 + vf.height * 0.15))
    }

    private func saveOrigin() {
        guard !movingProgrammatically, let panel, panel.isVisible else { return }
        AppModel.shared.prefs.set(NSStringFromPoint(panel.frame.origin), forKey: originKey)
    }
}
