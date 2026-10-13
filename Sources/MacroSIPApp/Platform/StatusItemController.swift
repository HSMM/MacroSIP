import SwiftUI
import AppKit
import MacroSIPCore

/// Menu bar status item with a native NSMenu (SCREENS.md section 7).
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate, NSTextFieldDelegate {
    static weak var current: StatusItemController?
    private let model: AppModel
    private let item: NSStatusItem
    private let menu = NSMenu()
    private var quickField: NSTextField?
    private var timer: Timer?
    private var appearanceObservation: NSKeyValueObservation?

    init(model: AppModel) {
        self.model = model
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        StatusItemController.current = self
        menu.delegate = self
        menu.autoenablesItems = false
        if let button = item.button {
            button.target = self
            button.action = #selector(clicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imagePosition = .imageLeading
            button.setAccessibilityLabel(model.appName)
        }
        appearanceObservation = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            Task { @MainActor in self?.refresh() }
        }
        refresh()
    }

    // MARK: - Icon

    private enum IconState {
        case offline, registered
    }

    /// Reads the model; called from an observation loop so it re-runs when anything it reads changes.
    func refresh() {
        guard let button = item.button else { return }
        let missed = model.missedUnseen
        let onCall = model.liveCalls.contains { $0.isEstablished } ? model.currentCall : nil
        let dark = button.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let ink: NSColor = dark ? .white : .black
        let registered = model.anyRegistered
        let online = model.networkOnline
        let image = Self.render(solid: online && (registered || onCall != nil), ink: ink, badge: missed, moon: model.doNotDisturb,
                                noNetwork: !online)
        button.image = image
        button.toolTip = !online ? "\(model.appName) · \(L.menubarNoNetwork)"
            : (registered ? model.appName : "\(model.appName) · \(L.menubarOffline)")
        if let call = onCall, let start = call.startedAt {
            button.attributedTitle = NSAttributedString(
                string: " " + formatDuration(Date().timeIntervalSince(start)),
                attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)])
            startTimer()
        } else {
            button.title = ""
            stopTimer()
        }
    }

    private func startTimer() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    private func stopTimer() { timer?.invalidate(); timer = nil }

    private static func render(solid: Bool, ink: NSColor, badge: Int, moon: Bool, noNetwork: Bool = false) -> NSImage {
        let symbolName = solid ? "phone.fill" : "phone"
        let cfg = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        let phone = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg.applying(.init(paletteColors: [solid ? ink : ink.withAlphaComponent(0.6)])))
        let moonImage = moon ? NSImage(systemSymbolName: "moon.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 9, weight: .regular)
                .applying(.init(paletteColors: [ink]))) : nil
        let badgeText = badge > 99 ? "99+" : "\(badge)"
        let badgeFont = NSFont.systemFont(ofSize: 8.5, weight: .bold)
        let badgeWidth = badge > 0 ? max(12, (badgeText as NSString).size(withAttributes: [.font: badgeFont]).width + 7) : 0
        let width = 18 + (moonImage != nil ? 11 : 0) + (badge > 0 ? badgeWidth - 5 : 0)
        let size = NSSize(width: width, height: 18)
        // Drawn eagerly on the main thread: AppKit may call a lazy drawing handler off-main when
        // it renders the status item, and a main-actor closure would then trap.
        let image = NSImage(size: size)
        image.lockFocus()
        do {
            if let phone {
                let r = NSRect(x: 0, y: (size.height - phone.size.height) / 2, width: phone.size.width, height: phone.size.height)
                phone.draw(in: r)
                if noNetwork {      // a slash across the outline phone: no network path
                    let slash = NSBezierPath()
                    slash.move(to: NSPoint(x: 2, y: 15)); slash.line(to: NSPoint(x: 15, y: 2))
                    slash.lineWidth = 1.6; slash.lineCapStyle = .round
                    ink.setStroke(); slash.stroke()
                }
            }
            var x: CGFloat = 17
            if let moonImage {
                moonImage.draw(in: NSRect(x: x - 1, y: 3, width: moonImage.size.width, height: moonImage.size.height))
                x += moonImage.size.width
            }
            if badge > 0 {
                let rect = NSRect(x: size.width - badgeWidth, y: size.height - 12, width: badgeWidth, height: 12)
                NSColor.systemRed.setFill()
                NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
                let attrs: [NSAttributedString.Key: Any] = [.font: badgeFont, .foregroundColor: NSColor.white]
                let ts = (badgeText as NSString).size(withAttributes: attrs)
                (badgeText as NSString).draw(at: NSPoint(x: rect.midX - ts.width / 2, y: rect.midY - ts.height / 2), withAttributes: attrs)
            }
        }
        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    #if DEBUG
    /// Titles of the menu as it would be built now (used by the demo snapshot).
    func debugMenuTitles() -> [String] { debugMenuEntries().map(\.title) }

    /// Titles with their enabled state (the self-test checks the voicemail item).
    func debugMenuEntries() -> [(title: String, enabled: Bool)] {
        let m = NSMenu()
        buildMenu(m)
        return m.items.flatMap { item -> [(title: String, enabled: Bool)] in
            let line = item.isSeparatorItem ? "----" : (item.view != nil ? "[quick dial field]" : item.attributedTitle?.string ?? item.title) + (item.state == .on ? "  [x]" : "")
            let subs = item.submenu?.items.map { ("      " + $0.title + ($0.state == .on ? "  [x]" : ""), $0.isEnabled) } ?? []
            return [(line, item.isEnabled)] + subs
        }
    }
    #endif

    // MARK: - Click and menu

    @objc private func clicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        let isRight = event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true
        if !isRight, model.liveCalls.contains(where: { $0.isEstablished }) {
            model.showMainWindow()      // SCREENS.md 7.1: clicking the icon during a call brings the window forward
            return
        }
        item.menu = menu
        sender.performClick(nil)
        item.menu = nil
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        buildMenu(menu)
    }

    private func buildMenu(_ menu: NSMenu) {
        // 1. accounts
        for account in model.enabledAccounts {
            let state = model.registration[account.id] ?? .unregistered
            let line = NSMenuItem()
            line.target = self
            line.action = #selector(openAccount(_:))
            line.representedObject = account.id.raw.uuidString
            let text = NSMutableAttributedString(string: account.displayName)
            if let reason = state.fullReason {
                text.append(NSAttributedString(string: "  " + L.menuAccountFailed(reason), attributes: [.foregroundColor: NSColor.systemRed]))
            } else {
                text.append(NSAttributedString(string: "  \(account.username)@\(account.domain)",
                                               attributes: [.foregroundColor: NSColor.secondaryLabelColor, .font: NSFont.menuFont(ofSize: 11.5)]))
            }
            line.attributedTitle = text
            let color: NSColor
            switch model.dot(for: account) {
            case .registered: color = .systemGreen
            case .registering: color = .systemOrange
            case .failed: color = .systemRed
            case .off: color = .systemGray
            }
            line.image = Self.dotImage(color)
            menu.addItem(line)
        }
        // 1a. voicemail (7.2): one item per enabled account with a voicemail number; disabled while nothing waits
        let voicemailAccounts = model.voicemailAccounts
        for account in voicemailAccounts {
            let state = model.voicemail[account.id]
            let waiting = state?.waiting == true
            let count = waiting ? (state?.new ?? 0) : 0
            let name = voicemailAccounts.count > 1 ? "\(L.menuVoicemail) · \(account.displayName)" : L.menuVoicemail
            let mi = NSMenuItem(title: "\(name): \(L.voicemailNewCount(count))", action: #selector(callVoicemail(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = account.id.raw.uuidString
            mi.isEnabled = waiting
            mi.image = NSImage(systemSymbolName: waiting ? "envelope.badge.fill" : "envelope", accessibilityDescription: nil)
            menu.addItem(mi)
        }
        if !model.accounts.isEmpty { menu.addItem(.separator()) }

        // 3. quick dial
        let quick = NSMenuItem()
        quick.view = makeQuickDialView()
        menu.addItem(quick)
        menu.addItem(.separator())

        // 5/6. recent calls
        let recent = Array(model.callLog.prefix(5))
        if !recent.isEmpty {
            menu.addItem(NSMenuItem.sectionHeader(title: L.menuRecentCalls))
            for entry in recent {
                let mi = NSMenuItem()
                mi.target = self
                mi.action = #selector(callRecent(_:))
                mi.representedObject = entry.id.uuidString
                let missed = entry.direction == .missed
                let title = NSMutableAttributedString(
                    string: model.name(for: entry),
                    attributes: missed ? [.foregroundColor: NSColor.systemRed] : [:])
                title.append(NSAttributedString(
                    string: "   " + Self.timeFormatter.string(from: entry.startedAt),
                    attributes: [.foregroundColor: NSColor.secondaryLabelColor, .font: NSFont.menuFont(ofSize: 11.5)]))
                mi.attributedTitle = title
                let symbol = entry.direction == .outgoing ? "phone.arrow.up.right" : "phone.arrow.down.left"
                let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
                if missed { mi.image = img?.withSymbolConfiguration(.init(paletteColors: [.systemRed])) } else { mi.image = img }
                menu.addItem(mi)
            }
            menu.addItem(.separator())
        }

        // 8. DND (7.2): a submenu; the title carries the time left of a timed one
        let dnd = NSMenuItem(title: model.dndTitle(), action: nil, keyEquivalent: "")
        dnd.state = model.doNotDisturb ? .on : .off
        let dndMenu = NSMenu()
        for choice in DNDChoice.presets {
            let mi = NSMenuItem(title: Self.dndTitle(choice), action: #selector(pickDND(_:)), keyEquivalent: "")
            mi.target = self
            mi.tag = Self.dndTag(choice)
            switch choice {
            case .off: mi.state = model.doNotDisturb ? .off : .on
            case .on: mi.state = model.doNotDisturb && model.doNotDisturbUntil == nil ? .on : .off
            default: break
            }
            dndMenu.addItem(mi)
            if choice == .on { dndMenu.addItem(.separator()) }
        }
        dnd.submenu = dndMenu
        menu.addItem(dnd)

        // 9. My Status (7.4)
        let status = NSMenuItem()
        let current = model.effectivePresence
        let statusTitle = NSMutableAttributedString(string: L.menuMyStatus)
        statusTitle.append(NSAttributedString(
            string: "   " + Self.statusTitle(current),
            attributes: [.foregroundColor: NSColor.secondaryLabelColor, .font: NSFont.menuFont(ofSize: 11.5)]))
        status.attributedTitle = statusTitle
        let sub = NSMenu()
        for option in [PresenceStatus.available, .away, .dnd] {
            let mi = NSMenuItem(title: Self.statusTitle(option), action: #selector(setMyStatus(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = option.rawValue
            mi.state = option == current ? .on : .off
            mi.image = Self.dotImage(Self.statusColor(option))
            sub.addItem(mi)
        }
        status.submenu = sub
        menu.addItem(status)
        menu.addItem(.separator())

        // 11-14
        let show = NSMenuItem(title: L.menuShowApp(model.appName), action: #selector(showApp), keyEquivalent: "0")
        show.target = self
        menu.addItem(show)
        let settings = NSMenuItem(title: L.menuSettings, action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: L.menuQuitApp(model.appName), action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()

    private static func dotImage(_ color: NSColor) -> NSImage {
        let rect = NSRect(x: 0, y: 0, width: 10, height: 10)
        let img = NSImage(size: rect.size)
        img.lockFocus()
        color.setFill()
        NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
        img.unlockFocus()
        img.isTemplate = false
        return img
    }

    private func makeQuickDialView() -> NSView {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 286, height: 34))
        let field = NSTextField(frame: NSRect(x: 14, y: 5, width: 216, height: 24))
        field.placeholderString = L.menuQuickDialPlaceholder
        field.bezelStyle = .roundedBezel
        field.isEditable = true
        field.isEnabled = model.hasAccounts
        field.target = self
        field.action = #selector(quickDial(_:))
        field.focusRingType = .default
        quickField = field
        container.addSubview(field)

        let button = NSButton(frame: NSRect(x: 238, y: 4, width: 26, height: 26))
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.backgroundColor = NSColor.systemGreen.cgColor
        button.layer?.cornerRadius = 13
        button.image = NSImage(systemSymbolName: "phone.fill", accessibilityDescription: L.menuCall)?
            .withSymbolConfiguration(.init(paletteColors: [.white]))
        button.imagePosition = .imageOnly
        button.isEnabled = model.hasAccounts
        button.target = self
        button.action = #selector(quickDial(_:))
        container.addSubview(button)
        return container
    }

    @objc private func quickDial(_ sender: Any?) {
        let text = quickField?.stringValue.trimmingCharacters(in: .whitespaces) ?? ""
        menu.cancelTracking()
        if text.isEmpty {
            if let last = model.lastDialedNumber { model.placeCall(to: last) }
        } else {
            model.placeCall(to: text)
        }
    }

    @objc private func openAccount(_ sender: NSMenuItem) {
        guard let s = sender.representedObject as? String, let uuid = UUID(uuidString: s) else { return }
        model.openSettings(tab: .accounts, account: AccountID(raw: uuid))
    }

    @objc private func callVoicemail(_ sender: NSMenuItem) {
        guard let s = sender.representedObject as? String, let uuid = UUID(uuidString: s) else { return }
        model.callVoicemail(for: AccountID(raw: uuid))
    }

    @objc private func callRecent(_ sender: NSMenuItem) {
        guard let s = sender.representedObject as? String, let uuid = UUID(uuidString: s),
              let entry = model.callLog.first(where: { $0.id == uuid }) else { return }
        model.callBack(entry)
    }

    private static func statusTitle(_ s: PresenceStatus) -> String {
        switch s {
        case .available, .offline: return L.menuStatusAvailable
        case .away: return L.menuStatusAway
        case .dnd, .ringing: return L.menuStatusDND   // ringing is never our own status
        }
    }

    private static func statusColor(_ s: PresenceStatus) -> NSColor {
        switch s {
        case .available, .offline: return .systemGreen
        case .away: return .systemYellow
        case .dnd, .ringing: return .systemRed
        }
    }

    @objc private func setMyStatus(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let status = PresenceStatus(rawValue: raw) else { return }
        model.setMyStatus(status)
    }

    private static func dndTitle(_ c: DNDChoice) -> String {
        switch c {
        case .off: return L.dndOff
        case .on: return L.dndOn
        case let .minutes(m): return m == 30 ? L.dnd30Minutes : L.dnd1Hour
        case .untilTomorrowMorning: return L.dndTomorrow
        }
    }

    private static func dndTag(_ c: DNDChoice) -> Int {
        switch c {
        case .off: return 0
        case .on: return 1
        case let .minutes(m): return m          // 30, 60
        case .untilTomorrowMorning: return -1
        }
    }

    @objc private func pickDND(_ sender: NSMenuItem) {
        switch sender.tag {
        case 0: model.setDND(.off)
        case 1: model.setDND(.on)
        case -1: model.setDND(.untilTomorrowMorning)
        default: model.setDND(.minutes(sender.tag))
        }
    }

    @objc private func showApp() { model.showMainWindow() }
    @objc private func openSettings() { model.openSettings() }
    @objc private func quitApp() { NSApp.terminate(nil) }
}
