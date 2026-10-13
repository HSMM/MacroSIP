import Foundation

/// File names and folders of finished recordings (SCREENS.md 8.6).
public enum RecordingFileName {
    /// `~/Music/MacroSIP Recordings`
    public static var defaultFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Music", isDirectory: true)
            .appendingPathComponent("MacroSIP Recordings", isDirectory: true)
    }

    /// "2026-10-10 14.52 Alesia Kazlouskaya (in).m4a": date and time to the minute, remote party, direction.
    public static func make(date: Date, remote: String, direction: CallDirection, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd HH.mm"
        let dir = direction == .outgoing ? "out" : "in"
        return "\(f.string(from: date)) \(sanitize(remote)) (\(dir)).m4a"
    }

    private static func nameFormatter(_ timeZone: TimeZone) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd HH.mm"
        return f
    }

    /// Reads a name made by `make` back: the minute the recording started, the remote party's part and the
    /// direction ("in" covers incoming and missed). A " 2", " 3" after the direction (a name that was taken) is ignored.
    public static func parse(_ fileName: String, timeZone: TimeZone = .current) -> (date: Date, remote: String, direction: CallDirection)? {
        parse(fileName, formatter: nameFormatter(timeZone))
    }

    private static func parse(_ fileName: String, formatter: DateFormatter) -> (date: Date, remote: String, direction: CallDirection)? {
        guard fileName.lowercased().hasSuffix(".m4a") else { return nil }
        let stem = (fileName as NSString).deletingPathExtension
        // "2026-10-10 14.52 " is 17 characters.
        guard stem.count > 17, let date = formatter.date(from: String(stem.prefix(16))) else { return nil }
        var rest = String(stem.dropFirst(17))
        if let range = rest.range(of: #" \d+$"#, options: .regularExpression), rest[..<range.lowerBound].hasSuffix(")") {
            rest.removeSubrange(range)
        }
        let direction: CallDirection
        if rest.hasSuffix(" (in)") { direction = .incoming; rest.removeLast(5) }
        else if rest.hasSuffix(" (out)") { direction = .outgoing; rest.removeLast(6) }
        else { return nil }
        return (date, rest, direction)
    }

    /// The recordings in a folder, read once; finds the one that belongs to a call-log entry.
    public struct Index: Sendable {
        struct Item: Sendable { var url: URL; var time: TimeInterval; var remote: String; var outgoing: Bool }
        let items: [Item]

        public init(files: [URL], timeZone: TimeZone = .current) {
            let f = RecordingFileName.nameFormatter(timeZone)
            items = files.compactMap { url in
                RecordingFileName.parse(url.lastPathComponent, formatter: f).map {
                    Item(url: url.standardizedFileURL, time: $0.date.timeIntervalSinceReferenceDate, remote: $0.remote, outgoing: $0.direction == .outgoing)
                }
            }
        }

        public var isEmpty: Bool { items.isEmpty }

        /// Files for several entries at once. A file belongs to an entry only when it has the same direction,
        /// its start minute lies within the call (from the minute the call began to its end) and its name part is
        /// the remote party's name or number; never on time alone. When several entries and files compete, the
        /// closest pairs (file time against call start) are assigned first, over all entries together, and a
        /// file is given to one entry only. Files in `excluding` belong to other entries already.
        public func assign(_ entries: [(entry: CallLogEntry, name: String)], excluding: Set<URL> = []) -> [UUID: URL] {
            struct Pair { var id: UUID; var item: Int; var distance: TimeInterval }
            var pairs: [Pair] = []
            for (entry, name) in entries {
                let start = entry.startedAt.timeIntervalSinceReferenceDate
                let from = (start / 60).rounded(.down) * 60
                let to = start + max(entry.duration, 0) + 1
                let wanted = [RecordingFileName.sanitize(name), RecordingFileName.sanitize(entry.remoteNumber)]
                let outgoing = entry.direction == .outgoing
                for (i, item) in items.enumerated()
                where item.outgoing == outgoing && item.time >= from && item.time <= to
                    && wanted.contains(item.remote) && !excluding.contains(item.url) {
                    pairs.append(Pair(id: entry.id, item: i, distance: abs(item.time - start)))
                }
            }
            pairs.sort { $0.distance < $1.distance }
            var result: [UUID: URL] = [:]
            var taken = Set<Int>()
            for p in pairs where result[p.id] == nil && !taken.contains(p.item) {
                result[p.id] = items[p.item].url
                taken.insert(p.item)
            }
            return result
        }

        /// The file of one entry (see `assign`).
        public func match(_ entry: CallLogEntry, name: String, excluding: Set<URL> = []) -> URL? {
            assign([(entry, name)], excluding: excluding)[entry.id]
        }
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
