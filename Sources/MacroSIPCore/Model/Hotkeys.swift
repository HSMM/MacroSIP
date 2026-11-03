import Foundation

/// What a global hotkey does (Settings › Calls › Global hotkeys).
public enum HotkeyAction: String, Codable, CaseIterable, Sendable {
    case answer, hangUp, mute
}

/// The modifier keys of a combination. The raw values are the app's own (stored in settings.json),
/// not Carbon's; the platform code translates.
public struct HotkeyModifiers: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let command = HotkeyModifiers(rawValue: 1 << 0)
    public static let control = HotkeyModifiers(rawValue: 1 << 1)
    public static let option = HotkeyModifiers(rawValue: 1 << 2)
    public static let shift = HotkeyModifiers(rawValue: 1 << 3)

    /// ⌘, ⌃ or ⌥ is present. Shift alone would fire while typing capital letters.
    public var hasCommandControlOrOption: Bool { !isDisjoint(with: [.command, .control, .option]) }
}

/// Why a combination was refused.
public enum HotkeyIssue: Equatable, Sendable {
    /// None of ⌘ ⌃ ⌥ is part of it.
    case needsModifier
    /// The key has no name in the table (it cannot be shown, so it cannot be chosen).
    case unsupportedKey
    /// The app's own menus already use it.
    case usedByMenu
    /// Another action of the app already has it.
    case duplicate(of: HotkeyAction)
}

/// A key and its modifiers. `keyCode` is the macOS virtual key code (a position on the keyboard, the same
/// in every layout), which is what Carbon hotkeys use.
public struct HotkeyCombo: Codable, Hashable, Sendable {
    public var keyCode: Int
    public var modifiers: HotkeyModifiers

    public init(keyCode: Int, modifiers: HotkeyModifiers) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    // Defaults: ⌃⌥A, ⌃⌥H, ⌃⌥M.
    public static let defaultAnswer = HotkeyCombo(keyCode: 0, modifiers: [.control, .option])
    public static let defaultHangUp = HotkeyCombo(keyCode: 4, modifiers: [.control, .option])
    public static let defaultMute = HotkeyCombo(keyCode: 46, modifiers: [.control, .option])

    /// Problems of the combination on its own; nil = fine. Duplicates are `HotkeySettings`' business.
    public var issue: HotkeyIssue? {
        if Self.keyNames[keyCode] == nil { return .unsupportedKey }
        if !modifiers.hasCommandControlOrOption { return .needsModifier }
        if Self.menuShortcuts.contains(self) { return .usedByMenu }
        return nil
    }

    /// "⌃⌥A": modifiers in the order macOS menus show them (⌃ ⌥ ⇧ ⌘), then the key.
    public var display: String {
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option) { s += "⌥" }
        if modifiers.contains(.shift) { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        return s + (Self.keyNames[keyCode] ?? "?")
    }

    /// Shortcuts of the app's menus (MacroSIPApp.swift, the Quick keys items) and the standard ones every
    /// Mac app shows. A global hotkey on one of these would take it away from the menu.
    public static let menuShortcuts: Set<HotkeyCombo> = {
        var set: Set<HotkeyCombo> = [
            HotkeyCombo(keyCode: 2, modifiers: .command),                    // ⌘D End Call
            HotkeyCombo(keyCode: 46, modifiers: [.command, .shift]),         // ⇧⌘M Mute
            HotkeyCombo(keyCode: 126, modifiers: .command),                  // ⌘↑ volume up
            HotkeyCombo(keyCode: 125, modifiers: .command),                  // ⌘↓ volume down
            HotkeyCombo(keyCode: 2, modifiers: [.command, .option]),         // ⌥⌘D Do Not Disturb
            HotkeyCombo(keyCode: 29, modifiers: .command),                   // ⌘0 show the app
        ]
        for code in [18, 19, 20, 21, 23, 22, 26, 28, 25] {                   // ⌘1…⌘9 quick keys
            set.insert(HotkeyCombo(keyCode: code, modifiers: .command))
        }
        // Standard: Quit, Close, Hide, Minimize, Settings, Find, Copy, Cut, Paste, Select All, Undo, Redo, New.
        for code in [12, 13, 4, 46, 43, 3, 8, 7, 9, 0, 6, 45] {
            set.insert(HotkeyCombo(keyCode: code, modifiers: .command))
        }
        set.insert(HotkeyCombo(keyCode: 6, modifiers: [.command, .shift]))
        return set
    }()

    /// Names of the keys, as on an ANSI keyboard.
    static let keyNames: [Int: String] = {
        var n: [Int: String] = [
            0: "A", 11: "B", 8: "C", 2: "D", 14: "E", 3: "F", 5: "G", 4: "H", 34: "I", 38: "J", 40: "K", 37: "L",
            46: "M", 45: "N", 31: "O", 35: "P", 12: "Q", 15: "R", 1: "S", 17: "T", 32: "U", 9: "V", 13: "W",
            7: "X", 16: "Y", 6: "Z",
            29: "0", 18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9",
            27: "-", 24: "=", 33: "[", 30: "]", 41: ";", 39: "'", 43: ",", 47: ".", 44: "/", 42: "\\", 50: "`",
            36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 117: "⌦", 53: "⎋",
            123: "←", 124: "→", 125: "↓", 126: "↑", 115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
            82: "Num 0", 83: "Num 1", 84: "Num 2", 85: "Num 3", 86: "Num 4", 87: "Num 5", 88: "Num 6",
            89: "Num 7", 91: "Num 8", 92: "Num 9", 65: "Num .", 67: "Num *", 69: "Num +", 75: "Num /",
            78: "Num -", 81: "Num =", 76: "Num ↩",
        ]
        let f: [Int: Int] = [1: 122, 2: 120, 3: 99, 4: 118, 5: 96, 6: 97, 7: 98, 8: 100, 9: 101, 10: 109, 11: 103,
                             12: 111, 13: 105, 14: 107, 15: 113, 16: 106, 17: 64, 18: 79, 19: 80, 20: 90]
        for (number, code) in f { n[code] = "F\(number)" }
        return n
    }()
}

/// Settings › Calls › Global hotkeys. Off by default; a file without the key decodes as off.
public struct HotkeySettings: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var answer: HotkeyCombo?
    public var hangUp: HotkeyCombo?
    public var mute: HotkeyCombo?
    /// The fields were pre-filled once (the first time the switch went on); after that they are the user's.
    public var prefilled: Bool

    public init(enabled: Bool = false, answer: HotkeyCombo? = nil, hangUp: HotkeyCombo? = nil,
                mute: HotkeyCombo? = nil, prefilled: Bool = false) {
        self.enabled = enabled
        self.answer = answer
        self.hangUp = hangUp
        self.mute = mute
        self.prefilled = prefilled
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? false
        answer = try? c.decodeIfPresent(HotkeyCombo.self, forKey: .answer)
        hangUp = try? c.decodeIfPresent(HotkeyCombo.self, forKey: .hangUp)
        mute = try? c.decodeIfPresent(HotkeyCombo.self, forKey: .mute)
        prefilled = (try? c.decodeIfPresent(Bool.self, forKey: .prefilled)) ?? false
    }

    public subscript(action: HotkeyAction) -> HotkeyCombo? {
        get {
            switch action {
            case .answer: return answer
            case .hangUp: return hangUp
            case .mute: return mute
            }
        }
        set {
            switch action {
            case .answer: answer = newValue
            case .hangUp: hangUp = newValue
            case .mute: mute = newValue
            }
        }
    }

    /// Turns the switch on or off. The first time on, the three fields get ⌃⌥A, ⌃⌥H, ⌃⌥M.
    public mutating func setEnabled(_ on: Bool) {
        enabled = on
        if on, !prefilled {
            answer = .defaultAnswer
            hangUp = .defaultHangUp
            mute = .defaultMute
            prefilled = true
        }
    }

    /// Assigns (or, with nil, clears) a combination. A refused one leaves the settings as they were
    /// and returns why.
    @discardableResult
    public mutating func assign(_ combo: HotkeyCombo?, to action: HotkeyAction) -> HotkeyIssue? {
        if let combo {
            if let issue = combo.issue { return issue }
            if let other = HotkeyAction.allCases.first(where: { $0 != action && self[$0] == combo }) {
                return .duplicate(of: other)
            }
        }
        self[action] = combo
        return nil
    }

    /// The combinations that should be registered now: none while off; invalid or repeated ones
    /// (a hand-edited file) are left out, the first action in `allCases` order keeps a repeated one.
    public var active: [HotkeyAction: HotkeyCombo] {
        guard enabled else { return [:] }
        var out: [HotkeyAction: HotkeyCombo] = [:]
        for action in HotkeyAction.allCases {
            guard let combo = self[action], combo.issue == nil, !out.values.contains(combo) else { continue }
            out[action] = combo
        }
        return out
    }
}

/// The part of the call list a hotkey looks at.
public struct HotkeyCallState: Equatable, Sendable {
    /// Ringing incoming calls, the oldest first.
    public var ringing: [CallID]
    /// The call a command applies to (the active one, else the first held one); nil = no call.
    public var current: CallID?
    /// Calls in the running conference (0 = none).
    public var conferenceLegs: Int

    public init(ringing: [CallID], current: CallID?, conferenceLegs: Int = 0) {
        self.ringing = ringing
        self.current = current
        self.conferenceLegs = conferenceLegs
    }
}

/// What a hotkey press leads to. The app maps each to the action its buttons use.
public enum HotkeyEffect: Equatable, Sendable {
    case none
    /// The Answer button of the incoming window.
    case answer(CallID)
    /// The Decline button of the incoming window.
    case decline(CallID)
    /// The End Call button of the call panel.
    case hangUp(CallID)
    /// The End Conference button (two or more legs).
    case endConference
    /// Call › Mute (the current call).
    case toggleMute

    /// Answer: the oldest ringing call. Hang up: a conference ends as a whole, else the current call, else
    /// a ringing call is declined. Mute: the current call. No call, no effect.
    public static func resolve(_ action: HotkeyAction, _ state: HotkeyCallState) -> HotkeyEffect {
        switch action {
        case .answer:
            return state.ringing.first.map(HotkeyEffect.answer) ?? .none
        case .hangUp:
            if state.conferenceLegs >= 2 { return .endConference }
            if let current = state.current { return .hangUp(current) }
            return state.ringing.first.map(HotkeyEffect.decline) ?? .none
        case .mute:
            return state.current == nil ? .none : .toggleMute
        }
    }
}
