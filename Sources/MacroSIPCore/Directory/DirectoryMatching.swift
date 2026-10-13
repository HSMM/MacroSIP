import Foundation

/// How directory numbers are compared with what the user typed or with a caller's number.
public enum DirectoryNumber {
    /// Digits only: "+7 (495) 123-45-67" → "74951234567"; a SIP URI gives the digits of its user part.
    public static func digits(_ raw: String) -> String {
        String(Contact.normalize(raw).filter(\.isASCII).filter(\.isNumber))
    }

    /// Whether two numbers are the same line. Equal digits match; numbers of 7 digits or more also match when
    /// their last digits agree (up to 10), so "+7 495 123-45-67", "8 495 1234567" and "1234567" are one line.
    /// Short extensions must be equal.
    public static func matches(_ a: String, _ b: String) -> Bool {
        let x = digits(a), y = digits(b)
        guard !x.isEmpty, !y.isEmpty else { return false }
        if x == y { return true }
        guard x.count >= minimumSuffix, y.count >= minimumSuffix else { return false }
        let n = min(x.count, y.count, 10)
        return x.suffix(n) == y.suffix(n)
    }

    /// The shortest number compared by its tail.
    public static let minimumSuffix = 7

    /// The digits a server-side substring search uses for `number`: its last 10 digits at most.
    static func searchKey(_ number: String) -> String {
        String(digits(number).suffix(10))
    }
}

/// An in-memory list of entries searched the way the number field expects. Used by the URL and macOS
/// Contacts sources; LDAP searches on the server.
struct DirectoryIndex: Sendable {
    private struct Row: Sendable {
        let entry: DirectoryEntry
        let text: String          // lowercased name and organization
        let numbers: [String]     // lowercased raw numbers
        let digits: [String]
    }

    private let rows: [Row]

    init(_ entries: [DirectoryEntry]) {
        rows = entries.map { e in
            Row(entry: e,
                text: (e.displayName + "\u{1}" + (e.organization ?? "")).lowercased(),
                numbers: e.numbers.map { $0.value.lowercased() },
                digits: e.numbers.map { DirectoryNumber.digits($0.value) })
        }
    }

    var entries: [DirectoryEntry] { rows.map(\.entry) }
    var count: Int { rows.count }

    /// Entries whose name or organization contains the text, or (for text without letters) whose number
    /// contains its digits. Names that start with the text come first.
    func search(_ query: String, limit: Int) -> [DirectoryEntry] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty, limit > 0 else { return [] }
        let digitQuery: String? = q.contains(where: \.isLetter) ? nil : DirectoryNumber.digits(q)
        var prefix: [DirectoryEntry] = []
        var other: [DirectoryEntry] = []
        for r in rows {
            let nameHit = r.text.contains(q)
            let numberHit = r.numbers.contains { $0.contains(q) }
                || (digitQuery.map { d in !d.isEmpty && r.digits.contains { $0.contains(d) } } ?? false)
            guard nameHit || numberHit else { continue }
            if r.text.hasPrefix(q) || r.text.contains(" " + q) || r.text.contains("\u{1}" + q) { prefix.append(r.entry) } else { other.append(r.entry) }
            if prefix.count >= limit { break }
        }
        return Array((prefix + other).prefix(limit))
    }

    /// The first entry with a number that `DirectoryNumber.matches` `number`; an exact digit match wins.
    func lookup(_ number: String) -> DirectoryEntry? {
        let d = DirectoryNumber.digits(number)
        guard !d.isEmpty else { return nil }
        if let exact = rows.first(where: { $0.digits.contains(d) }) { return exact.entry }
        return rows.first { r in r.entry.numbers.contains { DirectoryNumber.matches($0.value, number) } }?.entry
    }
}
