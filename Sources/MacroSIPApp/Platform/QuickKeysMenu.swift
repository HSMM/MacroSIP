import AppKit
import MacroSIPCore

/// The quick-key items of the menu bar, as AppKit items that AppKit validates every time the menu opens or a
/// key equivalent is looked up: Call › Quick keys › ⌘1…⌘9 (names, enabled state) and View › Show Quick Keys
/// (check mark). SwiftUI's `Commands` do not rebuild a menu when the settings change, so a menu made there
/// shows the keys of the moment it was built.
///
/// The Call menu is found by its title; the View entry is placed next to a hidden SwiftUI placeholder of the
/// same name (`AppCommands`), which also tells where the View menu is in any language.
@MainActor
final class QuickKeysMenu: NSObject, NSMenuItemValidation {
    private let model: AppModel
    private(set) var keysMenu: NSMenu?
    private var installedFor: (call: NSMenu, view: NSMenu)?

    init(model: AppModel) { self.model = model }

    /// Installs the items once the SwiftUI menus exist; retries for a few seconds. Safe to call again.
    func install(attempt: Int = 0) {
        if rebuildIfNeeded() { return }
        guard attempt < 40 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            MainActor.assumeIsolated { self?.install(attempt: attempt + 1) }
        }
    }

    /// true when the items are in place.
    @discardableResult
    func rebuildIfNeeded() -> Bool {
        guard let main = NSApp.mainMenu,
              let callMenu = main.items.first(where: { $0.title == L.menuCall })?.submenu,
              let anchor = Self.findAnchor(in: main), let viewMenu = anchor.menu else { return false }
        if let installed = installedFor, installed.call === callMenu, installed.view === viewMenu,
           keysMenu?.supermenu != nil { return true }

        // Call › Quick keys
        let sub = NSMenu(title: L.quickKeysTitle)
        for n in 1...QuickKeysSettings.shortcutCount {
            let item = NSMenuItem(title: L.quickKeysRowEmpty, action: #selector(pressKey(_:)), keyEquivalent: String(n))
            item.keyEquivalentModifierMask = .command
            item.tag = n
            item.target = self
            sub.addItem(item)
        }
        let parent = NSMenuItem(title: L.quickKeysTitle, action: nil, keyEquivalent: "")
        parent.submenu = sub
        callMenu.addItem(.separator())
        callMenu.addItem(parent)
        keysMenu = sub

        // View › Show Quick Keys
        anchor.isHidden = true
        let toggle = NSMenuItem(title: L.quickKeysShow, action: #selector(togglePanel(_:)), keyEquivalent: "")
        toggle.target = self
        let at = viewMenu.index(of: anchor)
        viewMenu.insertItem(toggle, at: at + 1)
        installedFor = (callMenu, viewMenu)
        return true
    }

    private static func findAnchor(in menu: NSMenu) -> NSMenuItem? {
        for item in menu.items {
            if item.title == L.quickKeysShow, item.target !== self, item.submenu == nil, !item.isSeparatorItem { return item }
            if let sub = item.submenu, let found = findAnchor(in: sub) { return found }
        }
        return nil
    }

    @objc private func pressKey(_ sender: NSMenuItem) { model.pressQuickKey(shortcut: sender.tag, viaMenu: true) }
    @objc private func togglePanel(_ sender: NSMenuItem) { model.toggleQuickKeysPanel() }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(pressKey(_:)):
            item.title = model.quickKeyShortcutTitle(item.tag)
            return model.quickKeyShortcutEnabled(item.tag) && model.quickKeyShortcutsAllowed
        case #selector(togglePanel(_:)):
            item.title = L.quickKeysShow
            item.state = model.quickKeyPanel == .off ? .off : .on
            return true
        default:
            return true
        }
    }
}
