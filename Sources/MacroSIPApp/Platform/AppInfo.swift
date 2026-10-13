import SwiftUI
import AppKit
import MacroSIPCore

/// Version and build of the running app. The version is `Product.version`; the build number comes
/// from `CFBundleVersion` (set by scripts/make-app.sh), absent when running outside an .app.
enum AppInfo {
    static let version = Product.version
    static var build: String? { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String }
    static let copyright = "© 2026 HSMM"
    static let repositoryURL = URL(string: "https://github.com/HSMM/MacroSIP")!

    /// "26.0.0 (42)" or "26.0.0".
    static var versionLine: String { build.map { "\(version) (\($0))" } ?? version }
}

/// The standard macOS About panel (SCREENS.md has no custom About window).
@MainActor
enum AboutPanel {
    static func show() {
        let credits = NSMutableAttributedString(
            string: L.aboutCredits + "\n",
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.labelColor])
        credits.append(NSAttributedString(
            string: AppInfo.repositoryURL.absoluteString,
            attributes: [.font: NSFont.systemFont(ofSize: 11), .link: AppInfo.repositoryURL]))
        let center = NSMutableParagraphStyle()
        center.alignment = .center
        credits.addAttribute(.paragraphStyle, value: center, range: NSRange(location: 0, length: credits.length))

        var options: [NSApplication.AboutPanelOptionKey: Any] = [
            .applicationName: Product.name,
            .applicationVersion: AppInfo.version,
            .version: AppInfo.build ?? "",
            .credits: credits,
            NSApplication.AboutPanelOptionKey(rawValue: "Copyright"): AppInfo.copyright,
        ]
        if let icon = NSApp.applicationIconImage { options[.applicationIcon] = icon }
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: options)
    }
}

extension AppModel {
    /// Plain-text report for bug reports: versions, accounts without passwords, settings.
    func diagnosticsText() -> String {
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        var lines: [String] = []
        lines.append("\(Product.name) \(AppInfo.versionLine)")
        lines.append("macOS \(os), \(Self.machineArchitecture)")
        lines.append("PJSIP 2.17, engine: \(isMockEngine ? "mock" : "pjsua"), log level \(launch.logLevel)")
        lines.append("Generated: \(ISO8601DateFormatter().string(from: Date()))")
        lines.append("Log file: \((FileLog.shared?.fileURL ?? FileLog.defaultDirectory.appendingPathComponent("MacroSIP.log")).path)")
        lines.append("")
        lines.append("Accounts (\(accounts.count)); passwords are in the Keychain and not listed")
        for a in accounts {
            let state = registration[a.id].map { String(describing: $0) } ?? "unknown"
            var parts = ["\(a.username)@\(a.domain)", "transport=\(a.transport.rawValue)", "srtp=\(a.srtp.rawValue)",
                         "enabled=\(a.enabled)", "register=\(a.registerWithServer)", "interval=\(a.registrationInterval)s",
                         "presence=\(a.publishPresence)", "default=\(a.isDefaultOutgoing)", "tlsVerify=\(a.verifyTLSCertificate)"]
            if let r = a.registrar { parts.append("registrar=\(r)") }
            if let p = a.outboundProxy { parts.append("proxy=\(p)") }
            if let id = a.authID { parts.append("authID=\(id)") }
            parts.append("state=\(state)")
            lines.append("- \(a.displayName): " + parts.joined(separator: " "))
        }
        lines.append("")
        lines.append("Settings")
        lines.append(Self.settingsJSON(settings))
        return lines.joined(separator: "\n") + "\n"
    }

    private static var machineArchitecture: String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
    }

    private static func settingsJSON(_ settings: AppSettings) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(settings),
              var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return "(unavailable)" }
        if var recording = object["recording"] as? [String: Any] {
            recording.removeValue(forKey: "folderBookmark")      // opaque binary data
            object["recording"] = recording
        }
        guard let out = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) else { return "(unavailable)" }
        return String(decoding: out, as: UTF8.self)
    }

    func copyDiagnostics() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(diagnosticsText(), forType: .string)
        AppLog.app.info("diagnostics copied to the clipboard")
        showBanner(L.diagnosticsCopied)
    }

    func openLogFolder() {
        let dir = FileLog.shared?.directory ?? FileLog.defaultDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("MacroSIP.log")
        if FileManager.default.fileExists(atPath: file.path) { NSWorkspace.shared.activateFileViewerSelecting([file]) }
        else { NSWorkspace.shared.open(dir) }
    }
}
