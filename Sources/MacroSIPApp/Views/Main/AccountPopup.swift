import SwiftUI
import AppKit
import MacroSIPCore

/// The account row above the number field (screen 1): a compact pop-up button at the left.
/// It sets the outgoing account for this call only. Clicking it opens `AccountPopupMenu`.
struct AccountRow: View {
    @Environment(AppModel.self) private var model
    @Local private var anchor = MenuAnchor()
    @Local private var pressed = false

    var body: some View {
        let current = model.effectiveAccount
        HStack(spacing: 0) {
            Button(action: openMenu) {
                HStack(spacing: 6) {
                    StatusDot(kind: current.map { model.dot(for: $0) } ?? .off, size: 8)
                    Text(current?.displayName ?? L.accountPopupNone)
                        .font(.system(size: 12.5, weight: .medium))
                        .lineLimit(1).truncationMode(.tail)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 16, height: 16)
                        .background(RoundedRectangle(cornerRadius: 4).fill(model.hasAccounts ? Theme.blue : Color.gray))
                }
                .padding(.leading, 8).padding(.trailing, 5)
                .frame(minHeight: 26)
                .background(RoundedRectangle(cornerRadius: 6).fill(pressed ? Theme.fill2 : Theme.control))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.controlBorder, lineWidth: 0.5))
                .shadow(color: .black.opacity(0.08), radius: 0.75, y: 0.75)
                .contentShape(Rectangle())
                .background(MenuAnchorView(anchor: anchor))
            }
            .buttonStyle(.plain)
            .disabled(!model.hasAccounts)
            .opacity(model.hasAccounts ? 1 : 0.5)
            .help(L.accountPickerHelp)
            .accessibilityLabel(L.accountPickerHelp)
            .accessibilityValue(current?.displayName ?? L.accountPopupNone)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.top, 3)
        .padding(.bottom, 6)
    }

    private func openMenu() {
        guard let view = anchor.view, model.hasAccounts else { return }
        pressed = true
        // Leave the button's own click handling before the menu starts its tracking loop.
        DispatchQueue.main.async {
            AccountPopupMenu(model: model).show(from: view)
            pressed = false
        }
    }
}

/// Reference to the NSView the menu is positioned against.
@MainActor
final class MenuAnchor {
    weak var view: NSView?
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

private struct MenuAnchorView: NSViewRepresentable {
    let anchor: MenuAnchor
    func makeNSView(context: Context) -> NSView {
        let v = FlippedView()
        anchor.view = v
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) { anchor.view = nsView }
}

// MARK: - Menu

/// The account pop-up: header, one row per account (pick with the name, switch on or off with
/// the switch without closing the menu), separator, "Account Settings…".
/// Rows are custom views so that the switch can be used while the menu stays open.
@MainActor
final class AccountPopupMenu: NSObject {
    static let width: CGFloat = 262
    private let model: AppModel
    private(set) var rows: [AccountMenuRow] = []
    private let menu = NSMenu()

    init(model: AppModel) {
        self.model = model
        super.init()
    }

    /// Builds the menu without showing it (used by the snapshot of the open pop-up).
    func build() -> NSMenu {
        menu.autoenablesItems = false
        menu.minimumWidth = Self.width
        menu.addItem(viewItem(AccountMenuHeader()))
        for account in model.accounts {
            let row = AccountMenuRow(accountID: account.id)
            row.onPick = { [weak self] id in self?.pick(id) }
            row.onToggle = { [weak self] id, on in self?.toggle(id, on) }
            rows.append(row)
            menu.addItem(viewItem(row))
        }
        refresh()
        menu.addItem(.separator())
        let settings = NSMenuItem(title: L.accountPopupSettings, action: #selector(openSettings), keyEquivalent: ",")
        settings.keyEquivalentModifierMask = .command
        settings.target = self
        menu.addItem(settings)
        return menu
    }

    func show(from anchor: NSView) {
        let menu = build()
        // Menu tracking does not service the main actor's queue: the engine work started by a switch
        // runs when the menu closes. The rows therefore follow the model (store), not the engine.
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.bounds.height + 3), in: anchor)
    }

    private func viewItem(_ view: NSView) -> NSMenuItem {
        let item = NSMenuItem()
        item.view = view
        item.isEnabled = true
        return item
    }

    private func refresh() {
        let selected = model.effectiveAccount?.id
        for row in rows {
            guard let account = model.account(row.accountID) else { continue }
            row.update(account: account, state: model.registration[account.id], dot: model.dot(for: account),
                       selected: account.id == selected)
        }
    }

    private func pick(_ id: AccountID) {
        guard model.account(id)?.enabled == true else { return }
        model.selectedAccountID = id
        menu.cancelTracking()
    }

    private func toggle(_ id: AccountID, _ on: Bool) {
        model.setAccountEnabled(id, on)
        refresh()           // the menu stays open
    }

    @objc private func openSettings() {
        model.openSettings(tab: .accounts)
    }
}

private final class AccountMenuHeader: NSView {
    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: AccountPopupMenu.width, height: 22))
        let label = NSTextField(labelWithString: L.accountPopupHeader)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.frame = NSRect(x: 14, y: 3, width: AccountPopupMenu.width - 28, height: 15)
        addSubview(label)
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError() }
}

@MainActor
private final class DotView: NSView {
    var kind: RegistrationDot = .off { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        switch kind {
        case .registered: NSColor.systemGreen.setFill(); NSBezierPath(ovalIn: bounds).fill()
        case .registering: NSColor.systemOrange.setFill(); NSBezierPath(ovalIn: bounds).fill()
        case .failed: NSColor.systemRed.setFill(); NSBezierPath(ovalIn: bounds).fill()
        case .off:
            let path = NSBezierPath(ovalIn: bounds.insetBy(dx: 0.75, dy: 0.75))
            path.lineWidth = 1.5
            NSColor.secondaryLabelColor.setStroke()
            path.stroke()
        }
    }
}

/// One account: check column, registration dot, name and address, switch.
@MainActor
final class AccountMenuRow: NSView {
    static let height: CGFloat = 37
    let accountID: AccountID
    var onPick: ((AccountID) -> Void)?
    var onToggle: ((AccountID, Bool) -> Void)?

    private let check = NSImageView()
    private let dot = DotView()
    private let name = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    let toggle = NSSwitch()
    private var hovered = false
    private var accountEnabled = true
    private var failedDetail = false

    init(accountID: AccountID) {
        self.accountID = accountID
        super.init(frame: NSRect(x: 0, y: 0, width: AccountPopupMenu.width, height: Self.height))
        check.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
        check.contentTintColor = .labelColor
        name.font = .systemFont(ofSize: 13, weight: .medium)
        detail.font = .systemFont(ofSize: 11)
        for l in [name, detail] { l.lineBreakMode = .byTruncatingTail; l.cell?.truncatesLastVisibleLine = true }
        toggle.controlSize = .mini
        toggle.target = self
        toggle.action = #selector(toggled)
        for v in [check, dot, name, detail, toggle] as [NSView] { addSubview(v) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        setAccessibilityRole(.menuItem)
    }
    required init?(coder: NSCoder) { fatalError() }

    func update(account: AccountConfig, state: RegistrationState?, dot kind: RegistrationDot, selected: Bool) {
        let address = "\(account.username)@\(account.domain)"
        accountEnabled = account.enabled
        name.stringValue = account.displayName
        if account.enabled, account.registerWithServer, let reason = state?.fullReason {
            detail.stringValue = L.accountPopupFailed(reason, address)
            failedDetail = true
        } else {
            detail.stringValue = address
            failedDetail = false
        }
        dot.kind = kind
        check.isHidden = !selected
        toggle.state = account.enabled ? .on : .off
        toolTip = detail.stringValue
        toggle.setAccessibilityLabel("\(L.accountEnabled): \(account.displayName)")
        setAccessibilityLabel(account.displayName)
        applyColors()
        needsDisplay = true
    }

    private var highlighted: Bool { accountEnabled && (hovered || enclosingMenuItem?.isHighlighted == true) }

    private func applyColors() {
        let hl = highlighted
        let on = NSColor.selectedMenuItemTextColor
        name.textColor = hl ? on : (accountEnabled ? .labelColor : .tertiaryLabelColor)
        detail.textColor = hl ? on.withAlphaComponent(0.85)
            : (!accountEnabled ? .tertiaryLabelColor : (failedDetail ? .systemRed : .secondaryLabelColor))
        check.contentTintColor = hl ? on : .labelColor
        dot.alphaValue = accountEnabled ? 1 : 0.6
    }

    override func layout() {
        super.layout()
        let h = bounds.height, w = bounds.width
        check.frame = NSRect(x: 14, y: (h - 12) / 2, width: 12, height: 12)
        dot.frame = NSRect(x: 34, y: (h - 8) / 2, width: 8, height: 8)
        let sw = NSSize(width: 26, height: 15)
        toggle.frame = NSRect(x: w - 14 - sw.width, y: (h - sw.height) / 2, width: sw.width, height: sw.height)
        let textX: CGFloat = 50
        let textW = toggle.frame.minX - 8 - textX
        name.frame = NSRect(x: textX, y: h / 2 + 0.5, width: textW, height: 16)
        detail.frame = NSRect(x: textX, y: h / 2 - 14.5, width: textW, height: 14)
    }

    override func draw(_ dirtyRect: NSRect) {
        applyColors()
        if highlighted {
            NSColor.selectedContentBackgroundColor.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 1), xRadius: 5, yRadius: 5).fill()
        }
    }

    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseUp(with event: NSEvent) {
        guard accountEnabled else { return }
        onPick?(accountID)
    }

    @objc private func toggled() {
        onToggle?(accountID, toggle.state == .on)
    }
}
