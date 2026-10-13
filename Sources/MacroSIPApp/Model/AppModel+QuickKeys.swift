import SwiftUI
import AppKit
import MacroSIPCore

/// UI-side state of the quick keys that is not a setting.
@MainActor @Observable
final class QuickKeyRuntime {
    /// Presence keys (`AppModel.presenceKey`) of lines that ring: set from the engine's `.ringing` presence
    /// (`AppModel.handleQuickKeyPresence`) and by `AppModel.setQuickKeyRinging(_:for:)` (demo states).
    var ringing: Set<String> = []
    /// When each ringing line started to ring, for "Ringing · N min".
    var ringingSince: [String: Date] = [:]
    /// Settings › Quick keys: the selected table row (0-based); set by the panel's "Edit…".
    var selectedRow: Int?
    /// Set by "Add key…": the pane selects the first empty row and puts the cursor in its name field.
    var focusNewRow = false
    /// Where "Show Quick Keys" puts the panel after it was switched off.
    var lastPlacement: QuickKeyPanel = .right
    /// Subscriptions this feature holds: key -> URI handed to the engine.
    @ObservationIgnored var subscribed: [UUID: String] = [:]
    /// The call a conference key placed; it is merged as soon as it is answered.
    @ObservationIgnored var pendingConference: CallID?
    @ObservationIgnored var conferenceDialling = false                  // a conference key placed its call and `makeCall` has not returned
    @ObservationIgnored var pendingConferenceStart = Date.distantPast    // when the key was pressed
    @ObservationIgnored var pendingConferenceSeen = false       // the call has shown up in `calls` (the engine's event may lag behind `makeCall`)
    /// The menu bar items (installed once the menus exist).
    @ObservationIgnored var menu: QuickKeysMenu?
    /// Keys pressed so far (the self test and the log read it).
    @ObservationIgnored var pressed: [String] = []

    init() {}
}

extension AppModel {
    // MARK: - The keys

    /// The keys that count: the table may hold blank rows while the user types.
    var quickKeyList: [QuickKey] { settings.quickKeys.keys.filter { !$0.isEmpty } }
    var quickKeyPanel: QuickKeyPanel { settings.quickKeys.show }

    /// ⌘1…⌘9 for the key at `index` of `quickKeyList`.
    func quickKeyShortcut(at index: Int) -> String? {
        QuickKeysSettings.shortcutDigit(at: index).map { "⌘\($0)" }
    }

    /// The established call a transfer or conference key acts on: the active one, else a held one.
    var quickKeyCall: CallInfo? {
        activeCalls.first(where: \.isEstablished) ?? liveCalls.first(where: \.isEstablished)
    }

    /// The connected, not held call a DTMF key sends its digits on.
    var quickKeyDTMFCall: CallInfo? { activeCalls.first(where: \.isEstablished) }

    /// What a press does now, and on which call. nil = the key is dimmed.
    ///  - no call at all: the key's idle action (transfer and conference types: nothing);
    ///  - a connected or held call: the in-call action; digits need a call that is not held;
    ///  - calls that are all still dialling: only a plain Call key works, smart, DTMF, transfer and
    ///    conference keys wait for an answer.
    func quickKeyResolve(_ key: QuickKey) -> (action: QuickKeyAction, call: CallInfo?)? {
        if let call = quickKeyCall {
            let action = key.type.inCallAction
            if action == .sendDigits { return quickKeyDTMFCall.map { (action, $0) } }
            return (action, call)
        }
        if liveCalls.isEmpty { return key.type.idleAction.map { ($0, nil) } }
        return key.type == .call ? (.call, nil) : nil
    }

    // MARK: - State of a key

    /// The URI a BLF key is watched at: its number on the default outgoing account (not the one picked for
    /// the next call in the main window).
    func quickKeyURI(_ key: QuickKey) -> String? {
        guard key.blf, !key.trimmedNumber.isEmpty, let acct = defaultAccount else { return nil }
        return DialString.parse(key.trimmedNumber, account: acct)?.uri
    }

    /// nil = the key has no dot (BLF off).
    func quickKeyState(_ key: QuickKey) -> QuickKeyLineState? {
        guard key.blf, let uri = quickKeyURI(key) else { return key.blf ? .unknown : nil }
        let k = Self.presenceKey(uri)
        return QuickKeyLineState(presence: presence[k], ringing: quickKeys.ringing.contains(k), networkOnline: networkOnline)
    }

    /// Marks the line of `key` as ringing (or not), as a PBX that reports call state would.
    func setQuickKeyRinging(_ on: Bool, for key: QuickKey) {
        guard let uri = quickKeyURI(key) else { return }
        let k = Self.presenceKey(uri)
        if on {
            quickKeys.ringing.insert(k)
            if quickKeys.ringingSince[k] == nil { quickKeys.ringingSince[k] = Date() }
        } else {
            quickKeys.ringing.remove(k)
            quickKeys.ringingSince[k] = nil
        }
    }

    /// A presence event of the engine: `.ringing` lights every key whose URI matches, any other status clears
    /// it. The time it started to ring is kept while the line keeps ringing.
    func handleQuickKeyPresence(uri: String, status: PresenceStatus, note: String?) {
        let k = Self.presenceKey(uri)
        for key in quickKeyList where quickKeyURI(key).map(Self.presenceKey) == k {
            setQuickKeyRinging(status == .ringing, for: key)
        }
        if status != .ringing { quickKeys.ringing.remove(k); quickKeys.ringingSince[k] = nil }
        else if quickKeys.ringingSince[k] == nil { quickKeys.ringingSince[k] = Date() }
    }

    /// "Ringing" with the minutes it has rung once it passes one: the state text of the tooltip.
    func quickKeyStateText(_ key: QuickKey, state: QuickKeyLineState, now: Date = Date()) -> String {
        guard state == .ringing, let uri = quickKeyURI(key), let since = quickKeys.ringingSince[Self.presenceKey(uri)] else {
            return L.quickKeyStateName(state)
        }
        let minutes = Int(now.timeIntervalSince(since) / 60)
        return minutes >= 1 ? L.quickKeysRingingFor(minutes) : L.quickKeyStateName(state)
    }

    /// Dimmed: no enabled account, no number, or nothing the key can do in the present call state.
    func quickKeyEnabled(_ key: QuickKey) -> Bool {
        guard !enabledAccounts.isEmpty, !key.trimmedNumber.isEmpty else { return false }
        if quickKeyState(key) == .ringing { return true }
        return quickKeyResolve(key) != nil
    }

    // MARK: - Pressing

    /// The pickup call of a ringing key: the code and the key's user part on the key's host, built directly.
    func quickKeyPickupDial(_ key: QuickKey) -> DialString? {
        guard quickKeyState(key) == .ringing, let acct = defaultAccount else { return nil }
        return settings.quickKeys.pickupURI(for: key, account: acct)
    }

    /// Places a call from the default outgoing account, as a quick key does (never the account picked in the
    /// main window). An active call goes on hold; what is typed in the number field stays.
    func quickKeyDial(_ make: (AccountConfig) -> DialString?) {
        guard let acct = defaultAccount else { showBanner(L.bannerNoAccount); return }
        guard let dial = make(acct) else { return }
        guard calls.count < 4 else { showBanner(L.bannerTooManyCalls); return }
        run {
            await self.ensureMicrophone()
            for active in self.activeCalls { try await self.engine.setHold(active.id, true) }
            _ = try await self.engine.makeCall(to: dial, from: acct.id)
            self.tab = .dialpad
            self.showKeypad = false
        }
    }

    func pressQuickKey(_ key: QuickKey) {
        guard quickKeyEnabled(key) else { return }
        quickKeys.pressed.append(key.name)
        if let pickup = quickKeyPickupDial(key) { quickKeyDial { _ in pickup }; return }
        let target = key.trimmedNumber
        guard let resolved = quickKeyResolve(key) else { return }
        let call = resolved.call
        switch resolved.action {
        case .call: quickKeyDial { DialString.parse(target, account: $0) }
        case .sendDigits:
            let digits = String(key.dtmfDigits.prefix(32))
            guard !digits.isEmpty, let call else { return }
            dtmfSent.append(digits)
            run { try await self.engine.sendDTMF(call.id, digits) }
        case .blindTransfer: if let call { blindTransfer(call, to: target) }
        case .attendedTransfer: if let call { startAttendedTransfer(call, to: target) }
        case .conference: if let call { startConferenceCall(from: call, to: target) }
        }
    }

    /// ⌘1…⌘9: presses the n-th key of the list (1-based). Nothing for an empty or dimmed key. From the menu
    /// (`viaMenu`) also nothing while a sheet or a panel is the key window or a text field of another window
    /// (Settings) is being edited: the shortcut belongs to that window then.
    func pressQuickKey(shortcut n: Int, viaMenu: Bool = false) {
        let list = quickKeyList
        guard (1...QuickKeysSettings.shortcutCount).contains(n), list.count >= n else { return }
        if viaMenu, !quickKeyShortcutsAllowed { return }
        pressQuickKey(list[n - 1])
    }

    var quickKeyShortcutsAllowed: Bool {
        guard let w = NSApp.keyWindow else { return true }
        if w.attachedSheet != nil || w.sheetParent != nil || w is NSPanel { return false }
        if w !== mainWindow, w.firstResponder is NSText { return false }
        return true
    }

    /// Calls `target` from the account of `call` (the active call goes on hold) and merges the new call into
    /// a conference when it is answered. A second press while the first leg is still unanswered is ignored.
    func startConferenceCall(from call: CallInfo, to target: String) {
        if quickKeys.conferenceDialling { return }
        if let pending = quickKeys.pendingConference,
           calls.contains(where: { $0.id == pending && $0.isLive }) || Date().timeIntervalSince(quickKeys.pendingConferenceStart) < 5 {
            return
        }
        guard let acct = account(call.accountID), let dial = DialString.parse(target, account: acct) else { return }
        guard calls.count < 4 else { showBanner(L.bannerTooManyCalls); return }
        quickKeys.pendingConferenceStart = Date()
        quickKeys.conferenceDialling = true
        run {
            defer { self.quickKeys.conferenceDialling = false }
            for active in self.activeCalls { try await self.engine.setHold(active.id, true) }
            let id = try await self.engine.makeCall(to: dial, from: acct.id)
            self.quickKeys.pendingConferenceSeen = false
            self.quickKeys.pendingConference = id
            self.advanceQuickKeyConference()        // the answer may already be in
        }
    }

    /// Merges the call a conference key placed once it is answered; forgets it when it fails or ends first.
    func advanceQuickKeyConference() {
        guard let id = quickKeys.pendingConference else { return }
        guard let call = calls.first(where: { $0.id == id }) else {
            if quickKeys.pendingConferenceSeen { quickKeys.pendingConference = nil }     // it was there and is gone
            return
        }
        quickKeys.pendingConferenceSeen = true
        if !call.isLive { quickKeys.pendingConference = nil }
        else if call.isEstablished {
            quickKeys.pendingConference = nil
            mergeCalls()
        }
    }

    // MARK: - Panel and settings

    func setQuickKeyPanel(_ panel: QuickKeyPanel) {
        if panel != .off { quickKeys.lastPlacement = panel; prefs.set(panel.rawValue, forKey: "quickKeys.lastPlacement") }
        updateSettings { $0.quickKeys.show = panel }
    }

    /// View › Show Quick Keys and the status bar button.
    func toggleQuickKeysPanel() {
        setQuickKeyPanel(quickKeyPanel == .off ? quickKeys.lastPlacement : .off)
    }

    func openQuickKeysSettings(editing key: QuickKey? = nil, newKey: Bool = false) {
        if let key, let row = settings.quickKeys.keys.firstIndex(where: { $0.id == key.id }) { quickKeys.selectedRow = row }
        if newKey { quickKeys.focusNewRow = true }
        openSettings(tab: .quickKeys)
    }

    func removeQuickKey(_ id: UUID) {
        updateSettings { $0.quickKeys.remove(id) }
    }

    /// Drops blank rows and trims; called when editing ends.
    func normalizeQuickKeys() {
        updateSettings { $0.quickKeys.normalize() }
    }

    // MARK: - BLF subscriptions

    /// Tells the presence registry which targets the keys with BLF on watch: the key's URI on the default
    /// outgoing account. The registry shares a target with the contacts and subscribes it once.
    func syncQuickKeySubscriptions() {
        guard engineReady else { return }
        var desired: [UUID: String] = [:]
        for key in quickKeyList { if let uri = quickKeyURI(key) { desired[key.id] = uri } }
        quickKeys.subscribed = desired
        setPresenceWatches(owner: Self.quickKeysOwner, uris: Array(desired.values))
    }

    /// Starts watching what the keys depend on. Called once at launch.
    func startQuickKeys() {
        let menu = QuickKeysMenu(model: self)
        quickKeys.menu = menu
        menu.install()
        if let raw = prefs.string(forKey: "quickKeys.lastPlacement"), let p = QuickKeyPanel(rawValue: raw), p != .off {
            quickKeys.lastPlacement = p
        } else if settings.quickKeys.show != .off {
            quickKeys.lastPlacement = settings.quickKeys.show
        }
        observeContinuously { [self] in
            // Everything a subscription depends on; reading it registers the change.
            _ = settings.quickKeys.keys
            _ = accounts
            _ = engineReady
            syncQuickKeySubscriptions()
        }
        observeContinuously { [self] in
            _ = calls
            advanceQuickKeyConference()
        }
    }
}

extension AppModel {
    // MARK: - Menu

    /// Title of the ⌘n menu item: the key's name, or "Empty".
    func quickKeyShortcutTitle(_ n: Int) -> String {
        let list = quickKeyList
        return list.count >= n ? list[n - 1].title : L.quickKeysRowEmpty
    }

    func quickKeyShortcutEnabled(_ n: Int) -> Bool {
        let list = quickKeyList
        return list.count >= n && quickKeyEnabled(list[n - 1])
    }
}
