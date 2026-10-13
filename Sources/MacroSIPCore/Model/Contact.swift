import Foundation

public enum PhoneLabel: String, Codable, CaseIterable, Sendable {
    case work, mobile, home, other, sip

    /// A label a later version adds (or a damaged file) reads as `.other`.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = PhoneLabel(rawValue: raw) ?? .other
    }
}

public struct PhoneNumber: Codable, Equatable, Hashable, Sendable {
    public var label: PhoneLabel
    /// Dial string as typed, e.g. "+7 495 123-45-67" or "sip:bob@host".
    public var value: String
    public var isDefault: Bool

    public init(label: PhoneLabel = .work, value: String, isDefault: Bool = false) {
        self.label = label
        self.value = value
        self.isDefault = isDefault
    }

    private enum CodingKeys: String, CodingKey { case label, value, isDefault }

    /// A missing label reads as `.other`, a missing `isDefault` as false.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        label = try c.decodeIfPresent(PhoneLabel.self, forKey: .label) ?? .other
        value = try c.decode(String.self, forKey: .value)
        isDefault = try c.decodeIfPresent(Bool.self, forKey: .isDefault) ?? false
    }
}

/// How the Contacts tab orders contacts and picks section letters (Settings › General › Contacts).
public enum ContactSortOrder: String, Codable, CaseIterable, Sendable {
    case firstName, lastName
}

public struct Contact: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var firstName: String
    public var lastName: String
    public var organization: String
    public var numbers: [PhoneNumber]
    public var email: String
    public var notes: String
    public var isFavorite: Bool
    /// JPEG, at most 256 px on a side (`ContactPhoto`). Not part of contacts.json: `ContactStore` keeps it in
    /// `photos/<id>.jpg` and fills this in when it loads (a 26.2 pre-release file with inline photos is migrated).
    public var photo: Data?
    public var preferredAccountID: AccountID?
    /// Whether to watch the presence of the default number.
    public var subscribePresence: Bool
    public var createdAt: Date
    /// The directory source that created this card (Settings › Directory, "Import into Contacts"). Later imports
    /// from that source update the card; cards without it belong to the user and only get what they lack.
    public var importedFrom: UUID?

    public init(
        id: UUID = UUID(),
        firstName: String = "",
        lastName: String = "",
        organization: String = "",
        numbers: [PhoneNumber] = [],
        email: String = "",
        notes: String = "",
        isFavorite: Bool = false,
        photo: Data? = nil,
        preferredAccountID: AccountID? = nil,
        subscribePresence: Bool = false,
        createdAt: Date = Date(),
        importedFrom: UUID? = nil
    ) {
        self.id = id
        self.firstName = firstName
        self.lastName = lastName
        self.organization = organization
        self.numbers = numbers
        self.email = email
        self.notes = notes
        self.isFavorite = isFavorite
        self.photo = photo
        self.preferredAccountID = preferredAccountID
        self.subscribePresence = subscribePresence
        self.createdAt = createdAt
        self.importedFrom = importedFrom
    }

    /// One number labelled `.other` (the label the 26.1 migration uses), default.
    public init(
        id: UUID = UUID(),
        name: String,
        number: String,
        preferredAccountID: AccountID? = nil,
        subscribePresence: Bool = false,
        createdAt: Date = Date()
    ) {
        let (first, last) = Contact.splitName(name)
        self.init(
            id: id, firstName: first, lastName: last,
            numbers: number.isEmpty ? [] : [PhoneNumber(label: .other, value: number, isDefault: true)],
            preferredAccountID: preferredAccountID, subscribePresence: subscribePresence, createdAt: createdAt)
    }

    // MARK: Coding (26.1 files have `name` and `number`)

    private enum CodingKeys: String, CodingKey {
        case id, firstName, lastName, organization, numbers, email, notes, isFavorite, photo
        case preferredAccountID, subscribePresence, createdAt, importedFrom
        case name, number   // `name` and `number` are written for 26.1 and read only from 26.1 files
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        if let list = try c.decodeIfPresent([PhoneNumber].self, forKey: .numbers) {
            numbers = list
            firstName = try c.decodeIfPresent(String.self, forKey: .firstName) ?? ""
            lastName = try c.decodeIfPresent(String.self, forKey: .lastName) ?? ""
        } else {
            let old = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
            (firstName, lastName) = Contact.splitName(old)
            let number = try c.decodeIfPresent(String.self, forKey: .number) ?? ""
            numbers = number.isEmpty ? [] : [PhoneNumber(label: .other, value: number, isDefault: true)]
        }
        if !numbers.isEmpty, !numbers.contains(where: \.isDefault) { numbers[0].isDefault = true }
        organization = try c.decodeIfPresent(String.self, forKey: .organization) ?? ""
        email = try c.decodeIfPresent(String.self, forKey: .email) ?? ""
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        isFavorite = try c.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        photo = try c.decodeIfPresent(Data.self, forKey: .photo)
        preferredAccountID = try c.decodeIfPresent(AccountID.self, forKey: .preferredAccountID)
        subscribePresence = try c.decodeIfPresent(Bool.self, forKey: .subscribePresence) ?? false
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        importedFrom = try c.decodeIfPresent(UUID.self, forKey: .importedFrom)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(firstName, forKey: .firstName)
        try c.encode(lastName, forKey: .lastName)
        try c.encode(organization, forKey: .organization)
        try c.encode(numbers, forKey: .numbers)
        try c.encode(email, forKey: .email)
        try c.encode(notes, forKey: .notes)
        try c.encode(isFavorite, forKey: .isFavorite)
        // Readable by 26.1, which has only `name` and `number`.
        try c.encode(displayName, forKey: .name)
        try c.encode(number, forKey: .number)
        try c.encodeIfPresent(preferredAccountID, forKey: .preferredAccountID)
        try c.encode(subscribePresence, forKey: .subscribePresence)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encodeIfPresent(importedFrom, forKey: .importedFrom)
    }

    /// Splits at the last space: "Anna Maria Ivanova" becomes ("Anna Maria", "Ivanova"); one word is a first name.
    public static func splitName(_ name: String) -> (first: String, last: String) {
        let s = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let i = s.lastIndex(of: " ") else { return (s, "") }
        return (String(s[..<i]).trimmingCharacters(in: .whitespaces), String(s[s.index(after: i)...]).trimmingCharacters(in: .whitespaces))
    }

    // MARK: Names

    /// "First Last", or whichever of the two is filled, else the organization, else the default number.
    public var displayName: String {
        let f = firstName.trimmingCharacters(in: .whitespaces)
        let l = lastName.trimmingCharacters(in: .whitespaces)
        if !f.isEmpty || !l.isEmpty { return [f, l].filter { !$0.isEmpty }.joined(separator: " ") }
        let o = organization.trimmingCharacters(in: .whitespaces)
        if !o.isEmpty { return o }
        return defaultNumber?.value ?? ""
    }

    /// The first name, last name, organization or number that heads the contact under `order`.
    public func sortKey(_ order: ContactSortOrder) -> String {
        let f = firstName.trimmingCharacters(in: .whitespaces)
        let l = lastName.trimmingCharacters(in: .whitespaces)
        let head = order == .firstName ? (f.isEmpty ? l : f) : (l.isEmpty ? f : l)
        if !head.isEmpty { return head }
        let o = organization.trimmingCharacters(in: .whitespaces)
        return o.isEmpty ? (defaultNumber?.value ?? "") : o
    }

    /// Section letter: the uppercased first character of the sort key if it is a letter, else "#".
    public func sectionLetter(_ order: ContactSortOrder) -> String {
        guard let ch = sortKey(order).first, ch.isLetter else { return "#" }
        return String(ch).uppercased()
    }

    /// Orders by the primary name, then the other one, then the display name.
    public static func sorted(_ list: [Contact], by order: ContactSortOrder) -> [Contact] {
        func cmp(_ a: String, _ b: String) -> ComparisonResult { a.localizedCaseInsensitiveCompare(b) }
        return list.sorted { a, b in
            let (a1, a2) = order == .firstName ? (a.firstName, a.lastName) : (a.lastName, a.firstName)
            let (b1, b2) = order == .firstName ? (b.firstName, b.lastName) : (b.lastName, b.firstName)
            let k = cmp(a.sortKey(order), b.sortKey(order))
            if k != .orderedSame { return k == .orderedAscending }
            let s = cmp(a1 + " " + a2, b1 + " " + b2)
            if s != .orderedSame { return s == .orderedAscending }
            return a.createdAt < b.createdAt
        }
    }

    // MARK: Numbers

    /// Read-only shorthand for `defaultNumber?.value` (the one `number` field of 26.1).
    public var number: String { defaultNumber?.value ?? "" }

    public var defaultNumber: PhoneNumber? { numbers.first(where: \.isDefault) ?? numbers.first }

    /// Default number first, then the others in order.
    public var numbersDefaultFirst: [PhoneNumber] {
        guard let d = defaultNumber, let i = numbers.firstIndex(of: d) else { return numbers }
        var list = numbers
        list.remove(at: i)
        return [d] + list
    }

    /// Key of the default number (`normalize`).
    public var normalizedNumber: String { defaultNumber.map { Contact.normalize($0.value) } ?? "" }

    /// Keys of all numbers; empty values dropped.
    public var allNormalizedNumbers: [String] {
        numbers.map { Contact.normalize($0.value) }.filter { !$0.isEmpty }
    }

    /// 0 when `number` is the default number, 1 when it is another one, nil when it is none of them.
    /// Spaces, dashes and brackets are ignored; the SIP domain counts when both sides have one.
    public func matchRank(_ number: String) -> Int? {
        let key = NumberKey(number)
        guard !key.user.isEmpty else { return nil }
        let defaultIndex = numbers.firstIndex(where: \.isDefault) ?? 0
        var best: Int?
        for (i, n) in numbers.enumerated() where key.matches(NumberKey(n.value)) {
            let rank = i == defaultIndex ? 0 : 1
            best = min(best ?? rank, rank)
        }
        return best
    }

    /// Whether `number` is one of this contact's numbers (see `matchRank`).
    public func hasNumber(_ number: String) -> Bool { matchRank(number) != nil }

    /// The one order contacts are told apart in wherever a tie has to be broken: by display name, then id.
    public static func precedes(_ a: Contact, _ b: Contact) -> Bool {
        let c = a.displayName.localizedCaseInsensitiveCompare(b.displayName)
        if c != .orderedSame { return c == .orderedAscending }
        return a.id.uuidString < b.id.uuidString
    }

    /// Contacts that have `number`, a match on the default number first, ties in `precedes` order.
    public static func candidates(for number: String, in list: [Contact]) -> [Contact] {
        ranked(number, in: list).map(\.0)
    }

    /// The best candidate (for showing a name).
    public static func find(number: String, in list: [Contact]) -> Contact? {
        ranked(number, in: list).first?.0
    }

    /// The candidate only when no other contact matches equally well; nil when two contacts claim the
    /// number (the call log then stays unlinked rather than guessing).
    public static func findUnique(number: String, in list: [Contact]) -> Contact? {
        let all = ranked(number, in: list)
        guard let first = all.first else { return nil }
        return all.dropFirst().contains { $0.1 == first.1 } ? nil : first.0
    }

    private static func ranked(_ number: String, in list: [Contact]) -> [(Contact, Int)] {
        var out: [(Contact, Int)] = []
        for c in list { if let r = c.matchRank(number) { out.append((c, r)) } }
        out.sort { a, b in a.1 != b.1 ? a.1 < b.1 : precedes(a.0, b.0) }
        return out
    }

    /// Case-insensitive match of `query` on names, organization and every number. Number normalisation
    /// (digits only) applies to queries that have no letters.
    public func matches(query: String) -> Bool { matches(ContactQuery(query)) }

    public func matches(_ query: ContactQuery) -> Bool {
        guard !query.isEmpty else { return true }
        let q = query.text
        if displayName.lowercased().contains(q) || organization.lowercased().contains(q) { return true }
        for n in numbers {
            if n.value.lowercased().contains(q) { return true }
            if let digits = query.digits, Contact.normalize(n.value).contains(digits) { return true }
        }
        return false
    }

    /// `query` matches in order: the contacts that match, in the order of `list`.
    public static func search(_ list: [Contact], query: String) -> [Contact] {
        let q = ContactQuery(query)
        return q.isEmpty ? list : list.filter { $0.matches(q) }
    }

    public static func normalize(_ raw: String) -> String {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = s.lowercased()
        if lower.hasPrefix("sip:") || lower.hasPrefix("sips:") || s.contains("@") {
            return DialString.userPart(of: s).lowercased()
        }
        if lower.hasPrefix("tel:") { return DialString.normalizeNumber(String(s.dropFirst(4))) }
        let n = DialString.normalizeNumber(s)
        return n.isEmpty ? lower : n
    }
}

/// A search text prepared once for many contacts.
public struct ContactQuery: Sendable {
    let text: String
    /// The text as a dial string (`Contact.normalize`) when it has no letters and some digits.
    let digits: String?

    public init(_ raw: String) {
        text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if text.contains(where: \.isLetter) { digits = nil }
        else { let n = Contact.normalize(text); digits = n.isEmpty ? nil : n }
    }

    public var isEmpty: Bool { text.isEmpty }
}

/// A number as compared between contacts and callers: the user part (digits for numbers) and, for SIP
/// addresses, the host. Hosts are compared only when both sides have one.
struct NumberKey: Equatable {
    var user: String
    var domain: String?

    init(_ raw: String) {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = s.lowercased()
        user = Contact.normalize(s)
        domain = nil
        if lower.hasPrefix("sip:") || lower.hasPrefix("sips:") || s.contains("@"), let at = s.lastIndex(of: "@") {
            let host = s[s.index(after: at)...].prefix { !";?>:".contains($0) }
            domain = host.isEmpty ? nil : host.lowercased()
        }
    }

    func matches(_ other: NumberKey) -> Bool {
        guard !user.isEmpty, user == other.user else { return false }
        if let a = domain, let b = other.domain { return a == b }
        return true
    }
}
