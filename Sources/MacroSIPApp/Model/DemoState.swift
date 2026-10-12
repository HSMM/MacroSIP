#if DEBUG
import Foundation
import AppKit
import MacroSIPCore

/// DEBUG-only launch states for screenshots and manual checks:
///   --demo-state first-launch | dialpad | contacts | calllog | connected | calls | incoming | incoming-hidden
///                 | conference | recording | autoAnswer | settings-recording | settings-autoanswer
///                 | account-popup | settings-accounts | account-editor | editor-first-launch
/// Data goes to a throw-away directory (see LaunchOptions); the Keychain is never touched.
enum DemoState {
    static let officeID = AccountID(raw: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
    static let homeID = AccountID(raw: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
    static let backupID = AccountID(raw: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!)
    static let labID = AccountID(raw: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!)

    static func seed(stores: (AccountStore, ContactStore, CallLogStore, SettingsStore), vault: PasswordVault) {
        let state = LaunchOptions.current.demoState ?? ""
        if state == "first-launch" || state == "editor-first-launch" { return }
        let (accounts, contacts, log, _) = stores
        var list = [
            AccountConfig(id: officeID, displayName: "Office", username: "1001", domain: "pbx.example.com",
                          transport: .tls, srtp: .mandatory, isDefaultOutgoing: true),
            AccountConfig(id: homeID, displayName: "Home", username: "alex", domain: "sip.provider.net",
                          transport: .udp, srtp: .disabled),
            AccountConfig(id: backupID, displayName: "Backup", username: "2001", domain: "backup.example.net",
                          transport: .tcp, srtp: .optional),
        ]
        if state.hasPrefix("account-popup") {       // the four accounts of the mockup (screen 1, Account pop-up)
            list = [
                AccountConfig(id: officeID, displayName: "Office", username: "alex", domain: "pbx.example.com",
                              transport: .tls, srtp: .mandatory, isDefaultOutgoing: true),
                AccountConfig(id: homeID, displayName: "Home", username: "7741", domain: "sip.example.net"),
                AccountConfig(id: backupID, displayName: "Backup", username: "alex", domain: "voip.example.org"),
                AccountConfig(id: labID, displayName: "Lab", username: "test", domain: "10.0.0.5", enabled: false),
            ]
        }
        for a in list {
            try? accounts.upsert(a)
            try? vault.set(a.id == backupID ? "wrong" : "demo", for: a.id)
        }
        let people: [(String, String)] = [
            ("Anna Petrova", "102"), ("Boris Ivanov", "101"), ("Reception", "100"),
            ("Dmitry Sokolov", "+7 912 555-01-23"), ("Elena Kuznetsova", "sip:elena@example.org"), ("Alex Müller", "+49 30 123456"),
        ]
        let watched: Set<String> = ["Anna Petrova", "Boris Ivanov", "Dmitry Sokolov", "Reception"]
        for (name, number) in people {
            try? contacts.upsert(Contact(name: name, number: number, subscribePresence: watched.contains(name)))
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
        case "quit":                // checks that quitting finishes (shutdown must not hang)
            try? await Task.sleep(for: .seconds(2))
            quitLater()
        case "calls":
            try? await Task.sleep(for: .seconds(1.5))
            model.placeCall(to: "102")
            try? await Task.sleep(for: .seconds(3.2))
            model.placeCall(to: "101")
        case "conference":
            try? await Task.sleep(for: .seconds(1.5))
            model.placeCall(to: "102")
            try? await Task.sleep(for: .seconds(3.2))
            model.placeCall(to: "101")
            try? await Task.sleep(for: .seconds(3.2))
            model.mergeCalls()
        case "recording":
            try? await Task.sleep(for: .seconds(1.5))
            model.placeCall(to: "102")
            try? await Task.sleep(for: .seconds(3.2))
            if let c = model.activeCall { model.toggleRecording(c) }
        case "autoAnswer":
            try? await Task.sleep(for: .seconds(1.0))
            model.updateSettings { $0.autoAnswer = AutoAnswerSettings(mode: .all, delaySeconds: 20, honourCallInfo: true) }
            try? await Task.sleep(for: .seconds(0.5))
            simulateIncoming(model)
        case "incoming":
            try? await Task.sleep(for: .seconds(1.5))
            simulateIncoming(model)
        case "incoming-hidden":
            try? await Task.sleep(for: .seconds(1.5))
            model.mainWindow?.orderOut(nil)
            try? await Task.sleep(for: .seconds(0.3))
            simulateIncoming(model)
        case "account-popup":       // the snapshot below also renders the open pop-up
            try? await Task.sleep(for: .seconds(1.5))
        case "account-popup-live":  // opens the real menu and drives its rows with timers
            try? await Task.sleep(for: .seconds(1.5))
            liveAccountPopup(model)
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
            let name = String(s.dropFirst(9)).lowercased()
            model.openSettings(tab: SettingsTab.allCases.first { $0.rawValue.lowercased() == name } ?? .general)
        default: break
        }
        if let prefix = model.launch.snapshotPrefix {
            try? await Task.sleep(for: .seconds(model.launch.snapshotDelay))
            snapshot(prefix: prefix)
            if state == "account-popup" { snapshotAccountPopup(prefix: prefix, model: model) }
        }
    }

    /// Opens the real pop-up and checks, while it is open: the switch of "Lab" does not close the menu and
    /// enables the account; picking "Home" selects it and closes the menu. Writes `<prefix>-live.txt`.
    @MainActor
    static func liveAccountPopup(_ model: AppModel) {
        guard let anchor = model.mainWindow?.contentView else { return }
        let popup = AccountPopupMenu(model: model)
        var out: [String] = []
        var returned = false
        func add(_ delay: TimeInterval, _ body: @escaping @MainActor () -> Void) {
            let t = Timer(timeInterval: delay, repeats: false) { _ in MainActor.assumeIsolated { body() } }
            RunLoop.main.add(t, forMode: .common)
        }
        add(0.8) {
            out.append("rows=\(popup.rows.count)")
            popup.rows.first { $0.accountID == labID }?.toggle.performClick(nil)
        }
        add(2.2) {
            out.append("menu still open after the switch: \(!returned)")
            out.append("lab enabled in model: \(model.account(labID)?.enabled == true)")
            out.append("lab in engine: \(model.engineAccounts.contains(labID))")
            out.append("lab registration: \(String(describing: model.registration[labID]))")
            if let r = popup.rows.first(where: { $0.accountID == homeID }) { r.onPick?(r.accountID) }
        }
        popup.show(from: anchor)
        returned = true
        out.append("menu closed after pick: true; outgoing = \(model.effectiveAccount?.displayName ?? "-")")
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            out.append("after close: lab in engine \(model.engineAccounts.contains(labID)), registration \(String(describing: model.registration[labID]))")
            if let prefix = model.launch.snapshotPrefix {
                try? out.joined(separator: "\n").write(toFile: "\(prefix)-live.txt", atomically: true, encoding: .utf8)
            }
        }
    }

    /// An open NSMenu is not part of any window, so the pop-up is rendered from its own row views
    /// and drawn over the main-window snapshot at the position of the mockup.
    @MainActor
    static func snapshotAccountPopup(prefix: String, model: AppModel) {
        let menu = AccountPopupMenu(model: model).build()
        let pad: CGFloat = 5
        let items = menu.items
        func height(_ item: NSMenuItem) -> CGFloat { item.view?.frame.height ?? (item.isSeparatorItem ? 9 : 22) }
        let total = items.reduce(pad * 2) { $0 + height($1) }
        // Each row is rendered on its own and drawn at its place in the menu.
        func render(_ v: NSView) -> NSImage {
            v.layoutSubtreeIfNeeded()
            let image = NSImage(size: v.bounds.size)
            if let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                v.cacheDisplay(in: v.bounds, to: rep)
                image.addRepresentation(rep)
            }
            return image
        }
        let size = NSSize(width: AccountPopupMenu.width + pad * 2, height: total)
        var pieces: [(NSImage, NSRect)] = []
        var y = total - pad
        for item in items {
            let h = height(item)
            y -= h
            if let v = item.view {
                pieces.append((render(v), NSRect(x: pad, y: y, width: v.bounds.width, height: h)))
            } else {
                let host = NSView(frame: NSRect(x: 0, y: 0, width: AccountPopupMenu.width, height: h))
                if item.isSeparatorItem {
                    let line = NSBox(frame: NSRect(x: 9, y: 4, width: AccountPopupMenu.width - 18, height: 1))
                    line.boxType = .separator
                    host.addSubview(line)
                } else {
                    let label = NSTextField(labelWithString: item.title)
                    label.font = .menuFont(ofSize: 13)
                    label.frame = NSRect(x: 9 + 12 + 8, y: 3, width: 160, height: 16)
                    host.addSubview(label)
                    let sc = NSTextField(labelWithString: "⌘,")
                    sc.font = .menuFont(ofSize: 13); sc.textColor = .secondaryLabelColor
                    sc.frame = NSRect(x: AccountPopupMenu.width - 49, y: 3, width: 40, height: 16)
                    sc.alignment = .right
                    host.addSubview(sc)
                }
                pieces.append((render(host), NSRect(x: pad, y: y, width: host.bounds.width, height: h)))
            }
        }
        // Compose over the main window (menu top at 61 pt from the top, left at 10 pt, as in the mockup).
        let mainURL = URL(fileURLWithPath: "\(prefix)-main.png")
        guard let base = NSImage(contentsOf: mainURL), let baseRep = base.representations.first else { return }
        let w = baseRep.pixelsWide, h = baseRep.pixelsHigh
        guard let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: out) else { return }
        let sx = CGFloat(w) / base.size.width
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        base.draw(in: NSRect(x: 0, y: 0, width: w, height: h))
        let menuRect = NSRect(x: (10 - pad) * sx, y: CGFloat(h) - (61 - pad + size.height) * sx,
                              width: size.width * sx, height: size.height * sx)
        let bubble = NSBezierPath(roundedRect: menuRect.insetBy(dx: pad * sx, dy: pad * sx), xRadius: 9 * sx, yRadius: 9 * sx)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
        shadow.shadowBlurRadius = 18 * sx
        shadow.shadowOffset = NSSize(width: 0, height: -6 * sx)
        shadow.set()
        NSColor.windowBackgroundColor.setFill()
        bubble.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSColor.separatorColor.setStroke()
        bubble.lineWidth = 0.5 * sx
        bubble.stroke()
        for (img, rect) in pieces {
            img.draw(in: NSRect(x: menuRect.minX + rect.minX * sx, y: menuRect.minY + rect.minY * sx,
                                width: rect.width * sx, height: rect.height * sx))
        }
        NSGraphicsContext.restoreGraphicsState()
        if let data = out.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: "\(prefix)-popup.png"))
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


        // presence: watched contacts get a status, unwatching drops it
        let watchedContacts = model.contacts.filter(\.subscribePresence)
        check("presence arrives for watched contacts", !watchedContacts.isEmpty && watchedContacts.allSatisfy { model.presenceStatus(for: $0) != nil },
              "\(model.presence)")
        if let anna = model.contacts.first(where: { $0.name == "Anna Petrova" }) {
            let subs = model.presenceSubscriptions.count
            model.setWatchPresence(false, for: anna)
            check("unwatch unsubscribes", model.presenceSubscriptions.count == subs - 1 && model.presenceStatus(for: anna) == nil)
            model.setWatchPresence(true, for: anna)
            await wait(1.2)
            check("watch subscribes again", model.presenceSubscriptions.count == subs && model.contacts.first { $0.id == anna.id }.flatMap(model.presenceStatus(for:)) != nil)
        }
        if let z = Optional(Contact(name: "Zzz", number: "888", subscribePresence: true)) {
            model.saveContact(z)
            let n = model.presenceSubscriptions.count
            model.deleteContact(z.id)
            check("delete unsubscribes", model.presenceSubscriptions.count == n - 1)
        }

        // my status and publish
        if var office = model.account(officeID) {
            office.publishPresence = true
            do { try await model.saveAccount(office, password: "demo", callerName: "") } catch { check("save publish flag", false, "\(error)") }
            model.setMyStatus(.away)
            await wait(0.3)
            var published = await mock?.publishedPresence[officeID]
            check("away published", published == .away && !model.doNotDisturb)
            model.setMyStatus(.dnd)
            await wait(0.3)
            published = await mock?.publishedPresence[officeID]
            check("My Status DND turns DND on and publishes dnd", model.doNotDisturb && published == .dnd)
            model.toggleDND()
            check("DND off restores the status from before (Away stays Away)", !model.doNotDisturb && model.settings.general.presenceStatus == .away,
                  "\(model.settings.general.presenceStatus)")
            await wait(0.3)
            published = await mock?.publishedPresence[officeID]
            check("away published again", published == .away)
            model.toggleDND()
            check("DND on sets status dnd", model.doNotDisturb && model.settings.general.presenceStatus == .dnd)
            model.toggleDND()
            model.setMyStatus(.available)
            check("status persisted", model.settingsStore.load().general.presenceStatus == .available && !model.doNotDisturb)
        }

        // conference, split, recording
        model.placeCall(to: "300")
        await wait(2.8)
        model.placeCall(to: "301")
        await wait(2.8)
        check("merge enabled with two connected calls", model.liveCalls.count == 2 && model.canMerge, "\(model.liveCalls.count)")
        model.mergeCalls()
        await wait(0.3)
        check("merged into a conference", model.conferenceCalls.count == 2 && model.activeCalls.count == 2 && !model.canMerge)
        // a conference is held and resumed as one unit
        if let leg = model.conferenceCalls.first {
            model.toggleHold(leg)
            await wait(0.4)
            check("holding a conference holds every leg", model.conferenceCalls.count == 2 && model.conferenceCalls.allSatisfy(\.isHeldCall))
            if let held = model.conferenceCalls.last { model.switchTo(held) }
            await wait(0.4)
            check("resuming one leg resumes the whole conference",
                  model.conferenceCalls.count == 2 && model.conferenceCalls.allSatisfy { !$0.isHeldCall } && model.activeCalls.count == 2)
        }
        if let c = model.conferenceCalls.first {
            let savedBefore = model.savedRecordings.count
            model.toggleRecording(c)
            await wait(0.4)
            let recorded = model.conferenceCalls.filter(\.isRecording)
            check("conference records one leg, the lowest serial", recorded.count == 1
                  && recorded.first?.id.serial == model.conferenceCalls.map(\.id.serial).min() && model.isRecording(c))
            model.toggleRecording(model.conferenceCalls.last ?? c)
            await wait(1.5)
            check("stopping a conference recording stops that one file",
                  model.conferenceCalls.allSatisfy { !$0.isRecording } && model.savedRecordings.count == savedBefore + 1)
            model.split(c)
        }
        await wait(0.3)
        check("split dissolves a two-party conference", model.conferenceCalls.isEmpty && model.heldCount == 1, "\(model.conferenceCalls.count)")
        let saved = model.savedRecordings.count
        let tempRecordings = FileManager.default.temporaryDirectory.appendingPathComponent("MacroSIP-Recording")
        let wavsBefore = Set((try? FileManager.default.contentsOfDirectory(atPath: tempRecordings.path))?.filter { $0.hasSuffix(".wav") } ?? [])
        if let c = model.activeCall { model.toggleRecording(c) }
        await wait(0.3)
        check("recording starts", model.activeCall?.isRecording == true && model.activeCall.flatMap { model.recordingSince[$0.id] } != nil)
        await wait(1.1)
        if let c = model.activeCall { model.toggleRecording(c) }
        await wait(1.5)
        check("recording stopped and converted", model.savedRecordings.count == saved + 1 && model.activeCall?.isRecording == false,
              "\(model.savedRecordings.count) \(String(describing: model.banner?.text))")
        if let url = model.savedRecordings.last {
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            check("m4a is in the recordings folder and named per 8.6",
                  size > 1024 && url.deletingLastPathComponent() == model.recordingFolderURL.standardizedFileURL
                  && url.lastPathComponent.hasSuffix("(out).m4a"), "\(url.path) \(size)")
        }
        if let c = model.activeCall { model.toggleRecording(c) }      // recording a second time, ended by the hang-up
        await wait(0.3)
        Task { await model.engine.hangupAll() }
        await wait(1.5)
        check("ending a recorded call converts it", model.savedRecordings.count == saved + 2, "\(model.savedRecordings.count)")
        let wavsAfter = Set((try? FileManager.default.contentsOfDirectory(atPath: tempRecordings.path))?.filter { $0.hasSuffix(".wav") } ?? [])
        check("temporary WAVs are deleted", wavsAfter.subtracting(wavsBefore).isEmpty, "\(wavsAfter.subtracting(wavsBefore))")

        // stereo layout: two one-channel WAVs become one M4A and none stays behind
        model.updateSettings { $0.recording.layout = .stereoSplit }
        model.placeCall(to: "305")
        await wait(2.8)
        if let c = model.activeCall { model.toggleRecording(c) }
        await wait(0.3)
        var stereoFiles = model.activeCall.flatMap { model.recordingJobs[$0.id]?.files }
        check("stereo recording writes a local and a remote WAV", stereoFiles?.layout == .stereoSplit
              && stereoFiles?.mixed == nil && stereoFiles?.local != nil && stereoFiles?.remote != nil
              && stereoFiles?.all.allSatisfy { FileManager.default.fileExists(atPath: $0.path) } == true,
              "\(String(describing: stereoFiles))")
        await wait(1.1)
        if let c = model.activeCall { model.toggleRecording(c) }
        await wait(1.5)
        check("stereo recording is converted to one m4a", model.savedRecordings.count == saved + 3
              && model.savedRecordings.last.map { FileManager.default.fileExists(atPath: $0.path) } == true, "\(model.savedRecordings.count)")
        check("stereo WAVs are deleted", stereoFiles?.all.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) } == true)
        stereoFiles = nil
        Task { await model.engine.hangupAll() }
        await wait(0.8)
        model.updateSettings { $0.recording.layout = .mono }

        // record all calls
        model.updateSettings { $0.recording.recordAllCalls = true }
        model.placeCall(to: "302")
        await wait(2.8)
        check("record-all starts recording on connect", model.activeCall?.isRecording == true)
        Task { await model.engine.hangupAll() }
        await wait(1.5)
        model.updateSettings { $0.recording.recordAllCalls = false }
        check("record-all call was saved", model.savedRecordings.count == saved + 4, "\(model.savedRecordings.count)")

        // record-all with a merge: the conference keeps one recording
        model.updateSettings { $0.recording.recordAllCalls = true }
        model.placeCall(to: "303")
        await wait(2.8)
        model.placeCall(to: "304")
        await wait(2.8)
        check("both calls record on connect", model.liveCalls.filter(\.isRecording).count == 2, "\(model.liveCalls.filter(\.isRecording).count)")
        model.mergeCalls()
        await wait(1.8)
        check("after the merge only the primary leg records", model.conferenceCalls.filter(\.isRecording).count == 1
              && model.conferenceCalls.first(where: \.isRecording)?.id.serial == model.conferenceCalls.map(\.id.serial).min())
        Task { await model.engine.hangupAll() }
        await wait(1.8)
        model.updateSettings { $0.recording.recordAllCalls = false }

        // auto-answer
        model.updateSettings { $0.autoAnswer = AutoAnswerSettings(mode: .contactsOnly, delaySeconds: 1, honourCallInfo: true) }
        await mock?.simulateIncoming(name: nil, number: "999", account: officeID)
        await wait(0.3)
        check("contacts-only ignores a stranger", model.autoAnswer.isEmpty && model.incomingCall != nil)
        if let c = model.incomingCall { model.decline(c.id) }
        await wait(0.3)
        await mock?.simulateIncoming(name: nil, number: "102", account: officeID)
        await wait(0.3)
        check("auto-answer armed for a contact", model.autoAnswer.count == 1)
        await wait(1.4)
        check("auto-answered after the delay", model.activeCall?.remote.number == "102" && model.autoAnswer.isEmpty)
        await mock?.simulateIncoming(name: nil, number: "101", account: officeID)
        await wait(1.5)
        check("never auto-answers a second call", model.incomingCall?.remote.number == "101" && model.autoAnswer.isEmpty)
        Task { await model.engine.hangupAll() }
        await wait(0.5)
        model.updateSettings { $0.autoAnswer.delaySeconds = 2 }
        await mock?.simulateIncoming(name: nil, number: "102", account: officeID)
        await wait(0.3)
        if let c = model.incomingCall { model.cancelAutoAnswer(c.id) }
        await wait(2.3)
        check("cancel keeps the call ringing", model.incomingCall?.remote.number == "102" && model.activeCall == nil)
        if let c = model.incomingCall { model.decline(c.id) }
        await wait(0.3)
        model.updateSettings { $0.autoAnswer.delaySeconds = 2 }
        await mock?.simulateIncoming(name: nil, number: "102", account: officeID)
        await wait(0.3)
        await mock?.simulateIncoming(name: nil, number: "555", account: officeID)
        await wait(0.3)
        check("a second ringing call leaves the first countdown alone", model.autoAnswer.count == 1 && model.ringingCalls.count == 2)
        await wait(2.2)
        check("the first call is auto-answered, the second keeps ringing",
              model.activeCall?.remote.number == "102" && model.incomingCall?.remote.number == "555", "\(model.calls.map(\.remote.number))")
        Task { await model.engine.hangupAll() }
        await wait(0.6)
        model.updateSettings { $0.autoAnswer = AutoAnswerSettings() }
        await wait(0.3)

        // call limit
        for n in ["200", "201", "202", "203"] { model.placeCall(to: n); await wait(0.15) }
        model.placeCall(to: "204")
        await wait(0.3)
        check("fifth call refused", model.calls.count == 4 && model.banner != nil, "\(model.calls.count)")
        await mock?.simulateIncoming(name: "Late Caller", number: "777", account: officeID)
        await wait(0.3)
        check("engine-rejected fifth call is noted in the log",
              model.callLog.first { $0.remoteNumber == "777" }?.note == CallLogNote.callLimit && model.calls.count == 4,
              "\(String(describing: model.callLog.first?.note))")
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

        // enabled switch (account pop-up)
        model.selectedAccountID = homeID
        check("picked account is the outgoing one", model.effectiveAccount?.id == homeID)
        model.setAccountEnabled(homeID, false)
        await model.waitForAccountSync()
        check("disabled account leaves the engine", !model.engineAccounts.contains(homeID) && model.registration[homeID] == nil)
        check("disabled account has no status", model.dot(for: model.account(homeID)!) == .off && !model.enabledAccounts.contains { $0.id == homeID })
        check("disabled account is not the outgoing one", model.effectiveAccount?.id == officeID, "\(String(describing: model.effectiveAccount?.displayName))")
        check("enabled flag persisted", model.accountStore.all().first { $0.id == homeID }?.enabled == false)
        model.setAccountEnabled(officeID, false)
        await model.waitForAccountSync()
        check("default disabled: first enabled is used", model.effectiveAccount?.id == backupID, "\(String(describing: model.effectiveAccount?.displayName))")
        model.setAccountEnabled(officeID, true)
        model.setAccountEnabled(homeID, true)
        await wait(1.4)
        check("switched on again: back in the engine and registered", model.engineAccounts.contains(homeID)
              && { if case .registered = model.registration[homeID] ?? .unregistered { return true } else { return false } }())
        check("default account is the flagged one again", model.effectiveAccount?.id == officeID)
        model.selectedAccountID = nil

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
        quitLater()
    }

    /// `terminate:` spins a nested run loop until `shutdown()` has finished on the main actor; calling it
    /// from inside a main-queue block or a main-actor task would block that very queue. A run-loop
    /// timer is neither.
    @MainActor
    static func quitLater() {
        NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0.1)
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
