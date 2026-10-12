import Foundation

/// File names and folders of finished recordings (SCREENS.md 8.6).
public enum RecordingFileName {
    /// `~/Music/MacroSIP Recordings`
    public static var defaultFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Music", isDirectory: true)
            .appendingPathComponent("MacroSIP Recordings", isDirectory: true)
    }

    /// "2026-10-10 14.52 Anna Petrova (in).m4a": date and time to the minute, remote party, direction.
    public static func make(date: Date, remote: String, direction: CallDirection, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd HH.mm"
        let dir = direction == .outgoing ? "out" : "in"
        return "\(f.string(from: date)) \(sanitize(remote)) (\(dir)).m4a"
    }

    /// Path separators, colons and control characters are not allowed in the name part.
    static func sanitize(_ name: String) -> String {
        var cleaned = String(name.map { ch -> Character in
            if ch == "/" || ch == ":" || ch == "\\" || ch.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) { return "-" }
            return ch
        })
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        if cleaned.count > 80 { cleaned = String(cleaned.prefix(80)).trimmingCharacters(in: .whitespaces) }
        return cleaned.isEmpty ? "Unknown" : cleaned
    }

    /// `name` inside `folder`, or "name 2.m4a", "name 3.m4a", ... when it already exists.
    public static func uniqueURL(in folder: URL, name: String) -> URL {
        let fm = FileManager.default
        var url = folder.appendingPathComponent(name)
        guard fm.fileExists(atPath: url.path) else { return url }
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var n = 2
        repeat {
            url = folder.appendingPathComponent("\(base) \(n)").appendingPathExtension(ext)
            n += 1
        } while fm.fileExists(atPath: url.path)
        return url
    }
}
