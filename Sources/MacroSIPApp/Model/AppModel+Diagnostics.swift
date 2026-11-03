import SwiftUI
import AppKit
import UniformTypeIdentifiers
import MacroSIPCore

/// Settings › General › Troubleshooting: Debug mode and the diagnostics archive.
extension AppModel {
    /// The level in effect: the launch level (an explicit `--log-level` / `MACROSIP_LOG_LEVEL` wins) or 4 in Debug mode.
    var effectiveLogLevel: Int {
        LogLevelPolicy.effectiveLevel(launchLevel: launch.logLevel, explicit: launch.logLevelIsExplicit, debugMode: settings.general.debugMode)
    }

    /// The level was fixed at launch, so the Debug mode switch cannot change it.
    var logLevelFixedAtLaunch: Bool { launch.logLevelIsExplicit }

    /// The file log in use (a demo check may substitute its own).
    var fileLog: FileLog? { fileLogOverride ?? FileLog.shared }

    /// The log file and PJSIP follow `effectiveLogLevel` at once, no restart.
    func applyLogLevel() {
        let level = effectiveLogLevel
        fileLog?.setLevel(level)
        Task { await engine.setLogLevel(level) }
        AppLog.app.info("log level \(level)\(settings.general.debugMode ? " (debug mode)" : "")")
    }

    func setDebugMode(_ on: Bool) {
        updateSettings { $0.general.debugMode = on }
    }

    // MARK: Archive

    /// Settings › General › Troubleshooting › Create Archive…
    func createDiagnosticsArchive() {
        guard !archiveInProgress else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = DiagnosticsArchive.defaultFileName()
        panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        panel.allowedContentTypes = [.zip]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await makeDiagnosticsArchive(at: url, reveal: true) }
    }

    /// The one code path of the button and of the self-check (which has no panel): flushes the log, builds the ZIP off the
    /// main actor, reveals it in Finder and shows the banner. A failure shows a localized banner and returns nil.
    @discardableResult
    func makeDiagnosticsArchive(at url: URL, reveal: Bool, crashReports: URL? = AppModel.systemCrashReportsFolder) async -> DiagnosticsArchive.Result? {
        archiveInProgress = true
        defer { archiveInProgress = false }
        let log = fileLog
        let directory = log?.directory ?? FileLog.defaultDirectory
        let text = diagnosticsText()
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                log?.flush()
                return try await DiagnosticsArchive.create(destination: url, logDirectory: directory, crashReportsDirectory: crashReports, diagnosticsText: text)
            }.value
            AppLog.app.info("diagnostics archive written: \(result.logFiles.count) log file(s), \(result.crashReports.count) crash report(s), \(result.bytes) bytes")
            if reveal { NSWorkspace.shared.activateFileViewerSelecting([result.url]) }
            showBanner(L.diagnosticsArchiveCreated(result.url.lastPathComponent), isError: false)
            return result
        } catch {
            let reason: String
            switch error as? DiagnosticsArchive.Failure {
            case let .zipFailed(text)?, let .cannotWrite(text)?: reason = text
            case nil: reason = error.localizedDescription
            }
            AppLog.app.error("diagnostics archive failed: \(reason)")
            showBanner(L.diagnosticsArchiveFailed(reason))
            return nil
        }
    }

    static var systemCrashReportsFolder: URL? {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)
    }
}
