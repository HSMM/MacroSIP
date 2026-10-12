import Foundation
import OSLog
import MacroSIPCore

/// Log file `~/Library/Logs/MacroSIP/MacroSIP.log`.
///
/// Every line is handed to the kernel with one `write(2)` on an `O_APPEND` descriptor, so there is no
/// user-space buffer that a crash could lose. The file rotates at 2 MB and keeps three files:
/// `MacroSIP.log`, `MacroSIP.1.log`, `MacroSIP.2.log` (newest first).
/// Line format: `2026-10-12 14:03:22.123 [pjsip] I text`. Multi-line text continues on lines
/// that start with a tab.
final class FileLog: @unchecked Sendable {
    static let maxBytes = 2 * 1024 * 1024
    static let fileCount = 3

    /// `MACROSIP_LOG_DIR` overrides the folder (tests, demos); demo launches do not write a file.
    static let shared: FileLog? = {
        if LaunchOptions.current.isDemo && ProcessInfo.processInfo.environment["MACROSIP_LOG_DIR"] == nil { return nil }
        return FileLog(directory: defaultDirectory)
    }()

    static var defaultDirectory: URL {
        if let dir = ProcessInfo.processInfo.environment["MACROSIP_LOG_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: dir, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/MacroSIP", isDirectory: true)
    }

    let directory: URL
    var fileURL: URL { directory.appendingPathComponent("MacroSIP.log") }

    private let queue = DispatchQueue(label: "com.hsmm.macrosip.filelog")
    private var fd: Int32 = -1
    private var size = 0
    private let maxBytes: Int
    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    init(directory: URL, maxBytes: Int = FileLog.maxBytes) {
        self.directory = directory
        self.maxBytes = maxBytes
    }

    /// Level: 1 error, 2 warning, 3 info, 4 and above debug (the PJSIP scale).
    func write(category: String, level: Int, _ text: String) {
        let now = Date()
        queue.async { [self] in
            let letter = level <= 1 ? "E" : level == 2 ? "W" : level == 3 ? "I" : "D"
            let body = text.trimmingCharacters(in: .newlines).replacingOccurrences(of: "\n", with: "\n\t")
            let line = "\(formatter.string(from: now)) [\(category)] \(letter) \(body)\n"
            append(Array(line.utf8))
        }
    }

    /// Blocks until everything written so far is on disk (used by tests and at quit).
    func flush() { queue.sync {} }

    private func append(_ bytes: [UInt8]) {
        if fd < 0 { open() }
        guard fd >= 0 else { return }
        if size > 0, size + bytes.count > maxBytes { rotate() }
        guard fd >= 0 else { return }
        let written = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, bytes.count) }
        if written > 0 { size += written }
    }

    private func open() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fd = Darwin.open(fileURL.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        size = (attrs?[.size] as? Int) ?? 0
    }

    private func rotate() {
        Darwin.close(fd)
        fd = -1
        let fm = FileManager.default
        func name(_ i: Int) -> URL { directory.appendingPathComponent(i == 0 ? "MacroSIP.log" : "MacroSIP.\(i).log") }
        try? fm.removeItem(at: name(Self.fileCount - 1))
        for i in stride(from: Self.fileCount - 2, through: 0, by: -1) {
            try? fm.moveItem(at: name(i), to: name(i + 1))
        }
        open()
    }
}

/// A logging category of the app: os_log (unified log) plus the log file.
/// Categories written to the file: engine, pjsip, recording, presence, app.
struct AppLog: Sendable {
    let category: String
    private let logger: Logger

    init(_ category: String) {
        self.category = category
        logger = Logger(subsystem: Product.bundleIdentifier, category: category)
    }

    static let app = AppLog("app")
    static let recording = AppLog("recording")
    static let presence = AppLog("presence")

    func debug(_ text: String) { logger.debug("\(text, privacy: .public)"); FileLog.shared?.write(category: category, level: 4, text) }
    func info(_ text: String) { logger.info("\(text, privacy: .public)"); FileLog.shared?.write(category: category, level: 3, text) }
    func notice(_ text: String) { logger.notice("\(text, privacy: .public)"); FileLog.shared?.write(category: category, level: 3, text) }
    func error(_ text: String) { logger.error("\(text, privacy: .public)"); FileLog.shared?.write(category: category, level: 1, text) }

    /// Engine `.log` events (the engine already sent them to os_log): PJSIP output goes to
    /// category `pjsip`, the engine's own messages (prefixed "engine: ") to `engine`.
    static func record(engineLevel level: Int, _ text: String) {
        if text.hasPrefix("engine: ") {
            FileLog.shared?.write(category: "engine", level: level, String(text.dropFirst(8)))
        } else {
            FileLog.shared?.write(category: "pjsip", level: level, text)
        }
    }
}
