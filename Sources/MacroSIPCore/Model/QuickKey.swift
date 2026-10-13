import Foundation

/// What a quick key does (SCREENS.md screen 11). The smart types call when idle and act on the active
/// call when in one.
public enum QuickKeyType: String, Codable, CaseIterable, Sendable {
    case call, dtmf, blindTransfer, attendedTransfer, conference
    case smartBlindTransfer, smartAttendedTransfer, smartConference

    /// The type needs an active call: dimmed while idle.
    public var needsCall: Bool {
        switch self {
        case .blindTransfer, .attendedTransfer, .conference: return true
        default: return false
        }
    }

    public var isSmart: Bool {
        switch self {
        case .smartBlindTransfer, .smartAttendedTransfer, .smartConference: return true
        default: return false
        }
    }

    /// What the key does in a call. Smart types become their plain counterpart.
    public var inCallAction: QuickKeyAction {
        switch self {
        case .call: return .call
        case .dtmf: return .sendDigits
        case .blindTransfer, .smartBlindTransfer: return .blindTransfer
        case .attendedTransfer, .smartAttendedTransfer: return .attendedTransfer
        case .conference, .smartConference: return .conference
        }
    }

    /// What the key does with no call. nil = nothing (dimmed).
    public var idleAction: QuickKeyAction? {
        switch self {
        case .call, .dtmf, .smartBlindTransfer, .smartAttendedTransfer, .smartConference: return .call
        case .blindTransfer, .attendedTransfer, .conference: return nil
        }
    }
}

/// The effect of pressing a key, once idle or in-call has been decided.
public enum QuickKeyAction: String, Sendable {
    case call, sendDigits, blindTransfer, attendedTransfer, conference
}

/// Line state shown by the BLF dot.
public enum QuickKeyLineState: String, Sendable {
    case available, busy, ringing, unknown
}

public struct QuickKey: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    /// Number, SIP URI or DTMF digits, as typed.
    public var number: String
    public var type: QuickKeyType
    /// Watch the line state of `number` (presence subscription shared with contacts).
    public var blf: Bool

    public init(id: UUID = UUID(), name: String = "", number: String = "", type: QuickKeyType = .call, blf: Bool = false) {
        self.id = id
        self.name = name
        self.number = number
        self.type = type
        self.blf = blf
    }

    /// Older or hand-edited files may lack fields; the type falls back to `call`.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        number = try c.decodeIfPresent(String.self, forKey: .number) ?? ""
        type = (try? c.decodeIfPresent(QuickKeyType.self, forKey: .type)) ?? .call
        blf = try c.decodeIfPresent(Bool.self, forKey: .blf) ?? false
    }

    /// A row with neither name nor number is an empty slot and is not stored.
    public var isEmpty: Bool {
        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && number.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var trimmedNumber: String { number.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The text on the key: the name, else the number.
    public var title: String {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return n.isEmpty ? trimmedNumber : n
    }

    /// The DTMF digits of `number` (0-9 * # A-D, spaces, dashes and parentheses dropped).
    public var dtmfDigits: String {
        String(number.uppercased().filter { "0123456789*#ABCD".contains($0) })
    }

    /// The number as it is appended to the pickup code: digits of a plain number, the user part of a URI.
    public var pickupNumber: String {
        let s = trimmedNumber
        let lower = s.lowercased()
        if lower.hasPrefix("sip:") || lower.hasPrefix("sips:") || s.contains("@") { return DialString.userPart(of: s) }
        if lower.hasPrefix("tel:") { return DialString.normalizeNumber(String(s.dropFirst(4))) }
        return DialString.normalizeNumber(s)
    }
}

private struct Lossy<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

public enum QuickKeyPanel: String, Codable, CaseIterable, Sendable {
    case off, right, bottom
}

public struct QuickKeysSettings: Codable, Equatable, Sendable {
    public static let maxKeys = 12
    public static let defaultPickupCode = "*8"
    /// Keys 1...9 have a shortcut, ⌘1...⌘9.
    public static let shortcutCount = 9

    public var show: QuickKeyPanel
    public var pickupCode: String
    public var keys: [QuickKey]

    public init(show: QuickKeyPanel = .off, pickupCode: String = QuickKeysSettings.defaultPickupCode, keys: [QuickKey] = []) {
        self.show = show
        self.pickupCode = pickupCode
        self.keys = Array(keys.prefix(Self.maxKeys))
    }

    /// Older settings.json files have no quick keys; they decode as the defaults.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        show = (try? c.decodeIfPresent(QuickKeyPanel.self, forKey: .show)) ?? .off
        pickupCode = try c.decodeIfPresent(String.self, forKey: .pickupCode) ?? Self.defaultPickupCode
        // Element by element: one broken entry is skipped, the others stay.
        let decoded = ((try? c.decodeIfPresent([Lossy<QuickKey>].self, forKey: .keys)) ?? nil)?.compactMap(\.value) ?? []
        keys = Array(decoded.prefix(Self.maxKeys))
    }

    /// Shortcut digit (1...9) of the key at `index` in the list, nil for keys 10...12.
    public static func shortcutDigit(at index: Int) -> Int? {
        (0..<shortcutCount).contains(index) ? index + 1 : nil
    }

    /// The characters a pickup code may hold: digits, `*` and `#`.
    public static func isValidPickupCode(_ code: String) -> Bool {
        !code.isEmpty && code.allSatisfy { "0123456789*#".contains($0) }
    }

    /// The code as it is dialled: trimmed, anything but digits, `*` and `#` dropped.
    public var cleanPickupCode: String {
        String(pickupCode.filter { "0123456789*#".contains($0) })
    }

    /// The SIP URI of a pickup: the code and the user part of the key's own URI, on the key's host
    /// (`*8` and `sip:alice@pbx` give `sip:*8alice@pbx`; `101` on an account of `pbx.example.com` gives
    /// `sip:*8101@pbx.example.com`). Built directly, the code is never run through number normalisation.
    /// `#` is escaped as `%23`. With no number the code alone is dialled (group pickup). nil with no code and
    /// no number.
    public func pickupURI(for key: QuickKey, account: AccountConfig) -> DialString? {
        let code = cleanPickupCode
        var user = ""
        var host = account.domain
        if !key.trimmedNumber.isEmpty, let target = DialString.parse(key.trimmedNumber, account: account) {
            user = DialString.userPart(of: target.uri)
            var rest = target.uri
            if let colon = rest.firstIndex(of: ":") { rest = String(rest[rest.index(after: colon)...]) }
            if let at = rest.firstIndex(of: "@") { host = String(rest[rest.index(after: at)...]) }
        }
        let dialled = code + user
        guard !dialled.isEmpty else { return nil }
        let escaped = dialled.replacingOccurrences(of: "#", with: "%23")
        let uri = DialString.withTransport("sip:\(escaped)@\(host)", account: account)
        return DialString(uri: uri, display: dialled)
    }

    /// Drops empty rows, trims names and caps the list at `maxKeys`.
    public mutating func normalize() {
        keys = keys.compactMap { k in
            var k = k
            k.name = k.name.trimmingCharacters(in: .whitespacesAndNewlines)
            k.number = k.trimmedNumber
            if k.number.isEmpty { k.blf = false }
            return k.isEmpty ? nil : k
        }
        if keys.count > Self.maxKeys { keys.removeLast(keys.count - Self.maxKeys) }
    }

    /// Adds a key at the end. false when the list is full.
    @discardableResult
    public mutating func add(_ key: QuickKey) -> Bool {
        guard keys.count < Self.maxKeys else { return false }
        keys.append(key)
        return true
    }

    public mutating func remove(_ id: UUID) { keys.removeAll { $0.id == id } }

    /// Moves the key at `from` so that it ends at `to` (both indices of the current list).
    public mutating func move(from: Int, to: Int) {
        guard keys.indices.contains(from), keys.indices.contains(to), from != to else { return }
        keys.insert(keys.remove(at: from), at: to)
    }
}

extension QuickKeyLineState {
    /// BLF dot from what the engine reports. `.ringing` (an Asterisk/FreePBX "Ringing" note) is ringing;
    /// `ringing` (a separate source, e.g. demo states) also wins over the status.
    /// available and away: the line is free (green); dnd: on the phone or busy (red); offline, unknown, no
    /// answer yet, or the network is down: grey.
    public init(presence: PresenceStatus?, ringing: Bool = false, networkOnline: Bool = true) {
        guard networkOnline, let presence else { self = .unknown; return }
        if ringing, presence != .offline { self = .ringing; return }
        switch presence {
        case .available, .away: self = .available
        case .dnd: self = .busy
        case .ringing: self = .ringing
        case .offline: self = .unknown
        }
    }
}
