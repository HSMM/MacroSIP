import Foundation

/// RFC 3842 `application/simple-message-summary` bodies (the voicemail indicator carried by
/// message-summary NOTIFYs):
///
///     Messages-Waiting: yes
///     Message-Account: sip:vm@example.com
///     Voice-Message: 2/8 (1/0)
///
/// Only `Messages-Waiting` and `Voice-Message` are read (fax and other classes are ignored).
/// Folded headers (a line starting with SP or HT continues the previous one, RFC 3842 § 5.2 via
/// RFC 2822 § 2.2.3) are unfolded first.
enum MessageSummary {
    /// Never fails: missing lines count as "no" / 0. Without a `Messages-Waiting` line the
    /// indicator is on when new voice messages are counted.
    static func parse(_ body: String) -> VoicemailState {
        var waiting: Bool?
        var counts = (new: 0, old: 0, urgentNew: 0, urgentOld: 0)
        for raw in unfold(body) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            switch name {
            case "messages-waiting":
                waiting = value.lowercased().hasPrefix("yes")
            case "voice-message":
                counts = self.counts(value)
            default:
                break
            }
        }
        return VoicemailState(waiting: waiting ?? (counts.new > 0), new: counts.new, old: counts.old,
                              urgentNew: counts.urgentNew, urgentOld: counts.urgentOld)
    }

    /// The body's header lines with continuation lines (leading SP or HT) joined to the line before
    /// them by one space; a continuation without a line before it is a line of its own.
    static func unfold(_ body: String) -> [String] {
        var lines: [String] = []
        for raw in body.split(whereSeparator: \.isNewline) {
            let line = String(raw)
            if let first = line.first, first == " " || first == "\t", !lines.isEmpty {
                let rest = line.trimmingCharacters(in: .whitespaces)
                if !rest.isEmpty { lines[lines.count - 1] += " " + rest }
            } else {
                lines.append(line)
            }
        }
        return lines
    }

    /// "2/8 (1/0)" -> new 2, old 8, urgent new 1, urgent old 0; absent numbers are 0.
    static func counts(_ value: String) -> (new: Int, old: Int, urgentNew: Int, urgentOld: Int) {
        var numbers: [Int] = []
        var current = ""
        for ch in value {
            if ch.isASCII, ch.isNumber {
                current.append(ch)
            } else if !current.isEmpty {
                numbers.append(Int(current) ?? 0)
                current = ""
            }
        }
        if !current.isEmpty { numbers.append(Int(current) ?? 0) }
        func at(_ i: Int) -> Int { i < numbers.count ? numbers[i] : 0 }
        return (at(0), at(1), at(2), at(3))
    }
}

extension Engine {
    /// The latest voicemail indicator the account's server reported (RFC 3842 NOTIFY, see
    /// `EngineEvent.voicemail`); nil before the first NOTIFY, after `removeAccount` and after
    /// `stop`. Accounts need `AccountConfig.mwi` for the subscription; unsolicited NOTIFYs
    /// (servers that send them without a subscription) are reported too.
    public func voicemailState(for id: AccountID) -> VoicemailState? {
        bridge.voicemail(of: id)
    }
}
