import Foundation

/// Turns a CSV or JSON directory feed into entries (URL sources).
///
/// CSV: a header row, then one person per row; comma, semicolon or tab separated (detected from the
/// header), RFC 4180 quoting, UTF-8 (a BOM is skipped). JSON: an array of objects, at the root or at
/// `jsonItemsPath`. Columns and keys are found through `URLFieldMap`, else by their recognised names.
/// Rows without a number are skipped.
public enum DirectoryFeedParser {
    public static func parse(_ data: Data, config: URLConfig, sourceID: UUID) throws -> [DirectoryEntry] {
        switch config.format {
        case .csv: return try parseCSV(data, columns: config.csvColumns, sourceID: sourceID)
        case .json: return try parseJSON(data, paths: config.jsonPaths, itemsPath: config.jsonItemsPath, sourceID: sourceID)
        }
    }

    // MARK: Recognised names

    enum Field: CaseIterable { case name, firstName, lastName, number, mobile, email, organization }

    /// Lowercased, letters and digits only.
    static func key(_ s: String) -> String { String(s.lowercased().filter { $0.isLetter || $0.isNumber }) }

    static let aliases: [Field: [String]] = [
        .name: ["name", "fullname", "displayname", "cn", "contact", "имя", "фио"],
        .firstName: ["firstname", "givenname", "first", "given"],
        .lastName: ["lastname", "surname", "familyname", "last", "sn", "family", "фамилия"],
        .number: ["number", "phone", "telephone", "telephonenumber", "phonenumber", "tel", "work", "workphone",
                  "extension", "ext", "internal", "номер", "телефон"],
        .mobile: ["mobile", "cell", "cellphone", "mobilephone", "mobilenumber", "мобильный"],
        .email: ["email", "mail", "emailaddress"],
        .organization: ["organization", "organisation", "company", "org", "department", "организация"],
    ]

    static func configured(_ map: URLFieldMap, _ f: Field) -> String? {
        let v: String?
        switch f {
        case .name: v = map.name
        case .firstName: v = map.firstName
        case .lastName: v = map.lastName
        case .number: v = map.number
        case .mobile: v = map.mobile
        case .email: v = map.email
        case .organization: v = map.organization
        }
        guard let s = v?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        return s
    }

    struct Fields {
        var values: [Field: [String]] = [:]
        func first(_ f: Field) -> String? {
            values[f]?.lazy.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
        }
    }

    static func entry(_ f: Fields, id: String, sourceID: UUID) -> DirectoryEntry? {
        var numbers: [PhoneNumber] = []
        func add(_ raw: [String]?, _ label: PhoneLabel) {
            for v in raw ?? [] {
                // A cell may hold several numbers: "101, +7 495 123-45-67".
                for part in v.split(whereSeparator: { ",;\n".contains($0) }) {
                    let s = part.trimmingCharacters(in: .whitespaces)
                    if !s.isEmpty, !numbers.contains(where: { $0.value == s }) {
                        numbers.append(PhoneNumber(label: label, value: s, isDefault: numbers.isEmpty))
                    }
                }
            }
        }
        add(f.values[.number], .work)
        add(f.values[.mobile], .mobile)
        guard !numbers.isEmpty else { return nil }
        let org = f.first(.organization)
        var name = f.first(.name) ?? ""
        if name.isEmpty { name = [f.first(.firstName), f.first(.lastName)].compactMap { $0 }.joined(separator: " ") }
        if name.isEmpty { name = org ?? numbers[0].value }
        return DirectoryEntry(id: id, sourceID: sourceID, sourceKind: .url, displayName: name, numbers: numbers,
                              organization: org, email: f.first(.email))
    }

    // MARK: CSV

    public static func parseCSV(_ data: Data, columns: URLFieldMap = URLFieldMap(), sourceID: UUID) throws -> [DirectoryEntry] {
        guard var text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1251) else {
            throw DirectoryError.badFeed(.notText)
        }
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        let firstLine = text.prefix { $0 != "\n" && $0 != "\r\n" && $0 != "\r" }
        let separator: Character = [",", ";", "\t"].max { a, b in
            firstLine.filter { $0 == a }.count < firstLine.filter { $0 == b }.count
        } ?? ","
        let rows = csvRows(text, separator: separator)
        guard let header = rows.first else { return [] }
        let keys = header.map(key)
        var index: [Field: [Int]] = [:]
        for f in Field.allCases {
            if let name = configured(columns, f) {
                let k = key(name)
                if let i = keys.firstIndex(of: k) { index[f] = [i] }
            } else {
                let names = aliases[f] ?? []
                let found = keys.indices.filter { names.contains(keys[$0]) }
                if !found.isEmpty { index[f] = found }
            }
        }
        guard index[.number] != nil || index[.mobile] != nil else {
            throw DirectoryError.badFeed(.noNumberColumn)
        }
        var out: [DirectoryEntry] = []
        for (n, row) in rows.dropFirst().enumerated() where !(row.count == 1 && row[0].isEmpty) {
            var f = Fields()
            for (field, cols) in index { f.values[field] = cols.compactMap { $0 < row.count ? row[$0] : nil } }
            if let e = entry(f, id: "row-\(n + 1)", sourceID: sourceID) { out.append(e) }
        }
        return out
    }

    /// RFC 4180 rows: quoted fields may contain the separator, line breaks and doubled quotes.
    static func csvRows(_ text: String, separator: Character) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var chars = text.makeIterator()
        var pending: Character? = nil
        func next() -> Character? {
            if let p = pending { pending = nil; return p }
            return chars.next()
        }
        while let c = next() {
            if quoted {
                if c == "\"" {
                    if let n = next() {
                        if n == "\"" { field.append("\"") } else { quoted = false; pending = n }
                    } else { quoted = false }
                } else { field.append(c) }
            } else if c == "\"" && field.isEmpty {
                quoted = true
            } else if c == separator {
                row.append(field); field = ""
            } else if c == "\n" || c == "\r\n" || c == "\r" {
                row.append(field); field = ""
                rows.append(row); row = []
            } else {
                field.append(c)
            }
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }

    // MARK: JSON

    public static func parseJSON(_ data: Data, paths: URLFieldMap = URLFieldMap(), itemsPath: String? = nil,
                                 sourceID: UUID) throws -> [DirectoryEntry] {
        let root: Any
        do { root = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) }
        catch { throw DirectoryError.badFeed(.invalidJSON) }
        var items: Any? = root
        if let p = itemsPath?.trimmingCharacters(in: .whitespaces), !p.isEmpty { items = value(at: p, in: root) }
        else if let obj = root as? [String: Any] {
            // An object at the root: the first array of objects in it ("contacts", "data", "items"…).
            items = obj.keys.sorted().lazy.compactMap { obj[$0] as? [[String: Any]] }.first ?? root
        }
        guard let list = items as? [Any] else { throw DirectoryError.badFeed(.noContactArray) }
        var out: [DirectoryEntry] = []
        for (n, item) in list.enumerated() {
            guard let obj = item as? [String: Any] else { continue }
            var f = Fields()
            for field in Field.allCases {
                if let p = configured(paths, field) {
                    f.values[field] = strings(value(at: p, in: obj))
                } else {
                    let names = aliases[field] ?? []
                    let vals = obj.keys.sorted().filter { names.contains(key($0)) }.flatMap { strings(obj[$0]) }
                    if !vals.isEmpty { f.values[field] = vals }
                }
            }
            let id = (obj["id"].flatMap { strings($0).first }).map { "id-\($0)" } ?? "row-\(n + 1)"
            if let e = entry(f, id: id, sourceID: sourceID) { out.append(e) }
        }
        return out
    }

    /// `a.b.0.c`: object keys and array indices.
    static func value(at path: String, in root: Any) -> Any? {
        var cur: Any? = root
        for part in path.split(separator: ".") {
            if let obj = cur as? [String: Any] { cur = obj[String(part)] }
            else if let arr = cur as? [Any], let i = Int(part), arr.indices.contains(i) { cur = arr[i] }
            else { return nil }
        }
        return cur
    }

    static func strings(_ v: Any?) -> [String] {
        switch v {
        case let s as String: return [s]
        case let n as NSNumber: return [n.stringValue]
        case let a as [Any]: return a.flatMap { strings($0) }
        default: return []
        }
    }
}
