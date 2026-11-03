import Foundation
import MacroSIPCore
#if DEBUG
import AppKit

/// Demo states of the global hotkeys and the MicroSIP import (26.1):
///   settings-hotkeys      Settings › Calls with the hotkeys on; the Mute field shows the "used by another app" message
///   import-microsip       Settings › Accounts with the Import from MicroSIP preview open (sample files in a temp folder)
///   import-microsip-done  the same after pressing Import (the report step)
///   hotkeys-selftest      only the hotkey checks of `selftest` (registers real hotkeys briefly: Control-Option-Shift-Command with F13 to F16)
///   import-selftest       only the import checks of `selftest`
extension DemoState {
    static func isHotkeyImportState(_ state: String) -> Bool {
        ["settings-hotkeys", "import-microsip", "import-microsip-done", "hotkeys-selftest", "import-selftest"].contains(state)
    }

    @MainActor
    static func runHotkeyImport(_ model: AppModel, state: String) async {
        try? await Task.sleep(for: .seconds(1.2))
        switch state {
        case "settings-hotkeys":
            model.updateSettings { $0.hotkeys = HotkeySettings(enabled: true, answer: .defaultAnswer, hangUp: .defaultHangUp, mute: .defaultMute, prefilled: true) }
            model.hotkeyFailures = [.mute: .inUse]          // what a refused registration looks like; nothing is registered in a demo
            model.openSettings(tab: .calls)
        case "import-microsip", "import-microsip-done":
            let ini = writeMicroSIPSamples(existingNumber: model.contacts.first?.defaultNumber?.value ?? "100")
            model.openSettings(tab: .accounts)
            try? await Task.sleep(for: .seconds(0.8))
            model.beginMicroSIPImport(ini: ini)
            if state == "import-microsip-done" {
                try? await Task.sleep(for: .seconds(0.5))
                model.applyMicroSIPImport()
            }
        case "hotkeys-selftest":
            var results: [(String, Bool, String)] = []
            await hotkeyChecks(model) { results.append(($0, $1, $2)) }
            finishChecks(model, results)
        case "import-selftest":
            var results: [(String, Bool, String)] = []
            await importChecks(model) { results.append(($0, $1, $2)) }
            finishChecks(model, results)
        default: break
        }
    }

    @MainActor
    private static func finishChecks(_ model: AppModel, _ results: [(String, Bool, String)]) {
        let failures = results.filter { !$0.1 }.count
        let text = results.map { "\($0.1 ? "PASS" : "FAIL") \($0.0) \($0.2)" }.joined(separator: "\n") + "\nfailures=\(failures)\n"
        if let prefix = model.launch.snapshotPrefix { try? text.write(toFile: "\(prefix)-selftest.txt", atomically: true, encoding: .utf8) }
        print(text)
        quitLater()
    }

    // MARK: Sample files

    /// A MicroSIP.ini and a Contacts.xml in a new temporary folder. The ini holds two new accounts, one that
    /// MacroSIP already has (the demo Office account), one without a user name, one without a server, one with a
    /// transport nobody knows and a dial plan, and "encrypted" passwords that must never reach the app.
    static func writeMicroSIPSamples(existingNumber: String) -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MacroSIP-import-sample-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let ini = """
        [Settings]
        accountId=2
        [Account1]
        label=Work PBX
        server=pbx2.example.org
        username=2001
        domain=pbx2.example.org
        displayName=Andrei K
        transport=tls
        srtp=optional
        voicemailNumber=*98
        password=0A1B2C3D4E5F
        [Account2]
        server=sip.provider.org:5070
        proxy=sip:edge.provider.org;transport=tcp
        username=andrei2
        domain=provider.org
        displayName=Home
        transport=sctp
        dialingPrefix=00
        password=DEADBEEF
        [Account3]
        username=7000
        [Account4]
        server=pbx.example.com
        username=1001
        domain=pbx.example.com
        password=FEEDFACE
        [Account5]
        server=no-user.example.org
        """
        let contacts = """
        <?xml version="1.0" encoding="UTF-8"?>
        <contacts>
        <contact name="Maria Ivanova" number="1201" presence="1" comment="front desk"/>
        <contact name="Oleg Petrov" number="1202" mobile="+375291112233"/>
        <contact name="No Number" number=""/>
        <contact name="LDAP Person" number="3001" directory="1"/>
        <contact name="Already Here" number="\(existingNumber)"/>
        <contact name="Oleg Again" number="1202"/>
        </contacts>
        """
        let url = folder.appendingPathComponent("MicroSIP.ini")
        try? ini.write(to: url, atomically: true, encoding: .utf8)
        try? contacts.write(to: folder.appendingPathComponent("Contacts.xml"), atomically: true, encoding: .utf8)
        return url
    }

    // MARK: Hotkey checks

    /// Registration with the system (real Carbon calls, with combinations nobody uses), the conflict path, and what each
    /// action does to the mock engine's calls. A press is simulated after Carbon's callback: no real key is pressed.
    @MainActor
    static func hotkeyChecks(_ model: AppModel, report: (String, Bool, String) -> Void) async {
        func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") { report("hotkeys: " + name, ok, ok ? "" : detail()) }
        func until(_ seconds: Double = 3, _ condition: @MainActor () async -> Bool) async {
            let end = Date().addingTimeInterval(seconds)
            while await !condition(), Date() < end { try? await Task.sleep(for: .milliseconds(50)) }
        }
        func settle() async { try? await Task.sleep(for: .milliseconds(350)) }      // for a press that should do nothing
        let mock = model.engine as? MockEngine
        let all: HotkeyModifiers = [.control, .option, .shift, .command]
        let f13 = HotkeyCombo(keyCode: 105, modifiers: all), f14 = HotkeyCombo(keyCode: 107, modifiers: all)
        let f15 = HotkeyCombo(keyCode: 113, modifiers: all), f16 = HotkeyCombo(keyCode: 106, modifiers: all)
        guard let hotkeys = model.globalHotkeys else { check("controller exists", false); return }

        // Off by default; demo launches register nothing even when switched on.
        check("off by default, nothing registered", !model.settings.hotkeys.enabled && hotkeys.activeCombos.isEmpty)
        model.setHotkeysEnabled(true)
        check("first switch-on pre-fills the three defaults", model.settings.hotkeys.answer?.display == "⌃⌥A"
              && model.settings.hotkeys.hangUp?.display == "⌃⌥H" && model.settings.hotkeys.mute?.display == "⌃⌥M")
        check("a demo launch registers nothing for real", hotkeys.activeCombos.isEmpty, "\(hotkeys.activeCombos)")
        model.setHotkeysEnabled(false)
        check("switch-off is stored", !model.settingsStore.load().hotkeys.enabled)

        // Real registration, with combinations nobody uses.
        model.hotkeysInDemo = true
        model.updateSettings { $0.hotkeys = HotkeySettings(enabled: false, answer: f13, hangUp: f14, mute: f15, prefilled: true) }
        model.setHotkeysEnabled(true)
        check("registered with the system: all three", hotkeys.activeCombos == [.answer: f13, .hangUp: f14, .mute: f15] && model.hotkeyFailures.isEmpty,
              "\(hotkeys.activeCombos) \(model.hotkeyFailures)")

        // Conflict: another holder of a combination. A second controller stands in for another app.
        let other = GlobalHotkeys { _ in }
        let probe = GlobalHotkeys { _ in }
        let blocker = other.apply([.mute: f16])
        let refused = probe.apply([.answer: f13])        // f13 is held by the app's own controller
        check("a second holder of the same combination is refused (the system's answer)", blocker.isEmpty && refused == [.answer: .inUse],
              "blocker \(blocker), second registration \(refused)")
        probe.stop()
        model.setHotkey(f16, for: .mute)
        check("conflict: the field gets the error, the others keep working",
              model.hotkeyFailures == [.mute: .inUse] && hotkeys.activeCombos == [.answer: f13, .hangUp: f14],
              "\(model.hotkeyFailures) \(hotkeys.activeCombos)")
        other.stop()
        model.setHotkey(f15, for: .mute)
        check("freeing the combination and choosing again works", model.hotkeyFailures.isEmpty && hotkeys.activeCombos[.mute] == f15,
              "\(model.hotkeyFailures) \(hotkeys.activeCombos)")

        // Validation through the model.
        model.setHotkey(HotkeyCombo(keyCode: 0, modifiers: .shift), for: .answer)
        check("Shift alone is refused, the old combination stays", model.hotkeyIssues[.answer] == .needsModifier && model.settings.hotkeys.answer == f13)
        model.setHotkey(f14, for: .answer)
        check("the same combination on two actions is refused", model.hotkeyIssues[.answer] == .duplicate(of: .hangUp) && model.settings.hotkeys.answer == f13)
        model.setHotkey(HotkeyCombo(keyCode: 2, modifiers: .command), for: .answer)
        check("a menu shortcut is refused", model.hotkeyIssues[.answer] == .usedByMenu)
        model.setHotkey(f13, for: .answer)
        check("a valid choice clears the message", model.hotkeyIssues[.answer] == nil)
        model.setHotkeyRecording(true)
        check("nothing is registered while a recorder listens", hotkeys.activeCombos.isEmpty)
        model.setHotkeyRecording(false)
        check("registered again afterwards", hotkeys.activeCombos.count == 3)

        // Actions.
        await model.engine.hangupAll()
        await until { model.calls.isEmpty }
        hotkeys.simulatePress(.answer); hotkeys.simulatePress(.hangUp); hotkeys.simulatePress(.mute)
        await settle()
        check("with no call, all three do nothing", model.calls.isEmpty && model.banner == nil, "\(model.calls.count) \(String(describing: model.banner))")

        await mock?.simulateIncoming(name: nil, number: "701", account: officeID)
        await mock?.simulateIncoming(name: nil, number: "702", account: officeID)
        await until { model.ringingCalls.count == 2 }
        hotkeys.simulatePress(.mute)
        await settle()
        check("mute does nothing while calls only ring", model.ringingCalls.count == 2 && model.liveCalls.isEmpty)
        hotkeys.simulatePress(.answer)
        await until { model.activeCall?.remote.number == "701" }
        check("answer takes the oldest ringing call", model.activeCall?.remote.number == "701" && model.ringingCalls.map(\.remote.number) == ["702"],
              "\(model.calls.map { ($0.remote.number, $0.state) })")
        hotkeys.simulatePress(.mute)
        await until { model.currentCall?.isMuted == true }
        check("mute toggles the current call on", model.currentCall?.isMuted == true)
        hotkeys.simulatePress(.mute)
        await until { model.currentCall?.isMuted == false }
        check("and off again", model.currentCall?.isMuted == false)
        hotkeys.simulatePress(.hangUp)
        await until { model.liveCalls.isEmpty }
        check("hang up ends the connected call and leaves the ringing one", model.liveCalls.isEmpty && model.ringingCalls.map(\.remote.number) == ["702"],
              "\(model.calls.map { ($0.remote.number, $0.state) })")
        hotkeys.simulatePress(.hangUp)
        await until { model.calls.isEmpty }
        check("with only a ringing call, hang up declines it", model.calls.isEmpty && model.callLog.first?.remoteNumber == "702" ,
              "\(model.calls.count) \(String(describing: model.callLog.first?.remoteNumber))")
        hotkeys.simulatePress(.answer)
        await settle()
        check("answer with nothing ringing does nothing", model.calls.isEmpty)

        // Attended transfer: Hang up does what End Call does (the consultation call, the original stays held).
        model.placeCall(to: "703")
        await until { model.activeCall?.remote.number == "703" && model.activeCall?.state == .connected }
        if let first = model.activeCall {
            model.startAttendedTransfer(first, to: "704")
            await until { model.liveCalls.count == 2 && model.activeCall?.remote.number == "704" }
            check("attended transfer set up", model.transfer != nil && model.activeCall?.remote.number == "704", "\(model.liveCalls.map(\.remote.number))")
            hotkeys.simulatePress(.hangUp)
            await until { model.liveCalls.map(\.remote.number) == ["703"] }
            check("during an attended transfer hang up ends the consultation call, like End Call", model.liveCalls.map(\.remote.number) == ["703"],
                  "\(model.liveCalls.map(\.remote.number))")
            model.transfer = nil
        } else { check("attended transfer set up", false, "no active call") }
        await model.engine.hangupAll()
        await until { model.calls.isEmpty }

        // Conference: Hang up ends it as a whole, like End Conference.
        model.placeCall(to: "705")
        await until { model.activeCall?.remote.number == "705" && model.activeCall?.state == .connected }
        model.placeCall(to: "706")
        await until { model.liveCalls.count == 2 && model.activeCall?.remote.number == "706" && model.activeCall?.state == .connected }
        model.mergeCalls()
        await until { model.conferenceCalls.count == 2 }
        check("conference set up", model.conferenceCalls.count == 2, "\(model.liveCalls.map { ($0.remote.number, $0.inConference) })")
        hotkeys.simulatePress(.hangUp)
        await until { model.calls.isEmpty }
        check("during a conference hang up ends all legs, like End Conference", model.calls.isEmpty, "\(model.calls.map(\.remote.number))")

        // Switching off and shutdown.
        model.setHotkeysEnabled(false)
        check("switching off releases every hotkey", hotkeys.activeCombos.isEmpty && model.hotkeyFailures.isEmpty)
        model.hotkeysInDemo = false
        model.updateSettings { $0.hotkeys = HotkeySettings() }
        hotkeys.stop()
        hotkeys.stop()
        check("stop twice does not crash, nothing stays registered", hotkeys.activeCombos.isEmpty)
        model.stopHotkeys()
        model.startHotkeys()
        check("controller can be restarted (as after a shutdown)", model.globalHotkeys != nil && model.globalHotkeys?.activeCombos.isEmpty == true)
    }

    // MARK: Import checks

    @MainActor
    static func importChecks(_ model: AppModel, report: (String, Bool, String) -> Void) async {
        func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") { report("import: " + name, ok, ok ? "" : detail()) }
        func until(_ seconds: Double = 3, _ condition: @MainActor () async -> Bool) async {
            let end = Date().addingTimeInterval(seconds)
            while await !condition(), Date() < end { try? await Task.sleep(for: .milliseconds(50)) }
        }
        let existing = model.contacts.first?.defaultNumber?.value ?? "100"
        let accountsBefore = model.accounts.count, contactsBefore = model.contacts.count
        let ini = writeMicroSIPSamples(existingNumber: existing)
        let samples = ini.deletingLastPathComponent()

        model.beginMicroSIPImport(ini: ini)
        guard let session = model.microSIPImport, case let .preview(merge) = session.outcome else { check("preview opens", false); return }
        check("Contacts.xml next to the ini is found", session.contactsURL?.lastPathComponent == "Contacts.xml")
        check("preview: two new accounts, one duplicate, contacts 2 + 4 skipped/dropped",
              merge.accounts.count == 2 && merge.skippedAccounts.count == 1 && merge.contacts.count == 2 && merge.skippedContacts.count == 2,
              "\(merge.accounts.count) \(merge.skippedAccounts.count) \(merge.contacts.count) \(merge.skippedContacts.count)")
        let warningTexts = merge.warnings.map(MicroSIPImportSheet.text(for:))
        check("every warning case in the sample has a localized text", warningTexts.count == merge.warnings.count && warningTexts.count == 6
              && !warningTexts.contains(where: \.isEmpty), "\(warningTexts)")
        check("nothing written by the preview", model.accounts.count == accountsBefore && model.contacts.count == contactsBefore)

        model.setMicroSIPContacts(nil)
        if case let .preview(m)? = model.microSIPImport?.outcome { check("choosing no contacts file drops the contacts", m.contacts.isEmpty && model.microSIPImport?.contactsURL == nil) }
        else { check("choosing no contacts file drops the contacts", false) }
        model.setMicroSIPContacts(samples.appendingPathComponent("Contacts.xml"))
        if case let .preview(m)? = model.microSIPImport?.outcome { check("choosing the file again brings them back", m.contacts.count == 2) }
        else { check("choosing the file again brings them back", false) }

        model.cancelMicroSIPImport()
        check("Cancel changes nothing", model.microSIPImport == nil && model.accounts.count == accountsBefore && model.contacts.count == contactsBefore
              && model.accountStore.all().count == accountsBefore && model.contactStore.all().count == contactsBefore)

        // A file that is not MicroSIP.ini gives a typed error.
        let bad = samples.appendingPathComponent("Other.ini")
        try? "[Settings]\nfoo=1\n".write(to: bad, atomically: true, encoding: .utf8)
        model.beginMicroSIPImport(ini: bad)
        if case .failed(.noAccountSections)? = model.microSIPImport?.outcome {
            check("an ini without accounts is a localized error", !MicroSIPImportSheet.text(for: .noAccountSections).isEmpty)
        } else { check("an ini without accounts is a localized error", false, "\(String(describing: model.microSIPImport?.outcome))") }
        model.cancelMicroSIPImport()

        // The import itself.
        model.beginMicroSIPImport(ini: ini)
        model.applyMicroSIPImport()
        let added = model.accounts.filter { ($0.username == "2001" && $0.domain == "pbx2.example.org") || ($0.username == "andrei2" && $0.domain == "provider.org") }
        check("two accounts and two contacts added", model.accounts.count == accountsBefore + 2 && model.contacts.count == contactsBefore + 2 && added.count == 2,
              "\(model.accounts.count) \(model.contacts.count)")
        check("they are stored (accounts.json, contacts.json)", model.accountStore.all().count == accountsBefore + 2 && model.contactStore.all().count == contactsBefore + 2)
        check("disabled, not in the engine", added.allSatisfy { !$0.enabled && !model.engineAccounts.contains($0.id) })
        check("the existing default stays the default", model.accounts.filter(\.isDefaultOutgoing).count == 1 && model.defaultAccount?.id == officeID)
        let work = added.first { $0.username == "2001" }, home = added.first { $0.username == "andrei2" }
        check("caller names stored like the editor stores them", work.map { model.callerName(for: $0.id) } == "Andrei K" && home.map { model.callerName(for: $0.id) } == "Home")
        check("fields mapped", work?.transport == .tls && work?.srtp == .optional && work?.voicemailNumber == "*98"
              && home?.transport == .udp && home?.registrar == "sip.provider.org:5070" && home?.outboundProxy == "edge.provider.org",
              "\(String(describing: work)) \(String(describing: home))")
        check("no password anywhere", added.allSatisfy { model.vault.password(for: $0.id) == nil })
        check("imported accounts need a password", added.allSatisfy { model.accountNeedsPassword($0.id) } && !model.accountNeedsPassword(officeID))
        check("contacts have the numbers", model.contacts.contains { $0.hasNumber("1201") } && model.contacts.contains { $0.hasNumber("+375291112233") })
        check("the report is shown", model.microSIPImport?.report?.accounts.count == 2 && model.microSIPImport?.report?.contacts == 2, "\(String(describing: model.microSIPImport?.report))")
        check("a banner reports it", model.banner?.isError == false && model.banner?.text.isEmpty == false, "\(String(describing: model.banner?.text))")
        let firstID = model.microSIPImport?.report?.firstAccount
        model.finishMicroSIPImport(openEditor: true)
        await until { model.settingsEditor != nil }
        check("the editor opens for the first imported account", model.settingsEditor?.accountID == firstID && firstID == work?.id, "\(String(describing: model.settingsEditor?.accountID))")
        model.settingsEditor = nil

        // Importing the same files again adds nothing.
        model.beginMicroSIPImport(ini: ini)
        if case let .preview(again)? = model.microSIPImport?.outcome { check("the same files again: nothing new", again.isEmpty, "\(again.accounts.count) \(again.contacts.count)") }
        else { check("the same files again: nothing new", false) }
        model.cancelMicroSIPImport()

        // Switching an account without a password on does not end in an error state.
        if let home {
            model.settingsEditor = nil
            model.setAccountEnabled(home.id, true)
            await model.waitForAccountSync()
            check("the enable switch opens the editor instead of enabling", model.account(home.id)?.enabled == false && model.settingsEditor?.accountID == home.id
                  && !model.engineAccounts.contains(home.id) && model.banner?.isError == true, "\(String(describing: model.account(home.id)?.enabled))")
            model.settingsEditor = nil
            // Typing the password and saving (what the editor does, with Enabled preset to on).
            if var cfg = model.account(home.id) {
                cfg.enabled = true
                do { try await model.saveAccount(cfg, password: "demo-secret", callerName: model.callerName(for: home.id)) } catch { check("saving", false, "\(error)") }
                await model.waitForAccountSync()
                check("password + save switches the account on", model.account(home.id)?.enabled == true && model.engineAccounts.contains(home.id)
                      && !model.accountNeedsPassword(home.id), "\(String(describing: model.account(home.id)?.enabled))")
                check("the password went to the vault only", model.vault.password(for: home.id) == "demo-secret" )
            }
        }
        if let work {
            check("the other imported account still has no password", model.vault.password(for: work.id) == nil && model.accountNeedsPassword(work.id) && model.account(work.id)?.enabled == false)
            await model.deleteAccount(work.id)
            check("deleting it forgets the flag", !model.accountNeedsPassword(work.id))
        }
        try? FileManager.default.removeItem(at: samples)
    }
}
#endif
