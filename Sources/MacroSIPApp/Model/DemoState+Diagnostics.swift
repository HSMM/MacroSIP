import Foundation
import MacroSIPCore
#if DEBUG
import AppKit

/// Demo states of Settings › General › Troubleshooting (26.1):
///   settings-diagnostics   General with the Advanced group open: Log file, Debug mode, Diagnostics, Diagnostics archive
///   diagnostics-selftest   writes sample log text with fake secrets to a temporary log folder, builds the archive through
///                          the code path of the Create Archive… button (no save panel), unzips it and checks the content and
///                          the redaction; checks that Debug mode changes the log level of the file and of the engine and persists
extension DemoState {
    static func isDiagnosticsState(_ state: String) -> Bool { ["settings-diagnostics", "diagnostics-selftest"].contains(state) }

    @MainActor
    static func runDiagnostics(_ model: AppModel, state: String) async {
        try? await Task.sleep(for: .seconds(1.2))
        switch state {
        case "settings-diagnostics":
            model.generalAdvancedOpen = true
            model.openSettings(tab: .general)
            try? await Task.sleep(for: .seconds(1.0))
            for window in NSApp.windows where window.isVisible { scrollToBottom(window.contentView) }
        case "diagnostics-selftest":
            var results: [(String, Bool, String)] = []
            await diagnosticsChecks(model) { results.append(($0, $1, $2)) }
            let failures = results.filter { !$0.1 }.count
            let text = results.map { "\($0.1 ? "PASS" : "FAIL") \($0.0) \($0.2)" }.joined(separator: "\n") + "\nfailures=\(failures)\n"
            if let prefix = model.launch.snapshotPrefix { try? text.write(toFile: "\(prefix)-selftest.txt", atomically: true, encoding: .utf8) }
            print(text)
            quitLater()
        default: break
        }
    }

    /// The group is at the bottom of a tall pane: scroll every scroll view in the window to its end for the screenshot.
    @MainActor
    private static func scrollToBottom(_ view: NSView?) {
        guard let view else { return }
        if let scroll = view as? NSScrollView, let doc = scroll.documentView {
            let y = doc.isFlipped ? max(0, doc.bounds.height - scroll.contentView.bounds.height) : 0
            doc.scroll(NSPoint(x: 0, y: y))
        }
        for sub in view.subviews { scrollToBottom(sub) }
    }

    @MainActor
    static func diagnosticsChecks(_ model: AppModel, report: (String, Bool, String) -> Void) async {
        func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") { report("diagnostics: " + name, ok, ok ? "" : detail()) }
        func settle() async { try? await Task.sleep(for: .milliseconds(300)) }
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("MacroSIP-diag-selftest-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let logs = base.appendingPathComponent("logs"), crashes = base.appendingPathComponent("crashes")
        try? fm.createDirectory(at: crashes, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }

        let log = FileLog(directory: logs, maxLevel: 3)
        model.fileLogOverride = log
        defer { model.fileLogOverride = nil }
        let mock = model.engine as? MockEngine

        // The switch: off by default, then on and off again, with the file, the engine and the settings following.
        check("off by default", !model.settings.general.debugMode && log.maxLevel == 3)
        log.write(category: "app", level: 4, "debug-line-before")
        log.write(category: "app", level: 3, "info-line-before")
        model.setDebugMode(true)
        await settle()
        check("switch on: file level 4, engine level 4", log.maxLevel == 4 && model.effectiveLogLevel == 4, "\(log.maxLevel)")
        let engineOn = await mock?.logLevel
        check("switch on reaches the engine", engineOn == 4)
        check("switch on is stored", model.settingsStore.load().general.debugMode)
        let secretSIP = """
        TX 560 bytes Request msg REGISTER/cseq=2 (tdta0x1)
        REGISTER sip:pbx.example.com SIP/2.0
        Authorization: Digest username="1001", realm="pbx", nonce="NONCE-SECRET-1", uri="sip:pbx.example.com",
         response="RESPONSE-SECRET-2", cnonce="CNONCE-SECRET-3", opaque="OPAQUE-SECRET-4"
        Proxy-Authorization:Digest username="1001",nonce="NONCE-SECRET-5",response="RESPONSE-SECRET-6"
        Contact: <sip:1001@10.0.0.5:5060>
        """
        log.write(category: "pjsip", level: 4, secretSIP)
        log.write(category: "app", level: 3, "debug-line-after password=PASSWORD-SECRET-7 call to +375291112233")
        log.flush()
        // A rotated file next to the live one.
        try? "2026-11-03 09:00:00.000 [pjsip] D WWW-Authenticate: Digest realm=\"pbx\", nonce=\"NONCE-SECRET-8\", opaque=\"OPAQUE-SECRET-9\"\n"
            .write(to: logs.appendingPathComponent("MacroSIP.1.log"), atomically: true, encoding: .utf8)
        let original = (try? String(contentsOf: log.fileURL, encoding: .utf8)) ?? ""
        check("debug line written only while the switch is on", original.contains("debug-line-after") && !original.contains("debug-line-before") && original.contains("info-line-before"))

        // Crash reports: two of this app, one of another app.
        for n in ["MacroSIP-2026-11-01-000000.ips", "MacroSIP-2026-11-02-000000.ips", "Other-2026-11-02-000000.ips"] {
            try? "{\"crash\":true}".write(to: crashes.appendingPathComponent(n), atomically: true, encoding: .utf8)
        }

        // The archive, through the code path of the button.
        let zip = base.appendingPathComponent(DiagnosticsArchive.defaultFileName())
        let result = await model.makeDiagnosticsArchive(at: zip, reveal: false, crashReports: crashes)
        check("archive is written", result != nil && fm.fileExists(atPath: zip.path), "\(String(describing: result))")
        check("a banner confirms it", model.banner?.isError == false && model.banner?.text.contains(zip.lastPathComponent) == true, "\(String(describing: model.banner?.text))")
        check("no temporary folder is left", !(((try? fm.contentsOfDirectory(atPath: fm.temporaryDirectory.path)) ?? []).contains { $0.hasPrefix("MacroSIP-archive-") }))
        let out = base.appendingPathComponent("unzipped")
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", zip.path, out.path]
        try? unzip.run(); unzip.waitUntilExit()
        let root = out.appendingPathComponent(zip.deletingPathExtension().lastPathComponent)
        func read(_ path: String) -> String? { try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8) }
        let archivedLog = read("logs/MacroSIP.log") ?? "", archivedOld = read("logs/MacroSIP.1.log") ?? "", diagnostics = read("diagnostics.txt") ?? ""
        check("contains the rotated log files and diagnostics.txt", !archivedLog.isEmpty && !archivedOld.isEmpty && diagnostics.contains("Accounts ("))
        let crashList = (try? fm.contentsOfDirectory(atPath: root.appendingPathComponent("crash-reports").path))?.sorted() ?? []
        check("contains this app's crash reports only", crashList == ["MacroSIP-2026-11-01-000000.ips", "MacroSIP-2026-11-02-000000.ips"], "\(crashList)")
        let secrets = (1...9).flatMap { ["NONCE-SECRET-\($0)", "RESPONSE-SECRET-\($0)", "CNONCE-SECRET-\($0)", "OPAQUE-SECRET-\($0)", "PASSWORD-SECRET-\($0)"] }
        let leaked = secrets.filter { s in archivedLog.contains(s) || archivedOld.contains(s) || diagnostics.contains(s) }
        check("no secret reaches the archive", leaked.isEmpty, "\(leaked)")
        check("numbers, users and servers stay", archivedLog.contains("+375291112233") && archivedLog.contains(#"username="1001""#) && archivedLog.contains("pbx.example.com"))
        let after = (try? String(contentsOf: log.fileURL, encoding: .utf8)) ?? ""
        check("the original log is not changed", after.contains("NONCE-SECRET-1") && after.contains("PASSWORD-SECRET-7"))

        // An unwritable destination: a banner, no crash.
        let bad = await model.makeDiagnosticsArchive(at: base.appendingPathComponent("no/such/folder/a.zip"), reveal: false, crashReports: nil)
        check("a failure shows an error banner", bad == nil && model.banner?.isError == true && model.banner?.text.isEmpty == false)

        model.setDebugMode(false)
        await settle()
        let engineOff = await mock?.logLevel
        check("switch off: levels back to 3", log.maxLevel == 3 && model.effectiveLogLevel == 3 && engineOff == 3)
        check("switch off is stored", !model.settingsStore.load().general.debugMode)
    }
}
#endif
