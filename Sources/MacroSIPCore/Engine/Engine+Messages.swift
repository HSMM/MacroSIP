internal import CPJSUA
import Foundation

// Text messages: SIP MESSAGE (RFC 3428) outside dialogs, text/plain;charset=utf-8
// (docs/ENGINE.md "Text messages (SIP MESSAGE)"). Sending: `sendMessage` and
// `pjOnPagerStatus2`; receiving: `pjOnPager2` and the shim's 415 filter (EngineBridge.swift,
// cpjsua_im_send / cpjsua_im_filter_register).

extension Engine {
    /// Longest text `sendMessage` accepts, in UTF-8 bytes: 2800. PJSIP encodes the whole request
    /// into PJSIP_MAX_PKT_LEN (4000) bytes and fails a longer one locally ("Message too long");
    /// the headers take about 460 bytes on a LAN and up to about 1050 with a long domain, a
    /// display name, a Route and the Authorization header after a 401. Follows
    /// PJSIP_MAX_PKT_LEN if config_site.h raises it.
    public static let maxMessageBytes = Int(PJSIP_MAX_PKT_LEN) - messageHeaderReserve
    /// Room kept for the request line and headers of a MESSAGE.
    static let messageHeaderReserve = 1200

    /// Reason of `.messageStatus(id, .failed(code: 0, reason:))` for a MESSAGE still waiting for
    /// its answer when the engine stopped.
    public static let messageInterruptedReason = "interrupted"

    /// Sends `text` as `MESSAGE` (Content-Type text/plain;charset=utf-8) from `account` to
    /// `dial.uri`. Returns at once; the outcome arrives as `.messageStatus(id, result)` exactly
    /// once per id. Throws `.notStarted`, `.unknownAccount`, `.invalidArgument` (empty text,
    /// text over `maxMessageBytes` UTF-8 bytes, a target that is not a SIP URI) and `.pjsip`
    /// when pjsua cannot create the request (no event follows then).
    ///
    /// A failure while sending (transport or DNS error) may be reported before this returns.
    /// Callers that must match the status to a message they stored use
    /// `sendMessage(_:to:from:id:)` with that message's id.
    public func sendMessage(_ text: String, to dial: DialString, from account: AccountID) throws -> MessageID {
        try sendMessage(text, to: dial, from: account, id: MessageID())
    }

    /// `sendMessage(_:to:from:)` with an id the caller chose (a fresh one per message), so the
    /// status event can be matched however early it comes.
    public func sendMessage(_ text: String, to dial: DialString, from account: AccountID,
                            id: MessageID) throws -> MessageID {
        try requireStarted()
        guard let entry = accounts[account] else { throw EngineError.unknownAccount(account) }
        let bytes = Array(text.utf8)
        guard !bytes.isEmpty else { throw EngineError.invalidArgument("empty message") }
        guard bytes.count <= Engine.maxMessageBytes else {
            throw EngineError.invalidArgument("message of \(bytes.count) bytes (at most \(Engine.maxMessageBytes))")
        }
        guard pjsua_verify_sip_url(dial.uri) == PJ.success else {
            throw EngineError.invalidArgument("message target \(dial.uri)")
        }
        // Registered before the request exists: pjsua may report it before cpjsua_im_send returns.
        let token = bridge.allocateSerial()
        bridge.addPendingMessage(token, PendingMessage(id: id, accountID: account, target: dial.uri))
        let status = bytes.withUnsafeBytes { raw in
            cpjsua_im_send(entry.index, dial.uri, raw.baseAddress?.assumingMemoryBound(to: CChar.self),
                           UInt32(raw.count), token)
        }
        if status != PJ.success {
            // Still pending: pjsua failed before the transaction existed and will not report it.
            // Otherwise on_pager_status2 has already emitted the failure for `id`.
            if bridge.takePendingMessage(token) != nil { throw PJ.error(status, "MESSAGE to \(dial.uri)") }
            return id
        }
        emit(.log(level: 4, "engine: \(id) sent to \(dial.uri) (\(bytes.count) bytes)"))
        return id
    }

    /// `stop`: MESSAGEs whose answer can no longer arrive fail with `messageInterruptedReason`.
    /// pjsua_destroy normally reports them itself (503 without a response, mapped to the same
    /// result while the bridge is stopping); this catches any it left. Call after pjsua_destroy
    /// and before the bridge is detached; emit the returned events after.
    func interruptedMessageEvents() -> [EngineEvent] {
        bridge.takeAllPendingMessages().map {
            .messageStatus($0.id, .failed(code: 0, reason: Engine.messageInterruptedReason))
        }
    }
}

/// An outgoing MESSAGE waiting for its final answer (`EngineBridge.State.pendingMessages`).
struct PendingMessage: Sendable {
    var id: MessageID
    var accountID: AccountID
    /// The Request-URI (for log lines).
    var target: String
}

/// Keeps the text of MESSAGEs out of the log (`pjLogWriter`: os_log, `.log` events, the file
/// log and the diagnostics archive). PJSIP writes it in pjsua_im.c's "Message '<text>' delivered
/// successfully" (level 4) and "Failed to deliver message '<text>': <code>/<reason>" (level 3),
/// and in the packet dumps of a MESSAGE request: pjsua's "RX/TX ... bytes ...:\n<packet>\n--end
/// msg--" (level 4) and pjsip's "Dropped packet:<packet>\n-- end of packet." (level 4). The text
/// or the body becomes "…"; status, reason, request line and headers stay. Where the end of the
/// text is ambiguous, more is replaced, never less.
enum MessageLogRedaction {
    static let placeholder = "…"

    static func redact(_ line: String) -> String {
        // Every log line passes here: only lines that can carry a MESSAGE are looked at.
        guard line.contains("essage '") || line.contains("MESSAGE ") else { return line }
        var out = line
        if !redactDelivery(&out) { redactPacketBody(&out) }
        return out
    }

    /// pjsua_im.c's delivery lines. Returns true when the line was one.
    private static func redactDelivery(_ s: inout String) -> Bool {
        if let start = s.range(of: "Message '"),
           let end = s.range(of: "' delivered successfully", options: .backwards), start.upperBound <= end.lowerBound {
            s.replaceSubrange(start.upperBound..<end.lowerBound, with: placeholder)
            return true
        }
        guard let start = s.range(of: "Failed to deliver message '") else { return false }
        // The text ends at the last "': <digits>/" (pjsua appends "<code>/<reason>").
        var searchEnd = s.endIndex
        while let quote = s.range(of: "': ", options: .backwards, range: start.upperBound..<searchEnd) {
            let tail = s[quote.upperBound...]
            let digits = tail.prefix { $0.isASCII && $0.isNumber }
            if !digits.isEmpty, tail.dropFirst(digits.count).first == "/" {
                s.replaceSubrange(start.upperBound..<quote.lowerBound, with: placeholder)
                return true
            }
            searchEnd = quote.lowerBound
        }
        s.replaceSubrange(start.upperBound..<s.endIndex, with: placeholder + "'")
        return true
    }

    /// The body of a dumped MESSAGE request (after its blank line, up to the end marker).
    private static func redactPacketBody(_ s: inout String) {
        for (startMarker, endMarker) in [("Dropped packet:", "\n-- end of packet."), (":\n", "\n--end msg--")] {
            guard let end = s.range(of: endMarker, options: .backwards),
                  let start = s.range(of: startMarker, range: s.startIndex..<end.lowerBound) else { continue }
            let packet = start.upperBound..<end.lowerBound
            guard s[packet].drop(while: { $0.isWhitespace }).hasPrefix("MESSAGE ") else { continue }
            guard let blank = s.range(of: "\r\n\r\n", range: packet) ?? s.range(of: "\n\n", range: packet),
                  blank.upperBound < end.lowerBound else { return }      // no body
            s.replaceSubrange(blank.upperBound..<end.lowerBound, with: placeholder)
            return
        }
    }
}

/// Pure mappings of the MESSAGE callbacks (tested without pjsua).
enum MessageMapping {
    /// `on_pager_status2` -> result. 2xx: accepted. A response: its code and reason phrase. No
    /// response (`answered == false`): 408 for the transaction timeout, else a local failure
    /// (pjsua reports transport errors as 503 and DNS errors as 502 with the pj_strerror text
    /// as reason), which becomes code 0 with that text.
    static func result(code: Int, reason: String, answered: Bool) -> MessageSendResult {
        if (200...299).contains(code) { return .accepted(code: code) }
        let text = reason.isEmpty ? PJ.string(pjsip_get_status_text(Int32(code)).pointee) : reason
        if !answered && code != 408 { return .failed(code: 0, reason: text) }
        return .failed(code: code, reason: text)
    }

    /// `on_pager2` -> event, nil for a MESSAGE that is not text/plain or has no body.
    /// `mimeType` is pjsua's "type/subtype" (parameters dropped); `from` the From name-addr.
    static func incoming(account: AccountID, from: String, mimeType: String, body: String, at: Date) -> IncomingMessage? {
        guard mimeType.trimmingCharacters(in: .whitespaces).lowercased() == "text/plain", !body.isEmpty else { return nil }
        return IncomingMessage(accountID: account, remote: RemoteParty.parse(from), text: body, receivedAt: at)
    }
}
