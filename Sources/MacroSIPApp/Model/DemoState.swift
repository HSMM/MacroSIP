import Foundation
import MacroSIPCore
#if DEBUG
import AppKit
import SwiftUI

/// DEBUG-only launch states for screenshots and manual checks:
///   --demo-state first-launch | dialpad | contacts | calllog | connected | calls | incoming | incoming-hidden
///                 | conference | recording | autoAnswer | settings-recording | settings-autoanswer | settings-calls | settings-general | settings-general-advanced | settings-network | deny-incoming
///                 | account-popup | settings-accounts | account-editor | account-editor-basic | account-editor-open | editor-first-launch
///                 | quality-good | quality-fair | quality-poor | recording-long | many-accounts | many-accounts-settings | quality-poor-calls | network-offline | reconnecting | call-volume | headset | headset-back
///                 | settings-audio | settings-codecs | timed-dnd | call-log-playback | busy-mode | quick-keys | quick-keys-bottom | contact-card | contact-card-new
///                 | directory | directory-done | directory-incoming | directory-sheet | directory-import | settings-directory
/// Data goes to a throw-away directory (see LaunchOptions); the Keychain is never touched.
enum DemoState {
    static let officeID = AccountID(raw: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
    static let homeID = AccountID(raw: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
    static let backupID = AccountID(raw: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!)
    static let labID = AccountID(raw: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!)

    static func seed(stores: (AccountStore, ContactStore, CallLogStore, SettingsStore), vault: PasswordVault) {
        let state = LaunchOptions.current.demoState ?? ""
        if state == "first-launch" || state == "editor-first-launch" { return }
        let (accounts, contacts, log, settingsStore) = stores
        if isDirectoryState(state) { seedDirectory(settingsStore) }
        var list = [
            AccountConfig(id: officeID, displayName: "Office", username: "1001", domain: "pbx.example.com",
                          transport: .tls, srtp: .mandatory, isDefaultOutgoing: true, voicemailNumber: "*97"),
            AccountConfig(id: homeID, displayName: "Home", username: "andrei", domain: "sip.provider.net",
                          transport: .udp, srtp: .disabled),
            AccountConfig(id: backupID, displayName: "Backup", username: "2001", domain: "backup.example.net",
                          transport: .tcp, srtp: .optional),
        ]
        if state.hasPrefix("account-popup") {       // the four accounts of the mockup (screen 1, Account pop-up)
            list = [
                AccountConfig(id: officeID, displayName: "Office", username: "andrei", domain: "pbx.example.com",
                              transport: .tls, srtp: .mandatory, isDefaultOutgoing: true),
                AccountConfig(id: homeID, displayName: "Home", username: "7741", domain: "sip.example.net"),
                AccountConfig(id: backupID, displayName: "Backup", username: "andrei", domain: "voip.example.org"),
                AccountConfig(id: labID, displayName: "Lab", username: "test", domain: "10.0.0.5", enabled: false),
            ]
        }
        var failing: Set<AccountID> = [backupID]
        if state.hasPrefix("many-accounts") {       // ten accounts in mixed states: two failing, two switched off
            let names: [(String, String, String, Bool, Bool)] = [   // name, user, domain, enabled, fails
                ("Office", "1001", "pbx.example.com", true, false), ("Home", "alex", "sip.provider.net", true, false),
                ("Backup", "2001", "backup.example.net", true, true), ("Lab", "test", "10.0.0.5", false, false),
                ("Sales", "3010", "pbx.example.com", true, false), ("Support", "3020", "pbx.example.com", true, false),
                ("Warehouse", "4001", "wh.example.net", false, false), ("Reception", "100", "pbx.example.com", true, false),
                ("Branch Berlin", "7001", "berlin.example.org", true, false), ("Branch Minsk", "7002", "minsk.example.org", true, true),
            ]
            list = names.enumerated().map { i, n in
                let id = i == 0 ? officeID : (i == 1 ? homeID : (i == 2 ? backupID : AccountID()))
                if n.4 { failing.insert(id) }
                return AccountConfig(id: id, displayName: n.0, username: n.1, domain: n.2, transport: i % 2 == 0 ? .tls : .udp,
                                     enabled: n.3, isDefaultOutgoing: i == 0)
            }
        }
        for a in list {
            try? accounts.upsert(a)
            try? vault.set(failing.contains(a.id) ? "wrong" : "demo", for: a.id)
        }
        for contact in demoContacts() { try? contacts.upsert(contact) }
        let now = Date()
        let rows: [(CallDirection, String, String?, AccountID, TimeInterval, TimeInterval)] = [
            (.missed, "101", DemoPeople.andrei, officeID, -600, 0),
            (.missed, "+7 912 555-01-23", DemoPeople.dzmitry, homeID, -3600, 0),
            (.incoming, "102", DemoPeople.alesia, officeID, -7200, 254),
            (.outgoing, "100", "Reception", officeID, -20000, 61),
            (.outgoing, "+49 30 123456", nil, homeID, -100_000, 725),
            (.incoming, "sip:elena@example.org", DemoPeople.katsiaryna, officeID, -190_000, 38),
        ]
        for (dir, number, name, acct, offset, duration) in rows {
            _ = try? log.append(CallLogEntry(direction: dir, remoteNumber: number, remoteDisplayName: name, accountID: acct,
                                         startedAt: now.addingTimeInterval(offset), duration: duration))
        }
    }

    /// The demo address book (26.2): several numbers per person, two photos, two favourites, one
    /// contact known only by its organization.
    static func demoContacts() -> [Contact] {
        func number(_ label: PhoneLabel, _ value: String, _ isDefault: Bool = false) -> PhoneNumber {
            PhoneNumber(label: label, value: value, isDefault: isDefault)
        }
        func person(_ name: String, _ numbers: [PhoneNumber], watch: Bool = false, favorite: Bool = false,
                    photo: Data? = nil, email: String = "", organization: String = "", notes: String = "") -> Contact {
            let (first, last) = Contact.splitName(name)
            return Contact(firstName: first, lastName: last, organization: organization, numbers: numbers, email: email, notes: notes,
                           isFavorite: favorite, photo: photo, subscribePresence: watch)
        }
        return [
            person(DemoPeople.alesia, [number(.work, "102", true), number(.mobile, "+375 29 555-01-42")], watch: true, favorite: true,
                   photo: photoJPEG(top: (0.38, 0.62, 0.95), bottom: (0.16, 0.36, 0.80)), email: "alesia@example.com",
                   organization: "Example Ltd, Sales",
                   notes: DemoPeople.alesiaNote),
            person(DemoPeople.andrei, [number(.work, "101", true)], watch: true, favorite: true,
                   photo: photoJPEG(top: (0.98, 0.72, 0.36), bottom: (0.86, 0.45, 0.16))),
            person("Reception", [number(.work, "100", true)], watch: true),
            person(DemoPeople.dzmitry, [number(.mobile, "+7 912 555-01-23", true), number(.work, "2231"), number(.home, "+375 17 200-30-40")], watch: true),
            person(DemoPeople.katsiaryna, [number(.sip, "sip:elena@example.org", true)]),
            person(DemoPeople.yauheni, [number(.mobile, "+49 30 123456", true)]),
            person(DemoPeople.siarhei, [number(.mobile, "+1 415 555-0142", true)]),
            Contact(organization: "Help Desk", numbers: [number(.sip, "sip:helpdesk@pbx.example.com", true)]),
        ]
    }

    /// A plain portrait (gradient, head and shoulders), encoded the way the contact card stores photos.
    static func photoJPEG(top: (CGFloat, CGFloat, CGFloat), bottom: (CGFloat, CGFloat, CGFloat)) -> Data? {
        let side = 256
        guard let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        let space = CGColorSpaceCreateDeviceRGB()
        let colors = [CGColor(red: bottom.0, green: bottom.1, blue: bottom.2, alpha: 1),
                      CGColor(red: top.0, green: top.1, blue: top.2, alpha: 1)] as CFArray
        if let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1]) {
            ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: side), options: [])
        }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.85))
        ctx.fillEllipse(in: CGRect(x: 88, y: 118, width: 80, height: 80))          // head
        ctx.fillEllipse(in: CGRect(x: 40, y: -70, width: 176, height: 170))        // shoulders
        guard let image = ctx.makeImage() else { return nil }
        return ContactPhoto.jpeg(from: image)
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
        case "contact-card", "contact-card-new":
            model.tab = .contacts
            try? await Task.sleep(for: .seconds(1.2))
            let alesia = model.contacts.first { $0.displayName == DemoPeople.alesia }
            ContactCardController.shared.show(ContactEditorRequest(contact: state == "contact-card" ? alesia : nil), model: model)
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
        case "quality-good", "quality-fair", "quality-poor":
            try? await Task.sleep(for: .seconds(1.5))
            let level: QualityLevel = state == "quality-good" ? .good : (state == "quality-fair" ? .fair : .poor)
            await (model.engine as? MockEngine)?.setQualityOverride(level)
            model.placeCall(to: "102")
            // The banner needs the call to stay poor for 6 s; the first sample comes 2 s after the start.
            try? await Task.sleep(for: .seconds(level == .poor ? 12 : 6))
        case "many-accounts", "many-accounts-settings":
            try? await Task.sleep(for: .seconds(1.5))
            if let reconnecting = model.accounts.first(where: { $0.displayName == "Branch Berlin" }) {
                await (model.engine as? MockEngine)?.simulateAccountRetry(reconnecting.id, attempt: 2, nextRetryIn: 30)
            }
            if state == "many-accounts-settings" { model.openSettings(tab: .accounts, account: officeID) }
        case "quality-poor-calls":
            try? await Task.sleep(for: .seconds(1.5))
            await (model.engine as? MockEngine)?.setQualityOverride(.poor)
            model.placeCall(to: "102")
            try? await Task.sleep(for: .seconds(3.2))
            model.placeCall(to: "101")
            try? await Task.sleep(for: .seconds(12))
        case "network-offline":
            try? await Task.sleep(for: .seconds(1.5))
            model.placeCall(to: "102")
            try? await Task.sleep(for: .seconds(3.2))
            await (model.engine as? MockEngine)?.simulateNetwork(online: false)
            try? await Task.sleep(for: .seconds(2.5))
        case "reconnecting":        // one account retrying, the call without media (network still up)
            try? await Task.sleep(for: .seconds(1.5))
            model.placeCall(to: "102")
            try? await Task.sleep(for: .seconds(3.2))
            let mock = model.engine as? MockEngine
            await mock?.simulateAccountRetry(officeID, attempt: 2, nextRetryIn: 12)
            if let id = model.activeCall?.id { try? await mock?.simulateCallReconnecting(id, true) }
            try? await Task.sleep(for: .seconds(4))
        case "call-volume":
            try? await Task.sleep(for: .seconds(1.5))
            model.setCallVolume(speaker: 1.2, microphone: 0.8)
            model.placeCall(to: "102")
            try? await Task.sleep(for: .seconds(4))
            model.callVolumeShown = true
        case "headset", "headset-back":
            try? await Task.sleep(for: .seconds(1.5))
            model.updateSettings { $0.audio.inputDeviceName = "MacBook Pro Microphone"; $0.audio.outputDeviceName = "MacBook Pro Speakers" }
            model.placeCall(to: "102")
            try? await Task.sleep(for: .seconds(3.5))
            await (model.engine as? MockEngine)?.simulateHeadset(connected: true)
            if state == "headset-back" {
                try? await Task.sleep(for: .seconds(1))
                await (model.engine as? MockEngine)?.simulateHeadset(connected: false)
            }
            try? await Task.sleep(for: .seconds(0.8))
        case "voicemail":           // two new messages on Office: the envelope badge in the status bar, "Voicemail: 2 new" in <prefix>-menu.txt
            try? await Task.sleep(for: .seconds(1.5))
            await (model.engine as? MockEngine)?.simulateVoicemail(account: officeID, new: 2, old: 5)
            try? await Task.sleep(for: .seconds(0.3))
        case "timed-dnd":           // 27 minutes left; Settings › General shows the Calls group, <prefix>-menu.txt the menu bar submenu
            try? await Task.sleep(for: .seconds(1.5))
            model.updateSettings { $0.general.doNotDisturb = true; $0.general.doNotDisturbUntil = Date().addingTimeInterval(27 * 60 - 10) }
            model.openSettings(tab: .general)
        case "call-log-playback":   // two entries with a play button, the inline player open under the first
            try? await Task.sleep(for: .seconds(1.0))
            model.tab = .callLog
            await seedRecordings(model)
        case "busy-mode":           // single-call mode: the second caller was turned away; General shows the setting
            try? await Task.sleep(for: .seconds(1.5))
            model.updateSettings { $0.callOptions.incomingWhileOnCall = .busy }
            model.placeCall(to: "102")
            try? await Task.sleep(for: .seconds(3.2))
            await (model.engine as? MockEngine)?.simulateIncoming(name: DemoPeople.andrei, number: "101", account: officeID)
            try? await Task.sleep(for: .seconds(0.3))
            model.tab = .callLog
            model.openSettings(tab: .calls)
        case "quick-keys", "quick-keys-bottom":     // the panel (right / bottom) with eight keys, one ringing; Settings › Quick keys opens too
            await quickKeysDemo(model, bottom: state == "quick-keys-bottom")
        case let s where isDirectoryState(s) && s != "settings-directory":
            await runDirectory(model, state: s)
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
        case "recording-long":      // a long account name makes the chip row wrap: the compact panel must still fit
            try? await Task.sleep(for: .seconds(1.5))
            if let i = model.accounts.firstIndex(where: { $0.id == officeID }) { model.accounts[i].displayName = "Office Moscow Branch North" }
            model.placeCall(to: "102")
            try? await Task.sleep(for: .seconds(3.2))
            if let c = model.activeCall { model.toggleRecording(c) }
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
        case "account-editor-basic":    // Home: all advanced fields at their defaults, so the section stays closed
            try? await Task.sleep(for: .seconds(1.5))
            model.openSettings(tab: .accounts, account: homeID)
            try? await Task.sleep(for: .seconds(0.8))
            model.settingsEditor = AccountEditorRequest(accountID: homeID)
        case "account-editor-open":     // the same account with the section opened by the user
            try? await Task.sleep(for: .seconds(1.5))
            model.accountAdvancedOpen = true
            model.openSettings(tab: .accounts, account: homeID)
            try? await Task.sleep(for: .seconds(0.8))
            model.settingsEditor = AccountEditorRequest(accountID: homeID)
        case "editor-first-launch":
            try? await Task.sleep(for: .seconds(1.0))
            model.mainEditor = AccountEditorRequest(accountID: nil)
        case "settings-network":    // port range moved and DNS SRV on: the engine asks for a restart, the pane shows the banner
            try? await Task.sleep(for: .seconds(1.5))
            model.updateSettings { $0.network.rtpPortStart = 20000; $0.network.dnsSRV = true; $0.network.nameserver = "10.0.0.53" }
            try? await Task.sleep(for: .seconds(1.2))
            model.openSettings(tab: .network)
        case "settings-codecs":     // the 26.2 codecs are listed below the four classic ones, off; Speex 16 kHz and GSM on to show both looks
            try? await Task.sleep(for: .seconds(1.5))
            model.updateSettings { $0.enabledCodecs.formUnion(["speex/16000/1", "GSM/8000/1"]) }
            model.openSettings(tab: .codecs)
        case "deny-incoming":       // "Numbers not in Contacts": a stranger was turned away (call log), General shows the rule
            try? await Task.sleep(for: .seconds(1.5))
            model.updateSettings { $0.callOptions.denyIncoming = .notInContacts }
            try? await Task.sleep(for: .seconds(0.4))
            await (model.engine as? MockEngine)?.simulateIncoming(name: "Unknown caller", number: "+49 30 5551234", account: officeID)
            try? await Task.sleep(for: .seconds(0.3))
            model.tab = .callLog
            model.openSettings(tab: .calls)
        case "settings-general-advanced":   // General with the Advanced group opened (Links, Troubleshooting): the tallest pane
            try? await Task.sleep(for: .seconds(1.5))
            model.generalAdvancedOpen = true
            model.openSettings(tab: .general)
        case "settings-autoanswer":
            try? await Task.sleep(for: .seconds(1.5))
            model.openSettings(tab: .calls)
        case let s where s.hasPrefix("settings-"):
            try? await Task.sleep(for: .seconds(1.5))
            let name = String(s.dropFirst(9)).lowercased()
            model.openSettings(tab: SettingsTab.allCases.first { $0.rawValue.lowercased() == name } ?? .general)
        default: break
        }
        if let prefix = model.launch.snapshotPrefix {
            try? await Task.sleep(for: .seconds(model.launch.snapshotDelay))
            snapshot(prefix: prefix)
            if state == "account-popup" || state == "many-accounts" { snapshotAccountPopup(prefix: prefix, model: model) }
            if state == "many-accounts" {       // the filter of the pop-up, checked on the real menu
                let popup = AccountPopupMenu(model: model)
                _ = popup.build()
                var lines = ["search row: \(popup.hasSearchField)", "rows: \(popup.visibleRowCount)"]
                popup.filter("berlin"); lines.append("berlin: \(popup.visibleRowCount)")
                popup.filter("EXAMPLE.COM"); lines.append("example.com: \(popup.visibleRowCount)")
                popup.filter("nothing"); lines.append("nothing: \(popup.visibleRowCount)")
                popup.filter(""); lines.append("cleared: \(popup.visibleRowCount)")
                try? lines.joined(separator: "\n").write(toFile: "\(prefix)-filter.txt", atomically: true, encoding: .utf8)
            }
            if state == "call-volume" { snapshotVolumePopover(prefix: prefix, model: model) }
            if state == "timed-dnd" || state == "voicemail", let menu = StatusItemController.current?.debugMenuTitles() {
                try? menu.joined(separator: "\n").write(toFile: "\(prefix)-menu.txt", atomically: true, encoding: .utf8)
            }
            if state != "selftest", state != "directory-selftest" { quitLater() }     // the snapshot was the point; those two quit themselves
        }
    }

    /// Two recordings for the call log: the incoming call from Alesia is found by its file name (older
    /// entries have no stored file), the outgoing call to Reception has its file stored. The player is
    /// opened under the first and parked at 0:18.
    @MainActor
    static func seedRecordings(_ model: AppModel) async {
        let folder = model.recordingFolderURL
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for number in ["102", "100"] {
            guard let entry = model.callLog.first(where: { $0.remoteNumber == number }) else { continue }
            let name = RecordingFileName.make(date: entry.startedAt.addingTimeInterval(20), remote: model.name(for: entry),
                                              direction: entry.direction)
            let wav = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).wav")
            try? MockEngine.sineWAV(seconds: 62).write(to: wav)
            let url = try? await RecordingConverter.convert(wav: wav, to: folder.appendingPathComponent(name))
            try? FileManager.default.removeItem(at: wav)
            if number == "100", let url { try? model.callLogStore.setRecording(url, for: entry.id) }
        }
        model.callLog = model.callLogStore.all()
        await model.updateRecordingLinks()
        if let entry = model.callLog.first(where: { $0.remoteNumber == "102" }), let url = model.recordingLinks[entry.id] {
            model.playerEntry = entry.id
            model.recordingPlayer.open(url, play: false)
            model.recordingPlayer.seek(to: 18)
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
        let items = menu.items.filter { !$0.isHidden }
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

    /// A popover is a window of its own that `snapshot` skips, so the volume popover is drawn from its view.
    @MainActor
    static func snapshotVolumePopover(prefix: String, model: AppModel) {
        let content = CallVolumePopover().environment(model)
            .background(Color(nsColor: .windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        let host = NSHostingView(rootView: content)
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: "\(prefix)-popover.png"))
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
            else if w is ContactCardPanel { name = "card" }
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

        await headsetChecks(model) { check($0, $1, $2) }
        await soundChecks(model) { check($0, $1, $2) }

        // DND
        model.toggleDND()
        let m2 = model.callLog.filter { $0.direction == .missed }.count
        await mock?.simulateIncoming(name: nil, number: "559", account: officeID)
        await wait(0.4)
        check("DND rejects", model.calls.isEmpty && model.callLog.filter { $0.direction == .missed }.count == m2 + 1)
        model.toggleDND()
        check("DND persisted off", !model.settingsStore.load().general.doNotDisturb)

        // timed Do Not Disturb (26.1)
        model.setDND(.minutes(30))
        let thirty = model.doNotDisturbUntil.map { $0.timeIntervalSinceNow } ?? 0
        check("DND for 30 minutes sets an end", model.doNotDisturb && thirty > 29 * 60 && thirty <= 30 * 60, "\(thirty)")
        check("timed DND shows the time left", model.dndRemainingMinutes() == 30 && model.dndTitle() == L.menuDNDRemaining(L.durationShort(minutes: 30)), model.dndTitle())
        check("timed DND is stored", abs((model.settingsStore.load().general.doNotDisturbUntil ?? .distantPast).timeIntervalSince(model.doNotDisturbUntil ?? .now)) < 1)
        check("timed DND publishes dnd", model.effectivePresence == .dnd)
        await wait(0.2)
        let engineDND = await mock?.callOptions.doNotDisturb
        check("DND reaches the engine as a call option", engineDND == true, "\(String(describing: engineDND))")
        check("short durations", L.durationShort(minutes: 27).contains("27") && L.durationShort(minutes: 60).contains("1")
              && L.durationShort(minutes: 65).contains("5"))
        model.setDND(.on)
        check("DND on has no end", model.doNotDisturb && model.doNotDisturbUntil == nil && model.dndTitle() == L.menuDND)
        model.setDND(.off)
        await wait(0.2)
        let engineDNDOff = await mock?.callOptions.doNotDisturb
        check("DND off reaches the engine", engineDNDOff == false)
        check("DND off clears the end", !model.doNotDisturb && model.settings.general.doNotDisturbUntil == nil && model.effectivePresence != .dnd)
        let cal = Calendar.current
        if let tomorrow = AppModel.dndEnd(of: .untilTomorrowMorning) {
            check("until tomorrow means the coming 9:00 (today before 9:00, else the next day)",
                  cal.component(.hour, from: tomorrow) == 9 && cal.component(.minute, from: tomorrow) == 0 && tomorrow > Date()
                  && (cal.component(.hour, from: Date()) < 9 ? cal.isDateInToday(tomorrow) : cal.isDateInTomorrow(tomorrow)), "\(tomorrow)")
            func at(_ h: Int, _ m: Int) -> Date { cal.date(bySettingHour: h, minute: m, second: 0, of: Date())! }
            let night = AppModel.dndEnd(of: .untilTomorrowMorning, from: at(2, 30))
            let late = AppModel.dndEnd(of: .untilTomorrowMorning, from: at(9, 0))
            check("at 2:30 until tomorrow is today 9:00, at 9:00 it is the next day",
                  night.map { cal.isDateInToday($0) && cal.component(.hour, from: $0) == 9 } == true
                  && late.map { cal.isDateInTomorrow($0) } == true)
        } else { check("until tomorrow has an end", false) }
        model.updateSettings { $0.general.doNotDisturb = true; $0.general.doNotDisturbUntil = Date().addingTimeInterval(1.2) }
        await mock?.simulateIncoming(name: nil, number: "560", account: officeID)
        await wait(0.3)
        check("timed DND rejects calls", model.calls.isEmpty)
        await wait(1.5)
        check("timed DND ends by itself", !model.doNotDisturb && model.settings.general.doNotDisturbUntil == nil && model.effectivePresence != .dnd)
        await mock?.simulateIncoming(name: nil, number: "561", account: officeID)
        await wait(0.3)
        check("calls ring again after the timer", model.incomingCall?.remote.number == "561")
        if let c = model.incomingCall { model.decline(c.id) }
        await wait(0.3)


        // presence: watched contacts get a status, unwatching drops it
        let watchedContacts = model.contacts.filter(\.subscribePresence)
        check("presence arrives for watched contacts", !watchedContacts.isEmpty && watchedContacts.allSatisfy { model.presenceStatus(for: $0) != nil },
              "\(model.presence)")
        if let anna = model.contacts.first(where: { $0.displayName == DemoPeople.alesia }) {
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
        check("merge enabled with two connected calls, one of them held", model.liveCalls.count == 2 && model.heldCount == 1 && model.canMerge,
              "\(model.liveCalls.count)")
        model.mergeCalls()
        await wait(0.3)
        check("merged into a conference", model.conferenceCalls.count == 2 && model.activeCalls.count == 2 && model.heldCount == 0 && !model.canMerge)
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
        await wait(0.3)
        check("the saved recording is linked to its call-log entry",
              model.savedRecordings.last.map { url in model.callLog.contains { $0.recordingURL == url } && model.recordingLinks.values.contains(url) } == true,
              "\(model.callLog.compactMap(\.recordingURL).map(\.lastPathComponent))")
        if let url = model.savedRecordings.last {
            let player = model.recordingPlayer
            player.open(url, play: false)
            check("the player opens the recording", player.duration > 0.5 && !player.isPlaying && !player.failed, "\(player.duration)")
            player.toggle()
            player.seek(to: 0.4)
            check("the player plays and seeks", player.isPlaying && abs(player.position - 0.4) < 0.1, "\(player.position)")
            player.toggle()
            check("the player pauses", !player.isPlaying)
            player.close()
            check("the player closes", player.url == nil && player.duration == 0)
            player.open(URL(fileURLWithPath: "/nonexistent.m4a"), play: false)
            check("a missing file is reported", player.failed)
            player.close()
            // a ringing call pauses playback; the player closes when its recording disappears
            if let entry = model.callLog.first(where: { $0.recordingURL == url }) {
                let copy = url.deletingLastPathComponent().appendingPathComponent("player-check.m4a")
                try? FileManager.default.copyItem(at: url, to: copy)
                try? model.callLogStore.setRecording(copy, for: entry.id)
                model.callLog = model.callLogStore.all()
                await model.updateRecordingLinks()
                model.playerEntry = entry.id
                player.open(copy, play: true)
                check("the player is playing", player.isPlaying)
                await mock?.simulateIncoming(name: nil, number: "783", account: officeID)
                await wait(0.3)
                check("a ringing call pauses the playback", !player.isPlaying && player.url == copy)
                for c in model.ringingCalls { model.decline(c.id) }
                await wait(0.3)
                try? FileManager.default.removeItem(at: copy)
                await model.updateRecordingLinks()
                check("the player closes when its recording is gone", model.playerEntry == nil && player.url == nil)
                try? model.callLogStore.setRecording(url, for: entry.id)
                model.callLog = model.callLogStore.all()
                await model.updateRecordingLinks()
            }
        }
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

        // call options (26.1): single-call mode, DTMF method, bring to front
        model.updateSettings { $0.callOptions = CallOptions(incomingWhileOnCall: .busy, dtmfMethod: .sipINFO) }
        await wait(0.2)
        let engineOptions = await mock?.callOptions
        check("call options reach the engine", engineOptions.map { var o = $0; o.knownNumbers = []; return o } == CallOptions(incomingWhileOnCall: .busy, dtmfMethod: .sipINFO), "\(String(describing: engineOptions))")
        check("call options are stored", model.settingsStore.load().callOptions == model.settings.callOptions)
        model.placeCall(to: "210")
        await wait(2.8)
        let busyLog = model.callLog.count
        await mock?.simulateIncoming(name: "Second Caller", number: "778", account: officeID)
        await wait(0.3)
        check("busy mode: the second call never rings", model.incomingCall == nil && model.calls.count == 1)
        check("busy mode: the rejection is noted in the log", model.callLog.count == busyLog + 1
              && model.callLog.first { $0.remoteNumber == "778" }?.note == CallLogNote.busy
              && L.logNoteText(CallLogNote.busy) == L.logNoteBusy, "\(String(describing: model.callLog.first?.note))")
        model.updateSettings { $0.callOptions.incomingWhileOnCall = .windowOnly }
        await wait(0.2)
        await mock?.simulateIncoming(name: "Second Caller", number: "779", account: officeID)
        await wait(0.3)
        check("window-only mode: the second call rings", model.incomingCall?.remote.number == "779")
        if let c = model.incomingCall { model.decline(c.id) }
        Task { await model.engine.hangupAll() }
        await wait(0.5)
        // busy mode counts only calls that are not ringing
        model.updateSettings { $0.callOptions.incomingWhileOnCall = .busy }
        await wait(0.2)
        await mock?.simulateIncoming(name: nil, number: "780", account: officeID)
        await mock?.simulateIncoming(name: nil, number: "781", account: officeID)
        await wait(0.3)
        check("busy mode: a ringing call does not make the next one busy", model.ringingCalls.count == 2,
              "\(model.ringingCalls.count) \(model.calls.map { "\($0.remote.number) \($0.state)" }) dnd \(model.doNotDisturb)")
        for c in model.ringingCalls { model.decline(c.id) }
        await wait(0.4)
        model.updateSettings { $0.callOptions = CallOptions(); $0.general.bringToFrontOnIncoming = true }
        check("bring-to-front is stored", model.settingsStore.load().general.bringToFrontOnIncoming)
        await mock?.simulateIncoming(name: nil, number: "782", account: officeID)
        await wait(0.4)
        let windowKey = NSApp.isActive && model.mainWindow?.isKeyWindow == true
        check("bring-to-front does not take the keys: they are held back until a click", model.incomingKeyGuard || windowKey,
              "guard \(model.incomingKeyGuard) key \(windowKey)")
        for c in model.ringingCalls { model.decline(c.id) }
        await wait(0.4)
        check("the key hold ends with the calls", !model.incomingKeyGuard)
        model.updateSettings { $0.general.bringToFrontOnIncoming = false }

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

        // call quality: bars, the poor-connection rule, the polling timer
        func sample(_ level: QualityLevel, loss: Double = 0.5, jitter: Double = 12, rtt: Double = 48, mos: Double = 4.3) -> CallQuality {
            CallQuality(lossPercent: loss, jitterMs: jitter, rttMs: rtt, mos: mos, level: level)
        }
        check("bars: good 4, fair 3 or 2, poor 1", sample(.good).bars == 4 && sample(.fair, mos: 3.9).bars == 3
              && sample(.fair, mos: 3.2).bars == 2 && sample(.poor, mos: 2).bars == 1)
        check("worst metric is named", PoorReason(sample(.poor, loss: 12, jitter: 30, rtt: 100)).kind == .loss
              && PoorReason(sample(.poor, loss: 1, jitter: 150, rtt: 100)).kind == .jitter
              && PoorReason(sample(.poor, loss: 1, jitter: 30, rtt: 900)).kind == .rtt
              && PoorReason(sample(.poor, loss: 1, jitter: 30, rtt: 100, mos: 2.5)).kind == .mos)
        check("details text has the four numbers", sample(.good).detailsText == L.callQualityDetails(
            loss: L.unitPercent(L.number(0.5)), jitter: L.unitMs("12"), rtt: L.unitMs("48"), mos: L.number(4.3)), sample(.good).detailsText)
        check("number format has at most one decimal", L.number(12.34) == L.number(12.3) && L.number(4) == "4")
        var monitor = QualityMonitor()
        let qid = CallID(raw: 0, serial: 9_999)
        let t0 = Date()
        let poor = sample(.poor, loss: 12)
        check("poor for 0 s: no banner", monitor.record(poor, for: qid, at: t0) == nil)
        check("poor for 5 s: no banner", monitor.record(poor, for: qid, at: t0.addingTimeInterval(5)) == nil)
        check("poor for 6 s: banner with the reason", monitor.record(poor, for: qid, at: t0.addingTimeInterval(6)) == PoorReason(poor))
        check("one good sample keeps the banner", monitor.record(sample(.fair), for: qid, at: t0.addingTimeInterval(8)) == PoorReason(poor))
        check("a poor sample after it restarts the count of good ones", monitor.record(poor, for: qid, at: t0.addingTimeInterval(10)) == PoorReason(poor)
              && monitor.record(sample(.good), for: qid, at: t0.addingTimeInterval(12)) == PoorReason(poor))
        check("two good samples in a row hide it", monitor.record(sample(.good), for: qid, at: t0.addingTimeInterval(14)) == nil)
        check("a new poor spell starts counting again", monitor.record(poor, for: qid, at: t0.addingTimeInterval(15)) == nil
              && monitor.record(poor, for: qid, at: t0.addingTimeInterval(20)) == nil
              && monitor.record(poor, for: qid, at: t0.addingTimeInterval(21)) != nil)
        check("banner text names the loss", PoorReason(sample(.poor, loss: 12)).text == L.callPoorLoss(L.unitPercent("12")), PoorReason(sample(.poor, loss: 12)).text)

        model.placeCall(to: "100")
        await wait(2.8)
        let qcall = model.activeCall
        await mock?.setQualityOverride(.fair)
        await wait(2.6)
        check("timer polls: fair sample arrives", qcall.flatMap { model.quality[$0.id] }?.level == .fair, "\(model.quality.count)")
        await mock?.setQualityOverride(.poor)
        await wait(3)
        check("poor for 2 s: no banner yet", qcall.map { model.poorWarning[$0.id] == nil } == true)
        await wait(6.5)
        check("poor for 6 s: banner", qcall.flatMap { model.poorWarning[$0.id] }?.kind == .loss, "\(model.poorWarning)")
        await mock?.setQualityOverride(.good)
        await wait(1.4)             // at most one poll (every 2 s) fits: the banner must still be there
        check("one good sample keeps the banner for now", qcall.flatMap { model.poorWarning[$0.id] } != nil)
        await wait(4.0)             // at least two more polls: the banner is gone
        check("recovery hides the banner", qcall.map { model.poorWarning[$0.id] == nil && model.quality[$0.id]?.level == .good } == true)

        // call volume: live on the call, stored, default for new calls, clamped, keyboard steps
        model.setCallVolume(speaker: 1.5, microphone: 0.5)
        await wait(0.3)
        var live: (speaker: Float, microphone: Float)?
        if let id = qcall?.id { live = await mock?.callVolumes[id] }
        let dflt = await mock?.defaultVolume
        check("volume applied to the live call", live?.speaker == 1.5 && live?.microphone == 0.5, "\(String(describing: live))")
        check("volume is the default of new calls", dflt?.speaker == 1.5 && dflt?.microphone == 0.5, "\(String(describing: dflt))")
        check("volume persisted", model.settingsStore.load().audio.callSpeakerVolume == 1.5 && model.settingsStore.load().audio.callMicrophoneVolume == 0.5)
        model.nudgeSpeakerVolume(by: 0.1)
        check("command-up adds 10 %", model.settings.audio.callSpeakerVolume == 1.6, "\(model.settings.audio.callSpeakerVolume)")
        model.nudgeSpeakerVolume(by: -0.1); model.nudgeSpeakerVolume(by: -0.1)
        check("command-down takes 10 % off", model.settings.audio.callSpeakerVolume == 1.4, "\(model.settings.audio.callSpeakerVolume)")
        model.setCallVolume(speaker: 3, microphone: -1)
        check("volume stays within 0...200 %", model.settings.audio.callSpeakerVolume == 2 && model.settings.audio.callMicrophoneVolume == 0)
        model.nudgeSpeakerVolume(by: 0.1)
        check("command-up stops at 200 %", model.settings.audio.callSpeakerVolume == 2)
        model.setCallVolume(speaker: 1, microphone: 1)
        await wait(0.2)
        check("reset gives 100 %", model.callVolume.speaker == 1 && model.callVolume.microphone == 1)
        Task { await model.engine.hangupAll() }
        await wait(0.5)
        check("quality state cleared after the call", model.quality.isEmpty && model.poorWarning.isEmpty)

        // ringtone volume and Opus options reach the engine
        model.updateSettings { $0.audio.ringtoneVolume = 0.4 }
        await wait(0.2)
        let ringVolume = await mock?.ringtoneVolume
        check("ringtone volume applied and stored", ringVolume == 0.4 && model.settingsStore.load().audio.ringtoneVolume == 0.4, "\(String(describing: ringVolume))")
        model.updateSettings { $0.audio.ringtoneVolume = 1 }
        let optionsAtStart = await mock?.codecOptions
        check("Opus options default: FEC on, DTX off", optionsAtStart == CodecOptions(opusFEC: true, opusDTX: false), "\(String(describing: optionsAtStart))")
        model.updateSettings { $0.codecOptions = CodecOptions(opusFEC: false, opusDTX: true) }
        await wait(0.2)
        let optionsNow = await mock?.codecOptions
        check("Opus options applied live and stored", optionsNow == CodecOptions(opusFEC: false, opusDTX: true)
              && model.settingsStore.load().codecOptions == CodecOptions(opusFEC: false, opusDTX: true), "\(String(describing: optionsNow))")
        model.updateSettings { $0.codecOptions = CodecOptions() }

        // many accounts: filter, pop-up order and search row, status summary
        func acct(_ n: String, _ u: String, _ d: String, enabled: Bool = true) -> AccountConfig { AccountConfig(displayName: n, username: u, domain: d, enabled: enabled) }
        let many = [acct("Zeta", "1", "z.example.com"), acct("alpha", "2", "a.example.com", enabled: false), acct("Beta", "3", "b.example.com"),
                    acct("Café", "cafe", "c.example.com", enabled: false), acct("Delta", "4", "d.example.com"), acct("Eta", "5", "e.example.com"),
                    acct("Gamma", "6", "g.example.com"), acct("Iota", "7", "pbx.berlin.example.org")]
        check("filter matches name, user and domain", AccountList.matches(many[0], query: "zet") && AccountList.matches(many[2], query: "3@b.")
              && AccountList.matches(many[7], query: "berlin") && !AccountList.matches(many[2], query: "zzz") && AccountList.matches(many[2], query: "  "))
        check("filter ignores case and accents", AccountList.matches(many[3], query: "CAFE") && AccountList.matches(many[1], query: "ALPHA"))
        check("pop-up order: enabled first, then disabled, each by name",
              AccountList.popupOrder(many).map(\.displayName) == ["Beta", "Delta", "Eta", "Gamma", "Iota", "Zeta", "alpha", "Café"],
              "\(AccountList.popupOrder(many).map(\.displayName))")
        check("search from 8 accounts on", AccountList.needsSearch(8) && !AccountList.needsSearch(7))
        let popup = AccountPopupMenu(model: model)
        _ = popup.build()
        check("a short list has no search row", !popup.hasSearchField && popup.visibleRowCount == model.accounts.count)
        let sum = model.registrationSummary
        check("summary counts online and failed", sum.total == model.enabledAccounts.count && sum.failed >= 1 && sum.online + sum.failed <= sum.total, "\(sum)")
        check("summary text without and with failures", L.statusSummary(4, 6) == L.statusSummary(4, 6, failed: 0)
              && L.statusSummary(4, 6, failed: 2).contains(L.statusSummaryFailed(2)) && L.statusSummary(4, 6, failed: 2).hasPrefix(L.statusSummary(4, 6)))

        // network: offline state, reconnecting accounts and calls, connection lost
        model.placeCall(to: "100")
        await wait(2.8)
        await mock?.simulateNetwork(online: false)
        await wait(0.5)
        check("offline is shown", !model.networkOnline)
        check("account retries while offline", model.registration[officeID]?.retry?.attempt == 1, "\(String(describing: model.registration[officeID]))")
        check("call is reconnecting", model.activeCall?.isReconnecting == true && model.reconnectingSince.count == 1)
        check("dot is orange while retrying", model.dot(for: model.account(officeID)!) == .registering)
        await mock?.simulateNetwork(online: true)
        await wait(1.6)
        check("online again", model.networkOnline)
        check("account registers again", { if case .registered = model.registration[officeID] ?? .unregistered { return true } else { return false } }(),
              "\(String(describing: model.registration[officeID]))")
        check("call recovered", model.activeCall?.isReconnecting == false && model.reconnectingSince.isEmpty)
        let lostBefore = model.callLog.filter { $0.note == CallLogNote.connectionLost }.count
        if let id = model.activeCall?.id { try? await mock?.simulateConnectionLost(id) }
        await wait(0.4)
        check("connection lost gets a log note", model.callLog.filter { $0.note == CallLogNote.connectionLost }.count == lostBefore + 1
              && L.logNoteText(CallLogNote.connectionLost) == L.logNoteConnectionLost)
        await wait(0.3)

        // following a headset
        let mic = "MacBook Pro Microphone", spk = "MacBook Pro Speakers"
        model.updateSettings { $0.audio.inputDeviceName = mic; $0.audio.outputDeviceName = spk }
        await wait(0.3)
        await mock?.simulateHeadset(connected: false)           // same list as before: nothing newly appeared
        await wait(0.4)
        var sel = await (mock?.selectedInput, mock?.selectedOutput)
        check("devices that were already there are not followed", model.headsetFollow.headset == nil && sel.0 == mic && sel.1 == spk, "\(sel)")
        await mock?.simulateHeadset(connected: true)
        await wait(0.5)
        sel = await (mock?.selectedInput, mock?.selectedOutput)
        check("new headset becomes input and output", sel.0 == "AirPods Pro" && sel.1 == "AirPods Pro" && model.headsetFollow.headset == "AirPods Pro", "\(sel)")
        check("configured names are untouched", model.settings.audio.inputDeviceName == mic && model.settings.audio.outputDeviceName == spk)
        check("banner says where the audio went", model.banner?.text == L.bannerAudioSwitched("AirPods Pro"), "\(String(describing: model.banner?.text))")
        await mock?.simulateHeadset(connected: false)
        await wait(0.5)
        sel = await (mock?.selectedInput, mock?.selectedOutput)
        check("unplugged: back to the configured names", sel.0 == mic && sel.1 == spk && model.headsetFollow.headset == nil, "\(sel)")
        check("banner says back", model.banner?.text == L.bannerAudioBack(spk), "\(String(describing: model.banner?.text))")
        model.updateSettings { $0.audio.followNewDevices = false }
        await mock?.simulateHeadset(connected: true)
        await wait(0.5)
        sel = await (mock?.selectedInput, mock?.selectedOutput)
        check("switch off: the headset is ignored", sel.0 == mic && sel.1 == spk && model.headsetFollow.headset == nil, "\(sel)")
        await mock?.simulateHeadset(connected: false)
        model.updateSettings { $0.audio.followNewDevices = true }
        await wait(0.3)
        await mock?.simulateHeadset(connected: true)
        await wait(0.5)
        model.updateSettings { $0.audio.followNewDevices = false }
        await wait(0.4)
        sel = await (mock?.selectedInput, mock?.selectedOutput)
        check("switching the setting off while following goes back", sel.0 == mic && sel.1 == spk && model.headsetFollow.headset == nil, "\(sel)")
        model.updateSettings { $0.audio.followNewDevices = true }
        await mock?.simulateHeadset(connected: false)
        await wait(0.3)
        await mock?.simulateHeadset(connected: true)
        await wait(0.5)
        model.updateSettings { $0.audio.inputDeviceName = "USB Headset" }
        await wait(0.4)
        sel = await (mock?.selectedInput, mock?.selectedOutput)
        check("picking a device by hand ends the following", model.headsetFollow.headset == nil && sel.0 == "USB Headset" && sel.1 == spk, "\(sel)")
        await mock?.simulateHeadset(connected: false)
        model.updateSettings { $0.audio.inputDeviceName = nil; $0.audio.outputDeviceName = nil }
        await wait(0.3)
        await mock?.simulateVirtualDevice(connected: true)
        await wait(0.5)
        sel = await (mock?.selectedInput, mock?.selectedOutput)
        check("a virtual device is never followed", model.headsetFollow.headset == nil && sel.0 == nil && sel.1 == nil, "\(sel)")
        await mock?.simulateVirtualDevice(connected: false)
        await wait(0.3)
        var hf = HeadsetFollow()
        let base = [AudioDevice(id: 0, name: "Mic", inputChannels: 1, outputChannels: 0), AudioDevice(id: 1, name: "Spk", inputChannels: 0, outputChannels: 2)]
        let pods = AudioDevice(id: 5, name: "Pods", inputChannels: 1, outputChannels: 2)
        let usb = AudioDevice(id: 6, name: "USB", inputChannels: 1, outputChannels: 2)
        let speakerOnly = AudioDevice(id: 7, name: "Display", inputChannels: 0, outputChannels: 2)
        let all: Set<String> = ["Pods", "USB"]
        func up(_ p: [AudioDevice], _ c: [AudioDevice], eligible: Set<String> = all, enabled: Bool = true) -> HeadsetFollow.Action {
            hf.update(previous: p, current: c, eligible: eligible, configuredInput: nil, configuredOutput: nil, enabled: enabled)
        }
        check("an output-only device is not a headset", up(base, base + [speakerOnly]) == .none)
        check("an empty previous list is no diff", up([], base + [pods]) == .none)
        check("a device that is not USB or Bluetooth is not followed", up(base, base + [pods], eligible: []) == .none)
        check("a headset is switched to", up(base, base + [pods]) == .switchTo("Pods"))
        check("a second headset takes over", up(base + [pods], base + [pods, usb]) == .switchTo("USB"))
        check("the first one going away changes nothing", up(base + [pods, usb], base + [usb]) == .none)
        check("the followed one going away reverts", up(base + [usb], base) == .revert)
        check("transport kinds: USB and Bluetooth only", AudioTransport.usb.isPhysicalHeadsetLink && AudioTransport.bluetooth.isPhysicalHeadsetLink
              && !AudioTransport.virtual.isPhysicalHeadsetLink && !AudioTransport.aggregate.isPhysicalHeadsetLink
              && !AudioTransport.builtIn.isPhysicalHeadsetLink && !AudioTransport.unknown.isPhysicalHeadsetLink)
        var hf2 = HeadsetFollow()
        check("a headset that is already configured is not announced", hf2.update(previous: base, current: base + [pods], eligible: all, configuredInput: "Pods", configuredOutput: "Pods", enabled: true) == .none)

        await quickKeysSelftest(model, mock: mock, check: { name, ok, detail in check(name, ok, detail) })

        // settings
        model.updateSettings { $0.codecOrder.swapAt(0, 1) }
        check("codec order saved", model.settingsStore.load().codecOrder.first == "G722/16000/1")
        model.updateSettings { $0.enabledCodecs = ["PCMU/8000/1"] }
        check("codec enabled saved", model.orderedEnabledCodecs == ["PCMU/8000/1"])

        // contacts and log
        model.saveContact(Contact(name: "Zed", number: "999"))
        check("contact saved", model.contacts.contains { $0.displayName == "Zed" })
        check("suggestions by letters", model.suggestions(for: "ze").first?.defaultNumber?.value == "999")
        if let z = model.contacts.first(where: { $0.displayName == "Zed" }) { model.deleteContact(z.id) }
        check("contact deleted", !model.contacts.contains { $0.displayName == "Zed" })

        // contact card (26.2): several numbers, photo, favorites, sort
        let alesia = model.contacts.first { $0.displayName == DemoPeople.alesia }
        let dzmitry = model.contacts.first { $0.displayName == DemoPeople.dzmitry }
        check("demo address book has photos and favourites",
              model.contacts.filter { $0.photo != nil }.count == 2 && model.contacts.filter(\.isFavorite).count == 2)
        check("photos are files beside contacts.json, not inside it",
              model.contacts.filter { $0.photo != nil }.allSatisfy { FileManager.default.fileExists(atPath: model.contactStore.photoDirectory.appendingPathComponent("\($0.id.uuidString).jpg").path) }
              && !((try? String(contentsOf: model.contactStore.photoDirectory.deletingLastPathComponent().appendingPathComponent("contacts.json"), encoding: .utf8))?.contains("\"photo\"") ?? true))
        let revisionBefore = model.contactsRevision
        model.saveContact(Contact(name: "Quick Save", number: "4242"))
        check("saving a contact updates the list in place", model.contactsRevision > revisionBefore && model.contact(forNumber: "4242")?.displayName == "Quick Save")
        if let q = model.contact(forNumber: "4242") { model.deleteContact(q.id) }
        check("deleting a contact drops it from the number index", model.contact(forNumber: "4242") == nil)
        check("photos are small JPEGs", model.contacts.compactMap(\.photo).allSatisfy { $0.count < 40_000 && $0.starts(with: [0xFF, 0xD8]) })
        check("alesia has two numbers, work is the default", alesia?.numbers.count == 2 && alesia?.defaultNumber?.label == .work)
        check("name resolves through a second number",
              dzmitry.map { model.name(for: RemoteParty(displayName: nil, uri: "sip:2231@pbx", number: "2231")) == $0.displayName } == true)
        check("name resolves ignoring spaces and dashes",
              model.contact(forNumber: "+375295550142")?.displayName == DemoPeople.alesia)
        check("organization-only contact shows its organization", model.contacts.contains { $0.displayName == "Help Desk" })
        check("search finds a contact by its third number", model.contacts.filter { $0.matches(query: "375 17 200") }.map(\.id) == [dzmitry?.id].compactMap { $0 })
        if var a = alesia {
            a.isFavorite = false
            model.saveContact(a)
            check("favourite toggles", model.contacts.filter(\.isFavorite).count == 1)
            a.isFavorite = true
            model.saveContact(a)
        }
        model.updateSettings { $0.general.contactSort = .lastName }
        check("sort setting saved", model.settingsStore.load().general.contactSort == .lastName)
        let byLast = Contact.sorted(model.contacts, by: model.settings.general.contactSort)
        let lastKeys = byLast.map { $0.sortKey(.lastName) }
        check("sorted by last name", lastKeys == lastKeys.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }, "\(lastKeys)")
        model.updateSettings { $0.general.contactSort = .firstName }
        model.placeCall(to: dzmitry ?? Contact(name: "x", number: "1"))
        await wait(0.4)
        let dialed = model.liveCalls.first { $0.remote.number == "+79125550123" }
        check("calling a contact dials its default number", dialed != nil, "\(model.liveCalls.map(\.remote.number))")
        if let c = dialed { model.hangup(c.id) }
        await wait(0.4)
        model.clearCallLog()
        check("log cleared", model.callLog.isEmpty)

        for r in await directorySelftest(model) { check(r.0, r.1, r.2) }

        await incomingRuleChecks(model) { check($0, $1, $2) }
        await networkChecks(model) { check($0, $1, $2) }

        let text = out.joined(separator: "\n") + "\nfailures=\(failures)\n"
        if let prefix = model.launch.snapshotPrefix { try? text.write(toFile: "\(prefix)-selftest.txt", atomically: true, encoding: .utf8) }
        print(text)
        quitLater()
    }

    /// "Reject calls from" (26.2): the rule reaches the mock, `knownNumbers` follows the contacts, and a rejected call
    /// never rings and is noted in the log.
    @MainActor
    static func incomingRuleChecks(_ model: AppModel, report: (String, Bool, String) -> Void) async {
        func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") { report(name, ok, ok ? "" : detail()) }
        func wait(_ s: Double) async { try? await Task.sleep(for: .seconds(s)) }
        let mock = model.engine as? MockEngine
        let expected = Set(model.contacts.flatMap { $0.numbers.map { Contact.normalize($0.value) } }.filter { !$0.isEmpty })
        check("known numbers are every number of every contact", !expected.isEmpty && model.knownNumbers == expected, "\(model.knownNumbers.count) of \(expected.count)")
        check("known numbers stay out of settings.json", model.settings.callOptions.knownNumbers.isEmpty)
        model.updateSettings { $0.callOptions.denyIncoming = .notInContacts }
        await wait(0.3)
        var options = await mock?.callOptions
        check("the rule reaches the engine with the known numbers", options?.denyIncoming == .notInContacts && options?.knownNumbers == expected,
              "\(String(describing: options?.denyIncoming)) \(options?.knownNumbers.count ?? -1)")
        check("the rule is stored", model.settingsStore.load().callOptions.denyIncoming == .notInContacts)
        model.saveContact(Contact(name: "Rule Test", number: "+7 (999) 123-45-67"))
        await wait(0.3)
        options = await mock?.callOptions
        check("a new contact's number reaches the engine, normalised", options?.knownNumbers.contains("+79991234567") == true, "\(String(describing: options?.knownNumbers))")
        // a stranger is turned away, a contact rings
        let logBefore = model.callLog.count
        await mock?.simulateIncoming(name: "Stranger", number: "9990001", account: officeID)
        await wait(0.3)
        check("a number not in Contacts is rejected without ringing", model.incomingCall == nil && model.calls.isEmpty)
        check("the rejection is noted in the log", model.callLog.count == logBefore + 1
              && model.callLog.first { $0.remoteNumber == "9990001" }?.note == CallLogNote.denied
              && model.callLog.first { $0.remoteNumber == "9990001" }?.direction == .missed
              && L.logNoteText(CallLogNote.denied) == L.logNoteDenied, "\(String(describing: model.callLog.first?.note))")
        await mock?.simulateIncoming(name: nil, number: "+7 999 123 45 67", account: officeID)
        await wait(0.3)
        check("a contact's number still rings", model.incomingCall?.remote.number == "+7 999 123 45 67", "\(model.calls.map(\.remote.number))")
        if let c = model.incomingCall { model.decline(c.id) }
        await wait(0.3)
        check("declining by hand is not noted as a rule", model.callLog.first { $0.remoteNumber == "+7 999 123 45 67" }?.note == nil)
        if let c = model.contacts.first(where: { $0.displayName == "Rule Test" }) { model.deleteContact(c.id) }
        await wait(0.3)
        options = await mock?.callOptions
        check("a deleted contact's number leaves the engine", options?.knownNumbers.contains("+79991234567") == false)
        // everyone, anonymous
        model.updateSettings { $0.callOptions.denyIncoming = .anonymous }
        await wait(0.3)
        await mock?.simulateIncoming(name: nil, number: "", account: officeID)
        await mock?.simulateIncoming(name: nil, number: "9990002", account: officeID)
        await wait(0.3)
        check("anonymous mode: the hidden number is rejected, a stranger rings", model.ringingCalls.map(\.remote.number) == ["9990002"]
              && model.callLog.first?.note == CallLogNote.denied, "\(model.ringingCalls.map(\.remote.number))")
        for c in model.ringingCalls { model.decline(c.id) }
        model.updateSettings { $0.callOptions.denyIncoming = .everyone }
        await wait(0.3)
        await mock?.simulateIncoming(name: nil, number: "100", account: officeID)
        await wait(0.3)
        check("everyone mode: nothing rings", model.incomingCall == nil && model.callLog.first?.note == CallLogNote.denied)
        model.updateSettings { $0.callOptions.denyIncoming = .nobody }
        await wait(0.3)
        await mock?.simulateIncoming(name: nil, number: "9990003", account: officeID)
        await wait(0.3)
        check("nobody mode: everyone rings", model.incomingCall?.remote.number == "9990003")
        if let c = model.incomingCall { model.decline(c.id) }
        await wait(0.3)
    }

    /// Network settings (26.2): rport applies at once, the port range and DNS ask for a restart of the engine.
    @MainActor
    static func networkChecks(_ model: AppModel, report: (String, Bool, String) -> Void) async {
        func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") { report(name, ok, ok ? "" : detail()) }
        func wait(_ s: Double) async { try? await Task.sleep(for: .seconds(s)) }
        /// Polls (the settings reach the engine after a 0.8 s debounce; a busy machine is slower).
        func until(_ ok: @MainActor () async -> Bool) async {
            for _ in 0..<40 { if await ok() { return }; await wait(0.25) }
        }
        let mock = model.engine as? MockEngine
        let defaults = NetworkSettings.default
        check("network defaults: ports 4000 +1000, rport on, SRV off, system nameserver",
              defaults.rtpPortStart == 4000 && defaults.rtpPortCount == 1000 && defaults.useRport && !defaults.dnsSRV && defaults.nameserver == nil)
        check("port range validation", RTPRange.validStart(1024, count: 1000) && !RTPRange.validStart(1023, count: 1000)
              && !RTPRange.validStart(65000, count: 1000) && RTPRange.validStart(64536, count: 1000) && !RTPRange.validCount(4, start: 4000))
        model.updateSettings { $0.network.useRport = false }
        await until { await mock?.network.useRport == false }
        check("rport applies without a restart", !model.networkRestartNeeded)
        let rport = await mock?.network.useRport
        check("rport reaches the engine", rport == false, "\(String(describing: rport)) ready \(model.engineReady)")
        model.updateSettings { $0.network.useRport = true; $0.network.dnsSRV = true; $0.network.nameserver = "10.0.0.53"; $0.network.rtpPortStart = 20000 }
        await until { model.networkRestartNeeded }
        check("port range and DNS ask for a restart", model.networkRestartNeeded, "ready \(model.engineReady)")
        model.restartEngineForNetwork()
        await wait(0.4)
        await until { if case .registered = model.registration[officeID] ?? .unregistered { return model.engineReady } else { return false } }
        let running = await mock?.network
        check("restarting applies them", !model.networkRestartNeeded && model.engineReady && running?.rtpPortStart == 20000
              && running?.dnsSRV == true && running?.nameserver == "10.0.0.53", "\(String(describing: running))")
        check("accounts register again after the restart", { if case .registered = model.registration[officeID] ?? .unregistered { return true } else { return false } }(), "\(String(describing: model.registration[officeID]))")
        let kept = await mock?.callOptions.knownNumbers
        check("known numbers survive the restart", kept == model.knownNumbers)
        model.updateSettings { $0.network = .default }
        await until { model.networkRestartNeeded }
        check("changing the range again asks for a restart", model.networkRestartNeeded)
        model.restartEngineForNetwork()
        await wait(0.4)
        await until { if case .registered = model.registration[officeID] ?? .unregistered { return model.engineReady } else { return false } }
    }

    /// Hold music, the recording notice, the voicemail indicator, the test tone, the sound events and the Google
    /// sign-in: every setting reaches the mock engine, every event reaches the model, the menu and the status bar.
    @MainActor
    static func soundChecks(_ model: AppModel, report: (String, Bool, String) -> Void) async {
        func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") { report(name, ok, ok ? "" : detail()) }
        func wait(_ s: Double) async { try? await Task.sleep(for: .seconds(s)) }
        func until(_ seconds: Double, _ condition: () async -> Bool) async {
            let end = Date().addingTimeInterval(seconds)
            while await !condition(), Date() < end { try? await Task.sleep(for: .milliseconds(50)) }
        }
        guard let mock = model.engine as? MockEngine else { check("sounds: mock engine", false); return }

        // hold music
        check("hold music: built-in reaches the engine at start", await mock.holdMusic == .builtIn)
        model.updateSettings { $0.audio.holdMusic = .off }
        await until(2) { await mock.holdMusic == .off }
        var hold = await mock.holdMusic
        check("hold music: off reaches the engine", hold == .off && model.holdMusicError == nil)
        let missing = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("macrosip-missing-\(UUID().uuidString).mp3")
        model.updateSettings { $0.audio.holdMusic = .file(missing) }
        await until(2) { model.holdMusicError != nil }
        hold = await mock.holdMusic
        check("hold music: an unreadable file is refused and the engine keeps the previous source",
              model.holdMusicError != nil && hold == .off, "\(String(describing: model.holdMusicError))")
        model.updateSettings { $0.audio.holdMusic = .builtIn }
        await until(2) { await mock.holdMusic == .builtIn }
        hold = await mock.holdMusic
        check("hold music: back to built-in clears the error", hold == .builtIn && model.holdMusicError == nil)
        check("hold music: stored", model.settingsStore.load().audio.holdMusic == .builtIn)

        // recording notice
        check("notice tone: off by default in the engine", await mock.recordingNotice.enabled == false)
        model.updateSettings { $0.recording.noticeTone = true; $0.recording.noticeToneIntervalSeconds = 20 }
        await until(2) { await mock.recordingNotice == (true, 20) }
        let notice = await mock.recordingNotice
        check("notice tone: switch and interval reach the engine", notice.enabled && notice.intervalSeconds == 20, "\(notice)")
        model.updateSettings { $0.recording.noticeToneIntervalSeconds = 2 }
        await until(2) { await mock.recordingNotice.intervalSeconds == 5 }
        let clamped = await mock.recordingNotice.intervalSeconds
        check("notice tone: an interval below 5 is clamped by the engine and when the file is read back",
              clamped == 5 && model.settingsStore.load().recording.noticeToneIntervalSeconds == 5, "\(clamped)")
        model.updateSettings { $0.recording.noticeTone = false; $0.recording.noticeToneIntervalSeconds = RecordingSettings.defaultNoticeInterval }
        await until(2) { await mock.recordingNotice.enabled == false }
        check("notice tone: off reaches the engine", await mock.recordingNotice.enabled == false)

        // voicemail indicator
        check("voicemail: nothing waiting at start", !model.voicemailWaiting && model.voicemailNewCount == 0)
        check("voicemail: Office has a number, Home has none", model.voicemailAccounts.map(\.id) == [officeID])
        await mock.simulateVoicemail(account: officeID, new: 2, old: 5)
        await until(2) { model.voicemail[officeID]?.new == 2 }
        check("voicemail: the event updates the model", model.voicemail[officeID] == VoicemailState(waiting: true, new: 2, old: 5)
              && model.voicemailWaiting && model.voicemailNewCount == 2, "\(model.voicemail)")
        var entries = StatusItemController.current?.debugMenuEntries() ?? []
        var item = entries.first { $0.title.hasPrefix(L.menuVoicemail) }
        check("voicemail: the menu bar item says 2 new and is enabled",
              item?.title == "\(L.menuVoicemail): \(L.voicemailNewCount(2))" && item?.enabled == true, "\(String(describing: item))")
        model.callVoicemail(for: officeID)
        await until(2) { !model.liveCalls.isEmpty }
        check("voicemail: the item calls the voicemail number through Office",
              model.liveCalls.first?.remote.number == "*97" && model.liveCalls.first?.accountID == officeID, "\(model.liveCalls.map(\.remote.number))")
        Task { await model.engine.hangupAll() }
        await until(2) { model.calls.isEmpty }
        await mock.simulateVoicemail(account: officeID, new: 0, old: 7)
        await until(2) { model.voicemail[officeID]?.new == 0 }
        entries = StatusItemController.current?.debugMenuEntries() ?? []
        item = entries.first { $0.title.hasPrefix(L.menuVoicemail) }
        check("voicemail: no messages: badge gone, item disabled", !model.voicemailWaiting && model.voicemailNewCount == 0 && item?.enabled == false,
              "\(String(describing: item))")
        check("voicemail: the engine snapshot matches", await mock.voicemailState(for: officeID) == model.voicemail[officeID])

        // test tone
        model.updateSettings { $0.audio.outputDeviceName = "USB Headset" }
        model.playTestTone()
        await until(2) { await !mock.testTones.isEmpty }
        let tone = await mock.testTones.last
        let tonePlaying = await mock.testTonePlaying
        check("test tone: played on the chosen speaker for 2 s", tone?.device == "USB Headset" && tone?.seconds == 2 && tonePlaying,
              "\(String(describing: tone))")
        let tonesBefore = await mock.testTones.count
        model.updateSettings { $0.audio.outputDeviceName = "Unplugged Speaker" }
        model.playTestTone()
        await until(2) { await mock.testTones.count > tonesBefore }
        let fallback = await mock.testTones.last
        check("test tone: a speaker that is not connected falls back to the system default", await mock.testTones.count > tonesBefore && fallback?.device == nil,
              "\(String(describing: fallback))")
        model.updateSettings { $0.audio.outputDeviceName = nil }

        // sound events: on
        await mock.clearPlayedSounds()
        model.updateSettings { $0.audio.soundEvents = SoundEventSettings(callEvents: true, keyPress: true, voicemail: true, error: true) }
        model.dialPadPressed("5")
        model.dialPadPressed("+")
        await until(2) { await mock.playedSounds.contains(.keyPress("5")) }
        var played = await mock.playedSounds
        check("sounds: a dial pad key plays its DTMF tone outside a call, + plays nothing",
              played == [.keyPress("5")] && model.dialText == "5+", "\(played) \(model.dialText)")
        model.dialText = ""
        await mock.clearPlayedSounds()
        model.placeCall(to: "100")
        await until(4) { model.activeCall?.state == .connected }
        await until(2) { await mock.playedSounds.contains(.callConnected) }
        played = await mock.playedSounds
        check("sounds: connected plays once", played == [.callConnected], "\(played)")
        if let c = model.activeCall { model.toggleHold(c) }
        await wait(0.2)
        if let c = model.currentCall { model.toggleHold(c) }
        await wait(0.2)
        played = await mock.playedSounds
        check("sounds: resume after hold is not a new connection", played == [.callConnected], "\(played)")
        model.dialPadPressed("1")
        await wait(0.2)
        played = await mock.playedSounds
        check("sounds: no key tone during a call", !played.contains(.keyPress("1")))
        model.dialText = ""
        if let c = model.currentCall { model.hangup(c.id) }
        await until(2) { await mock.playedSounds.contains(.callEnded) }
        played = await mock.playedSounds
        check("sounds: ended plays", played == [.callConnected, .callEnded], "\(played)")
        await mock.clearPlayedSounds()
        await mock.simulateVoicemail(account: officeID, new: 1, old: 7)
        await until(2) { await mock.playedSounds.contains(.voicemail) }
        played = await mock.playedSounds
        check("sounds: new voicemail plays", played == [.voicemail], "\(played)")
        await mock.simulateVoicemail(account: officeID, new: 0, old: 8)
        await wait(0.3)
        played = await mock.playedSounds
        check("sounds: messages gone plays nothing", played == [.voicemail], "\(played)")
        await mock.clearPlayedSounds()
        await mock.simulateNetwork(online: false)
        await until(2) { await mock.playedSounds.contains(.error) }
        await mock.simulateNetwork(online: true)
        await wait(0.3)
        await mock.simulateNetwork(online: false)
        await wait(0.3)
        played = await mock.playedSounds
        check("sounds: lost network plays the error sound once within 10 s", played == [.error], "\(played)")
        await mock.simulateNetwork(online: true)
        await until(3) { if case .registered = model.registration[officeID] ?? .unregistered { return true } else { return false } }

        // sound events: off
        model.lastErrorSoundAt = nil
        model.updateSettings { $0.audio.soundEvents = SoundEventSettings() }
        await mock.clearPlayedSounds()
        model.dialPadPressed("7")
        model.dialText = ""
        model.placeCall(to: "100")
        await until(4) { model.activeCall?.state == .connected }
        if let c = model.currentCall { model.hangup(c.id) }
        await until(2) { model.calls.isEmpty }
        await mock.simulateVoicemail(account: officeID, new: 3, old: 0)
        await mock.simulateNetwork(online: false)
        await wait(0.5)
        await mock.simulateNetwork(online: true)
        await until(3) { if case .registered = model.registration[officeID] ?? .unregistered { return true } else { return false } }
        played = await mock.playedSounds
        check("sounds: nothing plays when the switches are off", played.isEmpty, "\(played)")
        await mock.simulateVoicemail(account: officeID, new: 0, old: 0)
        check("sounds: settings stored", model.settingsStore.load().audio.soundEvents == SoundEventSettings())

        // headset buttons setting
        model.updateSettings { $0.audio.headsetButtons = false }
        check("headset buttons: the setting switches the controller off", !model.headsetButtonsEnabled && model.headsetButtonsDevice == nil)
        model.updateSettings { $0.audio.headsetButtons = true }
        check("headset buttons: on again and stored", model.headsetButtonsEnabled && model.settingsStore.load().audio.headsetButtons)

        // Google sign-in (mock: andrei@gmail.com after a second)
        let google = DirectorySource(id: UUID(), kind: .google, name: "Google Contacts", google: GoogleConfig())      // not the directory demo's id: that one is announced by the mock later
        model.saveDirectorySource(google)
        await wait(0.3)
        check("google: a new source is not forced to sign in required in a demo", model.directory.statuses[google.id] != .signInRequired,
              "\(String(describing: model.directory.statuses[google.id]))")
        model.directory.statuses[google.id] = .signInRequired
        model.signInToGoogle(google)
        await wait(0.2)
        check("google: the sign-in is running", model.directory.signingIn.contains(google.id))
        await until(3) { model.settings.directory.sources.first { $0.id == google.id }?.google?.accountEmail != nil }
        check("google: sign-in stores the e-mail and connects the source",
              model.settings.directory.sources.first { $0.id == google.id }?.google?.accountEmail == "andrei@gmail.com"
              && model.directory.statuses[google.id] == .connected && !model.directory.signingIn.contains(google.id)
              && model.directory.signInMessages[google.id] == nil,
              "\(String(describing: model.settings.directory.sources.first { $0.id == google.id }?.google)) \(String(describing: model.directory.statuses[google.id]))")
        check("google: the e-mail is stored", model.settingsStore.load().directory.sources.first { $0.id == google.id }?.google?.accountEmail == "andrei@gmail.com")
        model.signInToGoogle(google)
        await wait(0.2)
        model.cancelGoogleSignIn()
        await wait(0.3)
        check("google: a cancelled sign-in shows nothing", model.directory.signInMessages[google.id] == nil && !model.directory.signingIn.contains(google.id))
        model.removeDirectorySource(google.id)
        model.updateSettings { $0.directory = DirectorySettings() }
    }

    /// Headset call-control buttons (`Platform/HeadsetButtons.swift`): the report decoder, then the hook, mute and
    /// redial actions through the `simulate` seam, with the LED state the headset would be shown.
    @MainActor
    static func headsetChecks(_ model: AppModel, report: (String, Bool, String) -> Void) async {
        func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") { report(name, ok, ok ? "" : detail()) }
        /// Polls: events hop from the controller's queue to the main actor and the mock answers asynchronously.
        func until(_ seconds: Double = 3, _ condition: @MainActor () async -> Bool) async {
            let end = Date().addingTimeInterval(seconds)
            while await !condition(), Date() < end { try? await Task.sleep(for: .milliseconds(50)) }
        }
        let mock = model.engine as? MockEngine
        let tfon: UInt32 = 0x0B, hook: UInt32 = 0x20

        var button = HeadsetReportDecoder(hookHasPreferredState: true)
        check("headset: hook button press", button.decode(page: tfon, usage: hook, value: 1, at: 0) == .hookPress
              && button.decode(page: tfon, usage: hook, value: 0, at: 0.05) == nil)
        var sw = HeadsetReportDecoder(hookHasPreferredState: false)
        check("headset: hook switch levels", sw.decode(page: tfon, usage: hook, value: 1, at: 0) == .offHook
              && sw.decode(page: tfon, usage: hook, value: 0, at: 1.0) == .onHook
              && sw.decode(page: tfon, usage: hook, value: 1, at: 5) == .offHook
              && sw.decode(page: tfon, usage: hook, value: 0, at: 5.6) == .onHook && sw.hookStyle == .level)
        var learned = HeadsetReportDecoder(hookHasPreferredState: false)
        _ = learned.decode(page: tfon, usage: hook, value: 1, at: 0)
        check("headset: a switch released within 300 ms becomes a button",
              learned.decode(page: tfon, usage: hook, value: 0, at: 0.1) == nil && learned.hookStyle == .momentary
              && learned.decode(page: tfon, usage: hook, value: 1, at: 2) == .hookPress)
        var long = HeadsetReportDecoder(hookHasPreferredState: false)
        let answered = long.decode(page: tfon, usage: hook, value: 1, at: 10) == .offHook
        long.noteAnswered(at: 10.05)
        check("headset: a 600 ms press that answered a call does not hang it up and becomes a button",
              answered && long.decode(page: tfon, usage: hook, value: 0, at: 10.6) == nil && long.hookStyle == .momentary
              && long.decode(page: tfon, usage: hook, value: 1, at: 12) == .hookPress
              && long.decode(page: tfon, usage: hook, value: 0, at: 12.6) == nil)
        var handset = HeadsetReportDecoder(hookHasPreferredState: false)
        _ = handset.decode(page: tfon, usage: hook, value: 1, at: 20)
        handset.noteAnswered(at: 20.05)
        check("headset: a switch put back after the answer window hangs up and stays a switch",
              handset.decode(page: tfon, usage: hook, value: 0, at: 21.5) == .onHook && handset.hookStyle == .level)
        var idle = HeadsetReportDecoder(hookHasPreferredState: false)
        idle.noteAnswered(at: 30)                                                  // no press pending: ignored
        _ = idle.decode(page: tfon, usage: hook, value: 1, at: 31)
        check("headset: an answer noted without a press pending does not count",
              idle.decode(page: tfon, usage: hook, value: 0, at: 31.6) == .onHook && idle.hookStyle == .level)
        check("headset: mute, redial, flash on the rising edge; other pages ignored",
              sw.decode(page: tfon, usage: 0x2F, value: 1, at: 2) == .mute && sw.decode(page: tfon, usage: 0x2F, value: 0, at: 2.1) == nil
              && sw.decode(page: tfon, usage: 0x24, value: 1, at: 3) == .redial && sw.decode(page: tfon, usage: 0x21, value: 1, at: 4) == .flash
              && sw.decode(page: 0x0C, usage: 0xE2, value: 1, at: 5) == nil)

        guard let headset = model.headsetButtons else { check("headset: controller exists", false); return }
        check("headset: enabled by default, no device", model.headsetButtonsEnabled && model.headsetButtonsDevice == nil)
        check("headset: LEDs off while idle", headset.currentIndicators() == HeadsetIndicators())
        await mock?.simulateIncoming(name: nil, number: "601", account: officeID)
        await until { model.incomingCall?.remote.number == "601" && headset.currentIndicators().ring }
        check("headset: ring LED while ringing", headset.currentIndicators() == HeadsetIndicators(offHook: false, ring: true, mute: false),
              "\(headset.currentIndicators())")
        headset.simulate(.offHook)
        await until { model.activeCall?.remote.number == "601" && model.incomingCall == nil && headset.currentIndicators().offHook }
        check("headset: off-hook answers", model.activeCall?.remote.number == "601" && model.incomingCall == nil,
              "\(model.liveCalls.map { ($0.remote.number, $0.state) })")
        check("headset: off-hook LED on a call", headset.currentIndicators() == HeadsetIndicators(offHook: true, ring: false, mute: false),
              "\(headset.currentIndicators())")
        headset.simulate(.mute)
        await until { model.currentCall?.isMuted == true && headset.currentIndicators().mute }
        check("headset: mute toggles on", model.currentCall?.isMuted == true && headset.currentIndicators().mute)
        headset.simulate(.mute)
        await until { model.currentCall?.isMuted == false && !headset.currentIndicators().mute }
        check("headset: mute toggles off", model.currentCall?.isMuted == false && !headset.currentIndicators().mute)
        await mock?.simulateIncoming(name: nil, number: "602", account: officeID)
        await until { model.incomingCall?.remote.number == "602" }
        headset.simulate(.hookPress)
        await until { model.activeCall?.remote.number == "602" && model.heldCount == 1 && model.incomingCall == nil }
        check("headset: hook press answers the waiting call and holds the first",
              model.activeCall?.remote.number == "602" && model.heldCount == 1 && model.incomingCall == nil,
              "\(model.liveCalls.map { ($0.remote.number, $0.isHeldCall) })")
        headset.simulate(.onHook)
        await until { model.activeCall == nil && model.liveCalls.map(\.remote.number) == ["601"] }
        check("headset: on-hook ends the active call, the held one stays",
              model.activeCall == nil && model.liveCalls.map(\.remote.number) == ["601"], "\(model.liveCalls.map(\.remote.number))")
        headset.simulate(.hookPress)
        await until { model.calls.isEmpty && headset.currentIndicators() == HeadsetIndicators() }
        check("headset: hook press hangs up the held call", model.calls.isEmpty, "\(model.liveCalls.map(\.remote.number))")
        check("headset: LEDs off after the calls", headset.currentIndicators() == HeadsetIndicators(), "\(headset.currentIndicators())")
        let last = model.lastDialedNumber
        headset.simulate(.redial)
        await until { model.liveCalls.first?.remote.number == last }
        check("headset: redial calls the last outgoing number", last != nil && model.liveCalls.first?.remote.number == last,
              "\(String(describing: last)) \(model.liveCalls.map(\.remote.number))")
        headset.simulate(.redial)
        try? await Task.sleep(for: .milliseconds(300))                            // nothing should happen: give it time not to
        check("headset: redial does nothing during a call", model.liveCalls.count == 1, "\(model.liveCalls.map(\.remote.number))")
        await model.engine.hangupAll()
        await until { model.calls.isEmpty }
        model.setHeadsetButtonsEnabled(false)
        check("headset: switched off", !model.headsetButtonsEnabled && model.headsetButtonsDevice == nil)
        model.setHeadsetButtonsEnabled(true)
        check("headset: switched on again", model.headsetButtonsEnabled && model.headsetButtons != nil)
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
        Task { await mock.simulateIncoming(name: DemoPeople.andrei, number: "101", account: acct) }
    }
}

#endif


/// Sample people for demo launches and the mock engine. The spelling follows the app's language
/// (Cyrillic when it is Russian), so snapshots in each language read naturally.
enum DemoPeople {
    private static let russian = Locale.preferredLanguages.first?.hasPrefix("ru") == true
    private static func pick(_ latin: String, _ cyrillic: String) -> String { russian ? cyrillic : latin }

    static var alesiaNote: String { pick("Prefers calls after 10:00. Assistant: \(volha) (103).", "Лучше звонить после 10:00. Помощник: \(volha) (103).") }
    static var alesia: String { pick("Alesia Kazlouskaya", "Алеся Козловская") }
    static var andrei: String { pick("Andrei Kavaliou", "Андрей Ковалёв") }
    static var volha: String { pick("Volha Marozava", "Ольга Морозова") }
    static var dzmitry: String { pick("Dzmitry Navitski", "Дмитрий Новицкий") }
    static var katsiaryna: String { pick("Katsiaryna Zhuk", "Екатерина Жук") }
    static var siarhei: String { pick("Siarhei Lukashevich", "Сергей Лукашевич") }
    static var maryna: String { pick("Maryna Sakalouskaya", "Марина Соколовская") }
    static var yauheni: String { pick("Yauheni Marozau", "Евгений Морозов") }
    static var natallia: String { pick("Natallia Karpovich", "Наталья Карпович") }
    static var aliaksandr: String { pick("Aliaksandr Hrytsuk", "Александр Грицук") }
    static var kate: String { pick("Kate Imported", "Катя Импортова") }
    static var lev: String { pick("Lev Imported", "Лев Импортов") }
    static var kasia: String { pick("Kasia Wolska", "Ксения Каменская") }
    static var pavel: String { pick("Pavel Karnatski", "Павел Карнацкий") }
}
