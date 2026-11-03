import Foundation

/// Which log level the app runs at: the launch default, or debug mode's level 4.
public enum LogLevelPolicy {
    public static let debugLevel = 4

    /// - Parameters:
    ///   - launchLevel: `--log-level` / `MACROSIP_LOG_LEVEL`, or the default 3.
    ///   - explicit: the level was given at launch; it then wins over the debug switch.
    public static func effectiveLevel(launchLevel: Int, explicit: Bool, debugMode: Bool) -> Int {
        explicit ? launchLevel : (debugMode ? max(launchLevel, debugLevel) : launchLevel)
    }
}

/// Removes secrets from text that leaves the machine (the diagnostics archive). Pure: the caller
/// applies it to copies, never to the original log files.
///
/// What is replaced by `<redacted>`:
/// - the values of `response`, `nonce`, `cnonce`, `opaque` (and `rspauth`, `nextnonce`) in
///   `Authorization`, `Proxy-Authorization`, `WWW-Authenticate`, `Proxy-Authenticate` and
///   `Authentication-Info` headers, quoted or not, on continuation lines too, with or without a space
///   after the colon; the credentials of a `Basic` or `Bearer` scheme;
/// - the value of any key whose name contains `password`, `passwd`, `pwd`, `secret` or `token`
///   (`password=x`, `"password": "x"`, `access_token=...`);
/// - the password in `scheme://user:password@host` and `sip:user:password@host`;
/// - the value of `key`, `api_key`, `auth`, `sig` and similar query parameters.
/// Phone numbers, user names and server addresses are kept.
public enum LogRedaction {
    public static let mark = "<redacted>"

    public static func redact(_ text: String) -> String {
        var out = redactAuthHeaders(text)
        out = replace(passwordKey, in: out, with: "$1" + mark)
        out = replace(urlPassword, in: out, with: "$1$2:" + mark + "@")
        out = replace(sipPassword, in: out, with: "$1:" + mark + "@")
        out = replace(queryParam, in: out, with: "$1" + mark)
        return out
    }

    // MARK: Authentication headers

    private static let authHeader = rx(#"(?:^|\s)(?:Proxy-Authorization|Authorization|WWW-Authenticate|Proxy-Authenticate|Authentication-Info)\s*:"#, [.caseInsensitive])
    private static let anyHeader = rx(#"^\s*[A-Za-z][A-Za-z0-9-]*\s*:"#, [])
    private static let recordStart = rx(#"^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d"#, [])
    private static let digestParam = rx(#"(?<![A-Za-z0-9_-])((?:response|nonce|cnonce|opaque|rspauth|nextnonce)\s*=\s*)("[^"]*"|[^\s,;"]*)"#, [.caseInsensitive])
    private static let basicBearer = rx(#"(\b(?:Basic|Bearer)\s+)[^\s,]+"#, [.caseInsensitive])

    private static func redactAuthHeaders(_ text: String) -> String {
        let lower = text.lowercased()
        guard lower.contains("authorization") || lower.contains("authenticate") || lower.contains("authentication-info") else { return text }
        var result: [Substring] = []
        var inHeader = false
        var pieces = text.split(separator: "\n", omittingEmptySubsequences: false)
        let endsWithNewline = pieces.last?.isEmpty == true && pieces.count > 1
        if endsWithNewline { pieces.removeLast() }
        for piece in pieces {
            let line = String(piece)
            if matches(authHeader, line) {
                inHeader = true
                result.append(Substring(redactAuthValue(line)))
            } else if inHeader, !matches(recordStart, line), !matches(anyHeader, line),
                      let first = line.first, first == " " || first == "\t",
                      !line.trimmingCharacters(in: .whitespaces).isEmpty {
                result.append(Substring(redactAuthValue(line)))
            } else {
                inHeader = false
                result.append(piece)
            }
        }
        return result.joined(separator: "\n") + (endsWithNewline ? "\n" : "")
    }

    private static func redactAuthValue(_ line: String) -> String {
        var s = replace(digestParam, in: line, with: "$1" + mark)
        s = replace(basicBearer, in: s, with: "$1" + mark)
        return s
    }

    // MARK: Other secrets

    private static let passwordKey = rx(#"(["']?[A-Za-z0-9_.-]*(?:password|passwd|pwd|secret|token)[A-Za-z0-9_.-]*["']?\s*[=:]\s*)("[^"]*"|'[^']*'|[^\s,;&"'<>]+)"#, [.caseInsensitive])
    private static let urlPassword = rx(#"([A-Za-z][A-Za-z0-9+.-]*://)([^/\s:@]+):[^/\s@]+@"#, [])
    private static let sipPassword = rx(#"(\bsips?:[^:@\s;>"]+):[^@\s;>"]+@"#, [.caseInsensitive])
    private static let queryParam = rx(#"([?&;](?:key|api[_-]?key|apikey|auth|sig|signature|code|sid)=)[^&\s"'<>]+"#, [.caseInsensitive])

    // MARK: Helpers

    private static func rx(_ pattern: String, _ options: NSRegularExpression.Options) -> NSRegularExpression {
        var o = options
        o.insert(.anchorsMatchLines)
        // Patterns are literals above; a failure is a programming error caught by the tests.
        return try! NSRegularExpression(pattern: pattern, options: o)
    }

    private static func matches(_ regex: NSRegularExpression, _ s: String) -> Bool {
        regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    private static func replace(_ regex: NSRegularExpression, in s: String, with template: String) -> String {
        regex.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
    }
}
