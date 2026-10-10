#if DEBUG
import Foundation
import AppKit
import MacroSIPCore

/// DEBUG-only launch states for screenshots and manual checks:
///   --demo-state first-launch | dialpad | contacts | calllog | connected | calls | incoming | incoming-hidden
///                 | settings-accounts | account-editor | editor-first-launch
/// Data goes to a throw-away directory (see LaunchOptions); the Keychain is never touched.
enum DemoState {
    static let officeID = AccountID(raw: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
    static let homeID = AccountID(raw: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
    static let backupID = AccountID(raw: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!)

    static func seed(stores: (AccountStore, ContactStore, CallLogStore, SettingsStore), vault: PasswordVault) {
        let state = LaunchOptions.current.demoState ?? ""
        if state == "first-launch" || state == "editor-first-launch" { return }
        let (accounts, contacts, log, _) = stores
        let list = [
            AccountConfig(id: officeID, displayName: "Office", username: "1001", domain: "pbx.example.com",
                          transport: .tls, srtp: .mandatory, isDefaultOutgoing: true),
            AccountConfig(id: homeID, displayName: "Home", username: "alex", domain: "sip.provider.net",
                          transport: .udp, srtp: .disabled),
            AccountConfig(id: backupID, displayName: "Backup", username: "2001", domain: "backup.example.net",
                          transport: .tcp, srtp: .optional),
        ]
        for a in list {
            try? accounts.upsert(a)
            try? vault.set(a.id == backupID ? "wrong" : "demo", for: a.id)
        }
        let people: [(String, String)] = [
            ("Anna Petrova", "102"), ("Boris Ivanov", "101"), ("Reception", "100"),
            ("Dmitry Sokolov", "+7 912 555-01-23"), ("Elena Kuznetsova", "sip:elena@example.org"), ("Alex Müller", "+49 30 123456"),
        ]
        for (name, number) in people {
            try? contacts.upsert(Contact(name: name, number: number))
        }
        let now = Date()
        let rows: [(CallDirection, String, String?, AccountID, TimeInterval, TimeInterval)] = [
            (.missed, "101", "Boris Ivanov", officeID, -600, 0),
            (.missed, "+7 912 555-01-23", "Dmitry Sokolov", homeID, -3600, 0),
            (.incoming, "102", "Anna Petrova", officeID, -7200, 254),
            (.outgoing, "100", "Reception", officeID, -20000, 61),
            (.outgoing, "+49 30 123456", nil, homeID, -100_000, 725),
            (.incoming, "sip:elena@example.org", "Elena Kuznetsova", officeID, -190_000, 38),
        ]
        for (dir, number, name, acct, offset, duration) in rows {
            _ = try? log.append(CallLogEntry(direction: dir, remoteNumber: number, remoteDisplayName: name, accountID: acct,
                                         startedAt: now.addingTimeInterval(offset), duration: duration))
        }
    }

    @MainActor
    static func run(_ model: AppModel) async {
        let state = model.launch.demoState ?? ""
        switch model.launch.demoTab {
        case "contacts": model.tab = .contacts
        case "calllog": model.tab = .callLog
        default: break
        }
        switch state {
        case "contacts": model.tab = .contacts
        case "calllog": model.tab = .callLog
        case "connected":
            try? await Task.sleep(for: .seconds(1.5))
            model.placeCall(to: "102")
        case "suggest":
            model.dialText = "an"
        case "keypad":
            try? await Task.sleep(for: .seconds(1.5))
            model.placeCall(to: "102")
            try? await Task.sleep(for: .seconds(3))
            model.showKeypad = true
            for d in "1234" { model.dtmfSent.append(d) }
        case "transfer-banner":
            try? await Task.sleep(for: .seconds(1.5))
            model.placeCall(to: "102")
            try? await Task.sleep(for: .seconds(3))
            if let call = model.activeCall { model.startAttendedTransfer(call, to: "101") }
            try? await Task.sleep(for: .seconds(3))
        case "selftest":
            await selftest(model)
        case "calls":
            try? await Task.sleep(for: .seconds(1.5))
            model.placeCall(to: "102")
            try? await Task.sleep(for: .seconds(3.2))
            model.placeCall(to: "101")
        case "incoming":
            try? await Task.sleep(for: .seconds(1.5))
            simulateIncoming(model)
        case "incoming-hidden":
            try? await Task.sleep(for: .seconds(1.5))
            model.mainWindow?.orderOut(nil)
            try? await Task.sleep(for: .seconds(0.3))
            simulateIncoming(model)
        case "settings-accounts":
            try? await Task.sleep(for: .seconds(1.5))
            model.openSettings(tab: .accounts, account: officeID)
        case "account-editor":
            try? await Task.sleep(for: .seconds(1.5))
            model.openSettings(tab: .accounts, account: officeID)
            try? await Task.sleep(for: .seconds(0.8))
            model.settingsEditor = AccountEditorRequest(accountID: officeID)
        case "editor-first-launch":
            try? await Task.sleep(for: .seconds(1.0))
            model.mainEditor = AccountEditorRequest(accountID: nil)
        case let s where s.hasPrefix("settings-"):
            try? await Task.sleep(for: .seconds(1.5))
            model.openSettings(tab: SettingsTab(rawValue: String(s.dropFirst(9))) ?? .general)
        default: break
        }
        if let prefix = model.launch.snapshotPrefix {
            try? await Task.sleep(for: .seconds(model.launch.snapshotDelay))
            snapshot(prefix: prefix)
        }
    }

    /// Renders every visible window (and attached sheet) of the app into PNG files, in-process.
    @MainActor
    static func snapshot(prefix: String) {
        func save(_ window: NSWindow, name: String) {
            guard let content = window.contentView, let frameView = content.superview else { return }
            let view: NSView = frameView
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            if let data = rep.representation(using: .png, properties: [:]) {
                try? data.write(to: URL(fileURLWithPath: "\(prefix)-\(name).png"))
            }
        }
        let listing = NSApp.windows.map { "\(type(of: $0)) '\($0.title)' visible=\($0.isVisible) frame=\($0.frame) sheet=\(String(describing: $0.attachedSheet))" }
        try? listing.joined(separator: "\n").write(toFile: "\(prefix)-windows.txt", atomically: true, encoding: .utf8)
        var index = 0
        for w in NSApp.windows where w.isVisible && (w.frame.width > 150 || w.title == "Item-0") {
            let name: String
            if w === AppModel.shared.mainWindow { name = "main" }
            else if w is FloatingCallPanel { name = "panel" }
            else if w.styleMask.contains(.titled) { name = "settings"; index += 1 }
            else if NSStringFromClass(type(of: w)) == "NSStatusBarWindow", w.title == "Item-0" {
                name = "statusitem"
                if let menu = StatusItemController.current?.debugMenuTitles() {
                    try? menu.joined(separator: "\n").write(toFile: "\(prefix)-menu.txt", atomically: true, encoding: .utf8)
                }
            }
            else { continue }
            save(w, name: name)
            if let sheet = w.attachedSheet { save(sheet, name: name + "-sheet") }
        }
    }

    /// Drives the model like the views do and checks the resulting state. Result goes to
    /// `<snapshot prefix>-selftest.txt` (or stdout) and the app quits.
    @MainActor
    static func selftest(_ model: AppModel) async {
        var out: [String] = []
        var failures = 0
        func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
            if !ok { failures += 1 }
            out.append("\(ok ? "PASS" : "FAIL") \(name) \(ok ? "" : detail())")
        }
        func wait(_ s: Double) async { try? await Task.sleep(for: .seconds(s)) }
        let mock = model.engine as? MockEngine

        await wait(1.6)
        check("office registered", { if case .registered = model.registration[officeID] ?? .unregistered { return true } else { return false } }())
        check("backup failed 403", { if case .failed(403, _) = model.registration[backupID] ?? .unregistered { return true } else { return false } }(), "\(String(describing: model.registration[backupID]))")

        let logBefore = model.callLog.count
        model.placeCall(to: "100")
        await wait(0.3)
        check("calling state", model.liveCalls.first?.state == .calling, "\(String(describing: model.liveCalls.first?.state))")
        await wait(2.6)
        check("connected after 2s", model.activeCall?.state == .connected)
        check("name resolved from contact", model.currentCall.map { model.name(for: $0.remote) } == "Reception")
        if let c = model.activeCall { model.toggleMute(c) }
        await wait(0.2)
        check("muted", model.currentCall?.isMuted == true)
        if let c = model.activeCall { model.toggleHold(c) }
        await wait(0.2)
        check("held", model.currentCall?.isHeldCall == true && model.activeCall == nil)
        if let c = model.currentCall { model.toggleHold(c) }
        await wait(0.2)
        check("resumed", model.activeCall != nil)

        model.placeCall(to: "101")
        await wait(2.8)
        check("two calls", model.liveCalls.count == 2)
        check("first held, second active", model.liveCalls.first?.isHeldCall == true && model.activeCall?.remote.number == "101")
        if let held = model.liveCalls.first(where: { $0.isHeldCall }) { model.switchTo(held) }
        await wait(0.3)
        check("switch swaps active", model.activeCall?.remote.number == "100" && model.liveCalls.last?.isHeldCall == true)

        // attended transfer of 100 to 102 while 101 is held: consult call then complete
        if let a = model.activeCall { model.startAttendedTransfer(a, to: "102") }
        await wait(2.8)
        check("consult call exists", model.transfer?.consult != nil && model.liveCalls.count == 3, "\(model.liveCalls.count)")
        model.completeTransfer()
        await wait(0.4)
        check("transfer ends both legs", model.liveCalls.count == 1 && model.transfer == nil, "\(model.liveCalls.count)")
        if let c = model.currentCall { model.hangup(c.id) }
        await wait(0.3)
        check("all calls ended", model.calls.isEmpty)
        check("log entries written", model.callLog.count == logBefore + 3, "\(model.callLog.count - logBefore)")
        check("redial target is last outgoing", model.lastDialedNumber != nil)

        // blind transfer
        model.placeCall(to: "100")
        await wait(2.8)
        if let c = model.activeCall { model.blindTransfer(c, to: "102") }
        await wait(1.0)
        check("blind transfer ends call", model.calls.isEmpty)

        // incoming: decline -> missed
        let missedBefore = model.callLog.filter { $0.direction == .missed }.count
        await mock?.simulateIncoming(name: "Test Caller", number: "555", account: officeID)
        await wait(0.3)
        check("incoming shown", model.incomingCall?.remote.number == "555")
        if let c = model.incomingCall { model.decline(c.id) }
        await wait(0.3)
        check("declined call is missed", model.callLog.filter { $0.direction == .missed }.count == missedBefore + 1)
        check("missed badge grows", model.missedUnseen >= 3, "\(model.missedUnseen)")

        // incoming: answer, hold-and-answer second
        await mock?.simulateIncoming(name: nil, number: "556", account: officeID)
        await wait(0.2)
        if let c = model.incomingCall { model.answer(c.id) }
        await wait(0.3)
        check("answered", model.activeCall?.remote.number == "556" && model.incomingCall == nil)
        await mock?.simulateIncoming(name: nil, number: "557", account: officeID)
        await wait(0.2)
        if let c = model.incomingCall { model.holdAndAnswer(c.id) }
        await wait(0.4)
        check("hold & answer", model.activeCall?.remote.number == "557" && model.heldCount == 1)
        await mock?.simulateIncoming(name: nil, number: "558", account: officeID)
        await wait(0.2)
        if let c = model.incomingCall { model.endCurrentAndAnswer(c.id) }
        await wait(0.4)
        check("end current & answer", model.activeCall?.remote.number == "558" && model.liveCalls.count == 2, "\(model.liveCalls.map(\.remote.number))")
        Task { await model.engine.hangupAll() }
        await wait(0.4)

        // DND
        model.toggleDND()
        let m2 = model.callLog.filter { $0.direction == .missed }.count
        await mock?.simulateIncoming(name: nil, number: "559", account: officeID)
        await wait(0.4)
        check("DND rejects", model.calls.isEmpty && model.callLog.filter { $0.direction == .missed }.count == m2 + 1)
        model.toggleDND()
        check("DND persisted off", !model.settingsStore.load().general.doNotDisturb)

        // call limit
        for n in ["200", "201", "202", "203"] { model.placeCall(to: n); await wait(0.15) }
        model.placeCall(to: "204")
        await wait(0.3)
        check("fifth call refused", model.calls.count == 4 && model.banner != nil, "\(model.calls.count)")
        Task { await model.engine.hangupAll() }
        await wait(0.5)

        // account test and save
        var cfg = AccountConfig(displayName: "T", username: "u", domain: "ok.example.com")
        let good = await model.testAccount(cfg, password: "pw")
        check("test account success", { if case .success = good { return true } else { return false } }(), "\(good)")
        let bad = await model.testAccount(cfg, password: "wrong")
        check("test account 403", bad == .failed(code: 403, reason: "Forbidden"), "\(bad)")
        check("test leaves no account", model.accounts.count == 3)
        cfg.isDefaultOutgoing = true
        do { try await model.saveAccount(cfg, password: "pw", callerName: "Me") } catch { check("save account", false, "\(error)") }
        check("account saved", model.accounts.count == 4 && model.callerName(for: cfg.id) == "Me")
        check("default moved", model.accounts.filter(\.isDefaultOutgoing).count == 1 && model.defaultAccount?.id == cfg.id)
        await wait(1.3)
        check("new account registered", { if case .registered = model.registration[cfg.id] ?? .unregistered { return true } else { return false } }())
        await model.deleteAccount(cfg.id)
        check("account deleted", model.accounts.count == 3 && model.vault.password(for: cfg.id) == nil)

        // settings
        model.updateSettings { $0.codecOrder.swapAt(0, 1) }
        check("codec order saved", model.settingsStore.load().codecOrder.first == "G722/16000/1")
        model.updateSettings { $0.enabledCodecs = ["PCMU/8000/1"] }
        check("codec enabled saved", model.orderedEnabledCodecs == ["PCMU/8000/1"])

        // contacts and log
        model.saveContact(Contact(name: "Zed", number: "999"))
        check("contact saved", model.contacts.contains { $0.name == "Zed" })
        check("suggestions by letters", model.suggestions(for: "ze").first?.number == "999")
        if let z = model.contacts.first(where: { $0.name == "Zed" }) { model.deleteContact(z.id) }
        check("contact deleted", !model.contacts.contains { $0.name == "Zed" })
        model.clearCallLog()
        check("log cleared", model.callLog.isEmpty)

        let text = out.joined(separator: "\n") + "\nfailures=\(failures)\n"
        if let prefix = model.launch.snapshotPrefix { try? text.write(toFile: "\(prefix)-selftest.txt", atomically: true, encoding: .utf8) }
        print(text)
        NSApp.terminate(nil)
    }

    @MainActor
    static func simulateIncoming(_ model: AppModel) {
        guard let mock = model.engine as? MockEngine else {
            model.showBanner("Simulate incoming call needs --mock-engine.")
            return
        }
        let acct = model.defaultAccount?.id
        Task { await mock.simulateIncoming(name: "Boris Ivanov", number: "101", account: acct) }
    }
}
#endif
