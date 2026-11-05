import Foundation
import MacroSIPCore

/// What the Messages tab shows for stored data (SCREENS.md 14): row times, day separators, grouped bubbles, status lines and
/// failure reasons. Pure functions of the data, a date and a calendar, so the demo self-test can check them.
enum MessageFormat {
    /// Time column of a conversation row: today the time, yesterday the word, the last 6 days the weekday, older the date
    /// without the year (with it when not this year).
    static func rowTime(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let days = daysBetween(date, now, calendar)
        if days <= 0 { return date.formatted(date: .omitted, time: .shortened) }
        if days == 1 { return L.messagesDayYesterday }
        if days <= 6 { return date.formatted(.dateTime.weekday(.abbreviated)) }
        if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            return date.formatted(.dateTime.day().month(.abbreviated))
        }
        return date.formatted(.dateTime.day().month(.abbreviated).year())
    }

    /// Day separator of a conversation: Today, Yesterday, then "Mon, 6 Oct" (as the call log sections).
    static func daySeparator(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let days = daysBetween(date, now, calendar)
        if days == 0 { return L.messagesDayToday }
        if days == 1 { return L.messagesDayYesterday }
        return date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }

    private static func daysBetween(_ date: Date, _ now: Date, _ calendar: Calendar) -> Int {
        calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
    }

    static func timeOfDay(_ date: Date) -> String { date.formatted(date: .omitted, time: .shortened) }

    /// The last message on one line: line breaks become spaces; an outgoing one starts with "You: ".
    static func preview(_ message: Message) -> String {
        let flat = message.text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ")
        return message.direction == .outgoing ? L.messagesRowYou(flat) : flat
    }

    /// Text after "Not sent · ": the answer as received ("404 Not Found"), "Interrupted", "No connection" for a transport or
    /// name-resolution failure (the engine's own text is the tooltip), and otherwise the engine's text itself ("Message too
    /// long (PJSIP_EMSGTOOLONG)").
    static func failure(_ message: Message) -> (reason: String, tooltip: String?) {
        let code = message.failureCode ?? 0
        let phrase = (message.failureReason ?? "").trimmingCharacters(in: .whitespaces)
        if (300...699).contains(code) { return (phrase.isEmpty ? "\(code)" : "\(code) \(phrase)", nil) }
        if phrase == Engine.messageInterruptedReason { return (L.messagesErrorInterrupted, nil) }
        if phrase.isEmpty { return (L.messagesErrorLocal, nil) }
        return isConnectionProblem(phrase) ? (L.messagesErrorLocal, phrase) : (phrase, nil)
    }

    /// The texts pjsua gives when the request could not be sent or the host not found (strerror of the socket, DNS and
    /// transport errors; a 502/503 the engine turned into code 0).
    private static let connectionTexts = [
        "unreachable", "refused", "host is down", "no route", "timed out", "timeout", "connection", "network", "resolve",
        "dns", "name or service", "no such host", "broken pipe", "reset", "socket", "transport", "permission denied",
        "bad gateway", "service unavailable", "offline",
    ]

    static func isConnectionProblem(_ text: String) -> Bool {
        let lower = text.lowercased()
        return connectionTexts.contains { lower.contains($0) }
    }

    /// One line of the thread: a day separator, or a bubble with what goes under it.
    struct Row: Identifiable, Equatable {
        enum Kind: Equatable { case day(String), bubble(Message) }
        var id: String
        var kind: Kind
        /// The time line under the bubble (the last of its group, and every message still sending or not sent).
        var showsMeta = false
        /// "Sent": the last outgoing message, accepted.
        var showsSent = false
        /// Space above: 2 pt inside a group, 8 pt between groups, 0 under a day separator or at the top.
        var gap: CGFloat = 0
    }

    /// Messages that follow each other in one direction less than 2 minutes apart, on one day, form a group.
    static let groupInterval: TimeInterval = 120

    static func thread(_ messages: [Message], now: Date = Date(), calendar: Calendar = .current) -> [Row] {
        var rows: [Row] = []
        let lastOutgoing = messages.last { $0.direction == .outgoing }?.id
        for (i, m) in messages.enumerated() {
            let previous = i > 0 ? messages[i - 1] : nil
            let next = i + 1 < messages.count ? messages[i + 1] : nil
            let newDay = previous.map { !calendar.isDate($0.at, inSameDayAs: m.at) } ?? true
            if newDay { rows.append(Row(id: "day-\(m.id)", kind: .day(daySeparator(m.at, now: now, calendar: calendar)))) }
            let withPrevious = !newDay && previous.map { grouped($0, m) } == true
            let withNext = next.map { calendar.isDate($0.at, inSameDayAs: m.at) && grouped(m, $0) } == true
            rows.append(Row(
                id: m.id.uuidString, kind: .bubble(m),
                showsMeta: !withNext || m.state != .sent,
                showsSent: m.id == lastOutgoing && m.state == .sent,
                gap: newDay ? 0 : (withPrevious ? 2 : 8)))
        }
        return rows
    }

    private static func grouped(_ a: Message, _ b: Message) -> Bool {
        a.direction == b.direction && b.at.timeIntervalSince(a.at) < groupInterval && b.at >= a.at
    }
}
