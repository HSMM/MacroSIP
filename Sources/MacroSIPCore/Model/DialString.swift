import Foundation

/// A resolved call target. Built from what the user typed plus the outgoing account.
public struct DialString: Equatable, Sendable {
    /// Full SIP URI, e.g. "sip:100@sip.example.com;transport=tls".
    public let uri: String
    /// What to show in the UI and store in the call log, e.g. "100" or "+74951234567".
    public let display: String

    public init(uri: String, display: String) {
        self.uri = uri
        self.display = display
    }

    /// Rules (see docs/ENGINE.md "Dial strings"):
    /// - `sip:`/`sips:` URIs are used as is.
    /// - `tel:` keeps digits and a leading "+", then becomes sip:<digits>@<domain>.
    /// - plain numbers lose spaces, parentheses and dashes; "+" is kept; then sip:<result>@<domain>.
    /// - "user@host" without a scheme gets "sip:".
    /// - transport parameter is appended for TCP/TLS accounts unless the URI already has one.
    public static func parse(_ raw: String, account: AccountConfig) -> DialString? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lower = trimmed.lowercased()

        if lower.hasPrefix("sip:") || lower.hasPrefix("sips:") {
            let user = userPart(of: trimmed)
            return DialString(uri: withTransport(trimmed, account: account), display: user)
        }
        if lower.hasPrefix("tel:") {
            let number = normalizeNumber(String(trimmed.dropFirst(4)))
            guard !number.isEmpty else { return nil }
            return DialString(uri: withTransport("sip:\(number)@\(account.domain)", account: account), display: number)
        }
        if trimmed.contains("@") {
            return DialString(uri: withTransport("sip:\(trimmed)", account: account), display: userPart(of: trimmed))
        }
        let number = normalizeNumber(trimmed)
        guard !number.isEmpty else { return nil }
        return DialString(uri: withTransport("sip:\(number)@\(account.domain)", account: account), display: number)
    }

    static func normalizeNumber(_ s: String) -> String {
        var out = ""
        for (i, ch) in s.enumerated() {
            if ch.isNumber || ch == "*" || ch == "#" { out.append(ch) }
            else if ch == "+" && i == 0 { out.append(ch) }
            // spaces, parentheses, dashes and dots are dropped
        }
        return out
    }

    static func userPart(of uri: String) -> String {
        var s = uri
        if let colon = s.firstIndex(of: ":"), s[..<colon].lowercased().hasPrefix("sip") {
            s = String(s[s.index(after: colon)...])
        }
        if let at = s.firstIndex(of: "@") { s = String(s[..<at]) }
        return s
    }

    static func withTransport(_ uri: String, account: AccountConfig) -> String {
        guard account.transport != .udp, !uri.lowercased().contains("transport=") else { return uri }
        return "\(uri);transport=\(account.transport.rawValue)"
    }
}
