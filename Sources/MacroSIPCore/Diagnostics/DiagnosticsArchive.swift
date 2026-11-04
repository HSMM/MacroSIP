import Foundation

/// The diagnostics ZIP: the rotated log files (secrets removed from the copies), `diagnostics.txt`
/// and the newest crash reports of this app. Built in a temporary folder and zipped with `ditto`;
/// the originals are never changed.
public enum DiagnosticsArchive {
    public struct Result: Sendable, Equatable {
        public let url: URL
        public let logFiles: [String]
        public let crashReports: [String]
        public let bytes: Int
    }

    public enum Failure: Error, Equatable, Sendable {
        case zipFailed(String)
        case cannotWrite(String)
    }

    public static let maxCrashReports = 5
    public static let crashReportDays = 30

    /// `MacroSIP-diagnostics-20261103-1405.zip`
    public static func defaultFileName(now: Date = Date(), calendar: Calendar = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.dateFormat = "yyyyMMdd-HHmm"
        return "MacroSIP-diagnostics-\(f.string(from: now)).zip"
    }

    /// `MacroSIP.log`, `MacroSIP.1.log`, ... in the folder, newest first; empty when there are none.
    public static func logFiles(in directory: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        func index(_ name: String) -> Int? {
            if name == "MacroSIP.log" { return 0 }
            guard name.hasPrefix("MacroSIP."), name.hasSuffix(".log") else { return nil }
            return Int(name.dropFirst(9).dropLast(4))
        }
        return names.compactMap { n in index(n).map { ($0, n) } }
            .sorted { $0.0 < $1.0 }
            .map { directory.appendingPathComponent($0.1) }
    }

    /// `MacroSIP-*.ips` changed within `days` days, newest first, at most `limit`.
    public static func recentCrashReports(in directory: URL, now: Date = Date(),
                                          days: Int = crashReportDays, limit: Int = maxCrashReports) -> [URL] {
        let cutoff = now.addingTimeInterval(-Double(days) * 86400)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let dated: [(URL, Date)] = names.compactMap { n in
            guard n.hasPrefix("MacroSIP-"), n.hasSuffix(".ips") else { return nil }
            let url = directory.appendingPathComponent(n)
            guard let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                  date >= cutoff else { return nil }
            return (url, date)
        }
        return dated.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
    }

    /// Writes the archive to `destination` (replacing a file there). Call it off the main actor.
    /// The caller flushes the log first. Missing log files or crash reports are not an error.
    public static func create(destination: URL, logDirectory: URL, crashReportsDirectory: URL?,
                              diagnosticsText: String, now: Date = Date()) async throws -> Result {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("MacroSIP-archive-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: work) }
        let root = work.appendingPathComponent(destination.deletingPathExtension().lastPathComponent, isDirectory: true)
        let zip = work.appendingPathComponent("archive.zip")
        var logNames: [String] = [], crashNames: [String] = []
        do {
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            try LogRedaction.redact(diagnosticsText).write(to: root.appendingPathComponent("diagnostics.txt"), atomically: true, encoding: .utf8)
            let logs = logFiles(in: logDirectory)
            if !logs.isEmpty { try fm.createDirectory(at: root.appendingPathComponent("logs"), withIntermediateDirectories: true) }
            for file in logs {
                guard let data = try? Data(contentsOf: file) else { continue }
                let text = LogRedaction.redact(String(decoding: data, as: UTF8.self))
                try text.write(to: root.appendingPathComponent("logs/" + file.lastPathComponent), atomically: true, encoding: .utf8)
                logNames.append(file.lastPathComponent)
            }
            let crashes = crashReportsDirectory.map { recentCrashReports(in: $0, now: now) } ?? []
            if !crashes.isEmpty { try fm.createDirectory(at: root.appendingPathComponent("crash-reports"), withIntermediateDirectories: true) }
            for file in crashes {
                do {
                    try fm.copyItem(at: file, to: root.appendingPathComponent("crash-reports/" + file.lastPathComponent))
                    crashNames.append(file.lastPathComponent)
                } catch { continue }
            }
        } catch {
            throw Failure.cannotWrite(error.localizedDescription)
        }
        try await ditto(folder: root, zip: zip)
        do {
            if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
            try fm.moveItem(at: zip, to: destination)
        } catch {
            throw Failure.cannotWrite(error.localizedDescription)
        }
        let size = (try? fm.attributesOfItem(atPath: destination.path)[.size] as? Int) ?? 0
        return Result(url: destination, logFiles: logNames, crashReports: crashNames, bytes: size)
    }

    /// `--norsrc` keeps resource forks and extended attributes out: without it every file and folder gets a `._` AppleDouble
    /// twin in the ZIP, which only clutters what the user sends.
    private static func ditto(folder: URL, zip: URL) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--norsrc", "--keepParent", folder.path, zip.path]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        let status: Int32 = try await withCheckedThrowingContinuation { cont in
            process.terminationHandler = { p in cont.resume(returning: p.terminationStatus) }
            do { try process.run() } catch { cont.resume(throwing: Failure.zipFailed(error.localizedDescription)) }
        }
        guard status == 0 else {
            let text = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw Failure.zipFailed(text.isEmpty ? "ditto exit \(status)" : text)
        }
    }
}
