import Foundation
import MacroSIPCore
#if DEBUG
import AppKit

/// Demo states `quick-keys` (panel at the right) and `quick-keys-bottom` (strip under the window), and the
/// quick-key checks of `--demo-state selftest`.
extension DemoState {
    /// Eight keys as in the mockup: Andrei rings, Siarhei is on the phone, Sales queue has no information.
    @MainActor
    static func quickKeysDemo(_ model: AppModel, bottom: Bool) async {
        let russian = Locale.preferredLanguages.first?.hasPrefix("ru") == true
        func pick(_ latin: String, _ cyrillic: String) -> String { russian ? cyrillic : latin }
        let keys: [QuickKey] = [
            QuickKey(name: pick("Reception", "Приёмная"), number: "100", type: .call, blf: true),
            QuickKey(name: DemoPeople.alesia, number: "102", type: .smartBlindTransfer, blf: true),
            QuickKey(name: DemoPeople.andrei, number: "101", type: .call, blf: true),
            QuickKey(name: DemoPeople.siarhei, number: "105", type: .call, blf: true),
            QuickKey(name: pick("Sales queue", "Очередь продаж"), number: "700", type: .blindTransfer, blf: true),
            QuickKey(name: pick("Pickup", "Перехват"), number: "*8", type: .dtmf),
            QuickKey(name: pick("Conference room", "Переговорная"), number: "800", type: .conference),
            QuickKey(name: DemoPeople.volha, number: "103", type: .smartConference, blf: true),
        ]
        if let mock = model.engine as? MockEngine {
            await mock.pinPresence(user: "105", .dnd)
            await mock.pinPresence(user: "700", .offline)
            for user in ["100", "102", "103"] { await mock.pinPresence(user: user, .available) }
            await mock.pinPresence(user: "101", .ringing)       // reaches the key as the engine's ringing presence
        }
        try? await Task.sleep(for: .seconds(1.5))
        model.updateSettings { $0.quickKeys = QuickKeysSettings(show: bottom ? .bottom : .right, keys: keys) }
        try? await Task.sleep(for: .seconds(1.5))
        model.quickKeys.selectedRow = 1
        model.openSettings(tab: .quickKeys)
        try? await Task.sleep(for: .seconds(2))
        if let prefix = model.launch.snapshotPrefix {       // the menu bar as text: View › Show Quick Keys and Call › Quick keys › ⌘1…⌘9
            func dump(_ menu: NSMenu, _ indent: String) -> [String] {
                menu.items.flatMap { item -> [String] in
                    guard !item.isSeparatorItem else { return [] }
                    let key = item.keyEquivalent.isEmpty ? "" : "  [\(item.keyEquivalentModifierMask.contains(.command) ? "⌘" : "")\(item.keyEquivalent)]"
                    let flags = (item.isEnabled ? "" : "  (disabled)") + (item.state == .on ? "  (checked)" : "")
                    return ["\(indent)\(item.title)\(key)\(flags)"] + (item.submenu.map { dump($0, indent + "    ") } ?? [])
                }
            }
            let lines = NSApp.mainMenu.map { dump($0, "") } ?? []
            try? lines.joined(separator: "\n").write(toFile: "\(prefix)-mainmenu.txt", atomically: true, encoding: .utf8)
        }
    }

    @MainActor
    static func quickKeysSelftest(_ model: AppModel, mock: MockEngine?, check: (String, Bool, String) -> Void) async {
        func wait(_ s: Double) async { try? await Task.sleep(for: .seconds(s)) }
        func numbers() -> [String] { model.liveCalls.map(\.remote.number) }
        func clearCalls() async { await model.engine.hangupAll(); await wait(0.5) }
        await clearCalls()
        model.updateSettings { $0.callOptions = CallOptions() }

        let reception = QuickKey(name: "Reception", number: "100", type: .smartBlindTransfer)
        let pickup = QuickKey(name: "Pickup", number: "*8", type: .dtmf)
        let sales = QuickKey(name: "Sales", number: "700", type: .blindTransfer)
        let andrei = QuickKey(name: "Andrei", number: "101", type: .call, blf: true)       // a contact also watches 101
        let room = QuickKey(name: "Room", number: "800", type: .conference)
        let smartConf = QuickKey(name: "Smart conference", number: "102", type: .smartConference)
        let smartAtt = QuickKey(name: "Smart attended", number: "103", type: .smartAttendedTransfer)
        model.updateSettings { $0.quickKeys = QuickKeysSettings(show: .off, keys: [reception, pickup, sales, andrei, room, smartConf, smartAtt]) }
        await wait(0.3)
        check("quick keys: shortcuts follow the list", model.quickKeyList.map(\.name).first == "Reception" && model.quickKeyShortcut(at: 0) == "⌘1"
              && model.quickKeyShortcut(at: 8) == "⌘9" && model.quickKeyShortcut(at: 9) == nil, "")
        check("quick keys: stored in settings", model.settingsStore.load().quickKeys.keys.count == 7, "")

        // idle: transfer and conference keys are dimmed and do nothing; a plain call key and DTMF dial
        check("quick keys: transfer key dimmed with no call", !model.quickKeyEnabled(sales) && !model.quickKeyEnabled(room), "")
        check("quick keys: smart and DTMF keys enabled with no call", model.quickKeyEnabled(reception) && model.quickKeyEnabled(pickup), "")
        model.pressQuickKey(shortcut: 3)
        model.pressQuickKey(shortcut: 5)
        await wait(0.3)
        check("quick keys: dimmed keys place no call", model.calls.isEmpty, "\(numbers())")
        model.pressQuickKey(shortcut: 8)        // beyond the list
        model.pressQuickKey(shortcut: 12)       // out of range
        await wait(0.2)
        check("quick keys: a shortcut beyond the list does nothing", model.calls.isEmpty, "\(numbers())")

        // the menu follows the keys that were set a moment ago, and ⌘1 pressed in it works
        let callMenu = NSApp.mainMenu?.items.first { $0.title == L.menuCall }?.submenu
        let keysMenu = callMenu?.items.last { $0.title == L.quickKeysTitle }?.submenu
        keysMenu?.update()                      // what AppKit does when the menu opens or a key equivalent is looked up
        let firstItem = keysMenu?.items.first
        check("quick keys: the menu lists the new keys and enables ⌘1", firstItem?.title == "Reception" && firstItem?.keyEquivalent == "1"
              && firstItem?.isEnabled == true && keysMenu?.items.count == 9 && keysMenu?.items[2].isEnabled == false,
              "\(String(describing: firstItem?.title)) \(String(describing: firstItem?.isEnabled))")
        let command1 = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: ProcessInfo.processInfo.systemUptime,
                                        windowNumber: model.mainWindow?.windowNumber ?? 0, context: nil, characters: "1",
                                        charactersIgnoringModifiers: "1", isARepeat: false, keyCode: 18)
        let handled = command1.map { NSApp.mainMenu?.performKeyEquivalent(with: $0) ?? false } ?? false
        await wait(0.4)
        check("quick keys: ⌘1 in the menu presses key 1 (smart: calls when idle)", handled && numbers() == ["100"], "\(handled) \(numbers())")
        await wait(2.6)
        check("quick keys: call connected", model.activeCall?.state == .connected, "")
        check("quick keys: transfer and conference keys enabled in a call", model.quickKeyEnabled(sales) && model.quickKeyEnabled(room), "")

        // in a call: DTMF sends digits on the call and dials nothing
        let sentBefore = await mock?.dtmfSent.count ?? 0
        model.pressQuickKey(shortcut: 2)
        await wait(0.3)
        let sent = await mock?.dtmfSent ?? []
        check("quick keys: DTMF key sends its digits on the call", sent.count == sentBefore + 1 && sent.last == "*8" && numbers() == ["100"],
              "\(sent) \(numbers())")

        // in a call: blind transfer key hands the call over at once
        model.pressQuickKey(shortcut: 3)
        await wait(1.2)
        check("quick keys: blind transfer key transfers the active call", model.calls.isEmpty, "\(numbers())")

        // idle: DTMF dials its digits as a number
        model.pressQuickKey(shortcut: 2)
        await wait(0.4)
        check("quick keys: DTMF key dials its digits when idle", numbers() == ["*8"], "\(numbers())")
        await clearCalls()

        // smart conference: calls, then on a call holds it, calls the number and merges when answered
        model.pressQuickKey(shortcut: 6)
        await wait(3.0)
        check("quick keys: smart conference key calls when idle", numbers() == ["102"] && model.activeCall != nil, "\(numbers())")
        model.pressQuickKey(shortcut: 5)        // conference key: calls 800 from the account of the active call
        model.pressQuickKey(shortcut: 5)        // a second press before the first leg is answered is ignored
        await wait(0.4)
        check("quick keys: a second conference press while the first leg rings is ignored", numbers().filter { $0 == "800" }.count == 1, "\(numbers())")
        check("quick keys: conference key holds the call and dials the number", numbers().contains("800") && model.heldCount == 1, "\(numbers())")
        for _ in 0..<20 where model.conferenceCalls.count < 2 { await wait(0.5) }
        check("quick keys: conference key merges the new call when answered",
              model.conferenceCalls.count == 2 && model.quickKeys.pendingConference == nil, "\(model.conferenceCalls.count) \(String(describing: model.quickKeys.pendingConference))")
        await clearCalls()

        // smart attended transfer in a call starts the consultation call
        model.pressQuickKey(shortcut: 1)
        await wait(3.0)
        model.pressQuickKey(shortcut: 7)
        await wait(3.0)
        check("quick keys: smart attended key starts an attended transfer", model.transfer?.consult != nil && model.liveCalls.count == 2, "\(numbers())")
        model.cancelTransfer()
        await wait(0.5)
        await clearCalls()

        // dialling and held calls: smart, DTMF, transfer and conference keys wait for a connected call
        model.placeCall(to: "100")
        await wait(0.3)
        check("quick keys: while the only call is still dialling smart, DTMF, transfer and conference keys are dimmed, Call is not",
              !model.quickKeyEnabled(reception) && !model.quickKeyEnabled(pickup) && !model.quickKeyEnabled(sales) && !model.quickKeyEnabled(room)
              && !model.quickKeyEnabled(smartConf) && model.quickKeyEnabled(andrei), "")
        let dialling = model.calls.count
        model.pressQuickKey(shortcut: 1)
        model.pressQuickKey(shortcut: 6)
        await wait(0.3)
        check("quick keys: a dimmed smart key places no second call", model.calls.count == dialling, "\(numbers())")
        await wait(2.6)
        if let c = model.activeCall { model.toggleHold(c) }
        await wait(0.4)
        let digitsBefore = await mock?.dtmfSent.count ?? 0
        check("quick keys: with only a held call the DTMF key is dimmed, smart keys are not", model.heldCount == 1 && model.activeCall == nil
              && !model.quickKeyEnabled(pickup) && model.quickKeyEnabled(reception), "\(model.heldCount)")
        model.pressQuickKey(shortcut: 2)
        await wait(0.4)
        let digitsAfter = await mock?.dtmfSent.count ?? 0
        check("quick keys: the DTMF key does nothing with only a held call", digitsAfter == digitsBefore && numbers().count == 1, "\(digitsBefore) \(digitsAfter) \(numbers())")
        await clearCalls()

        // BLF: one subscription per key URI, shared with the contact that watches the same number
        let uri = model.quickKeyURI(andrei)
        check("quick keys: BLF key has a URI on the outgoing account", uri?.hasPrefix("sip:101@") == true, "\(String(describing: uri))")
        await wait(1.8)
        let presenceKey = uri.map(AppModel.presenceKey) ?? ""
        check("quick keys: BLF key subscribed and has a state", model.quickKeys.subscribed[andrei.id] == uri && model.presence[presenceKey] != nil
              && model.quickKeyState(andrei) == .available, "\(String(describing: model.quickKeyState(andrei)))")
        check("quick keys: a key without BLF has no dot", model.quickKeyState(reception) == nil, "")
        let contactWatchesIt = model.contact(forNumber: "101")?.subscribePresence == true
        check("quick keys: a key and a contact with one number share one watch",
              !contactWatchesIt || model.presenceRegistry.owners(of: uri ?? "") == [AppModel.contactsOwner, AppModel.quickKeysOwner],
              "\(model.presenceRegistry.owners(of: uri ?? ""))")

        // BLF follows the default outgoing account, not the one picked for the next call; keys call from the default account
        let homeBefore = model.selectedAccountID
        model.selectedAccountID = homeID
        await wait(0.5)
        check("quick keys: picking another account does not move the BLF subscription", model.quickKeyURI(andrei) == uri
              && model.quickKeys.subscribed[andrei.id] == uri, "\(String(describing: model.quickKeyURI(andrei)))")
        model.pressQuickKey(shortcut: 4)
        await wait(0.4)
        check("quick keys: a key calls from the default account, not the picked one", model.liveCalls.first?.accountID == officeID && numbers() == ["101"],
              "\(String(describing: model.liveCalls.first?.accountID)) \(numbers())")
        model.selectedAccountID = homeBefore
        await clearCalls()

        // the engine's `.ringing` presence lights the key, any other status clears it (the mock sends what it is pinned to
        // when the target is subscribed: an unwatched number, so the key is its only owner)
        let ring = QuickKey(name: "Ring", number: "109", type: .call, blf: true)
        await mock?.pinPresence(user: "109", .ringing)
        model.updateSettings { $0.quickKeys.add(ring) }
        await wait(1.8)
        let ringKey = model.quickKeyURI(ring).map(AppModel.presenceKey) ?? ""
        check("quick keys: a .ringing presence event lights the key", model.quickKeyState(ring) == .ringing
              && model.quickKeys.ringingSince[ringKey] != nil, "\(String(describing: model.quickKeyState(ring))) \(String(describing: model.presence[ringKey]))")
        check("quick keys: pickup URI is the code and the user part on the key's host", model.quickKeyPickupDial(ring)?.uri == "sip:*8109@pbx.example.com;transport=tls"
              && model.quickKeyPickupDial(ring)?.display == "*8109", "\(String(describing: model.quickKeyPickupDial(ring)?.uri))")
        check("quick keys: a line that rings for a moment shows plain Ringing", model.quickKeyStateText(ring, state: .ringing) == L.quickKeysBlfRinging, "")
        model.quickKeys.ringingSince[ringKey] = Date().addingTimeInterval(-185)
        check("quick keys: a line that rings for 3 minutes shows Ringing · 3 min",
              model.quickKeyStateText(ring, state: .ringing) == L.quickKeysRingingFor(3), model.quickKeyStateText(ring, state: .ringing))
        await mock?.pinPresence(user: "109", .available)
        let ringIndex = model.settings.quickKeys.keys.firstIndex { $0.id == ring.id } ?? 0
        model.updateSettings { $0.quickKeys.keys[ringIndex].blf = false }
        await wait(0.3)
        check("quick keys: the last owner gone unsubscribes the target", !model.presenceRegistry.isWatched("sip:109@pbx.example.com") && model.presence[ringKey] == nil, "")
        model.updateSettings { $0.quickKeys.keys[ringIndex].blf = true }
        await wait(1.8)
        check("quick keys: an .available presence event clears it", model.quickKeyState(ring) == .available
              && !model.quickKeys.ringing.contains(ringKey) && model.quickKeys.ringingSince[ringKey] == nil,
              "\(String(describing: model.quickKeyState(ring)))")
        model.removeQuickKey(ring.id)
        await wait(0.3)
        // a key that is a SIP URI: the code goes before its user part, the host stays
        let alice = QuickKey(name: "Alice", number: "sip:alice@pbx.example.com", type: .call, blf: true)
        check("quick keys: pickup URI of a key that is a SIP URI",
              model.defaultAccount.flatMap { model.settings.quickKeys.pickupURI(for: alice, account: $0)?.uri } == "sip:*8alice@pbx.example.com;transport=tls", "")

        // ringing (reported through the seam) shows orange and the click dials pickup code + number
        model.setQuickKeyRinging(true, for: andrei)
        check("quick keys: ringing state", model.quickKeyState(andrei) == .ringing, "")
        check("quick keys: pickup URI is code + number", model.quickKeyPickupDial(andrei)?.uri == "sip:*8101@pbx.example.com;transport=tls", "\(String(describing: model.quickKeyPickupDial(andrei)?.uri))")
        model.pressQuickKey(shortcut: 4)
        await wait(0.4)
        check("quick keys: a click on a ringing key dials the pickup string", numbers() == ["*8101"], "\(numbers())")
        await clearCalls()
        model.setQuickKeyRinging(false, for: andrei)
        check("quick keys: ringing cleared", model.quickKeyState(andrei) == .available, "")

        model.updateSettings { $0.quickKeys.keys[3].blf = false }
        await wait(0.4)
        check("quick keys: BLF off drops the key's subscription", model.quickKeys.subscribed[andrei.id] == nil, "")
        check("quick keys: a contact's subscription to the same number stays", !contactWatchesIt || model.presence[presenceKey] != nil,
              "\(String(describing: model.presence[presenceKey]))")
        model.updateSettings { $0.quickKeys.keys[3].blf = true }
        await wait(0.3)
        model.removeQuickKey(andrei.id)
        await wait(0.4)
        check("quick keys: removing a key drops its subscription", model.quickKeys.subscribed.isEmpty && model.quickKeyList.count == 6, "")

        // the window follows the panel: 340 wide with none, 560 with the column, 92 pt taller with the strip
        func contentSize() -> NSSize { model.mainWindow.map { $0.contentRect(forFrameRect: $0.frame).size } ?? .zero }
        if model.mainWindow != nil {
            model.setQuickKeyPanel(.off)
            await wait(0.8)
            let base = contentSize()         // the content view includes the title bar: 340 wide, 520 + title bar tall
            check("quick keys: no panel, the window is 340 pt wide", base.width == 340 && base.height >= 520, "\(base)")
            model.setQuickKeyPanel(.right)
            await wait(0.8)
            var size = contentSize()
            check("quick keys: the right panel widens the window to 560 pt", size.width == 560 && size.height == base.height, "\(size) \(base)")
            model.setQuickKeyPanel(.bottom)
            await wait(0.8)
            size = contentSize()
            check("quick keys: the bottom panel adds height and no width", size.width == 340 && size.height == base.height + QuickKeysPanel.dockHeight, "\(size) \(base)")
            model.setQuickKeyPanel(.off)
            await wait(0.8)
            size = contentSize()
            check("quick keys: hiding the panel restores the window", size == base, "\(size) \(base)")
        }

        // panel toggle
        model.setQuickKeyPanel(.bottom)
        model.toggleQuickKeysPanel()
        check("quick keys: toggle hides the panel", model.quickKeyPanel == .off, "")
        model.toggleQuickKeysPanel()
        check("quick keys: toggle shows it where it was", model.quickKeyPanel == .bottom, "")
        model.updateSettings { $0.quickKeys = QuickKeysSettings() }
        await wait(0.2)
    }
}
#endif
