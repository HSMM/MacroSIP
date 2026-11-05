import Foundation
import os
import Testing
@testable import MacroSIPCore

// Text messages (docs/ENGINE.md "Text messages (SIP MESSAGE)"): sending with each outcome,
// receiving (Cyrillic from chan_dongle, the 415 filter, account mapping, inside a call),
// validation, and the pure mappings.

// MARK: - MESSAGE stub

/// A SIP peer on 127.0.0.1 (one UDP socket, random port) for the MESSAGE tests. Every MESSAGE
/// it receives is recorded byte for byte and answered with `answer` (a status line such as
/// "404 Not Found"; nil = no answer at all, so the sender times out). It answers an INVITE with
/// 200 and a PCMU SDP (it never sends RTP) and remembers that dialog for `sendInDialogMessage`;
/// any other request gets 200. It sends MESSAGEs of its own as Asterisk/chan_dongle does
/// (`sendMessage`) and records the status lines of the answers by Call-ID.
final class MessageStub: Sendable {
    struct Request: Sendable {
        var requestLine: String
        /// Header lines as received ("Content-Type: text/plain;charset=utf-8").
        var headers: [String]
        var body: [UInt8]
        /// Size of the whole datagram.
        var size: Int

        /// Value of the first header called `name` (case-insensitive), trimmed.
        func header(_ name: String) -> String? {
            for line in headers {
                guard let colon = line.firstIndex(of: ":"),
                      line[..<colon].trimmingCharacters(in: .whitespaces).lowercased() == name.lowercased() else { continue }
                return line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            return nil
        }
    }

    struct Response: Sendable {
        var callID: String
        var statusLine: String
    }

    /// The call the engine set up with the stub (for an in-dialog MESSAGE).
    struct Dialog: Sendable {
        var callID: String
        /// The engine's From header value (with its tag): our To.
        var remote: String
        /// The engine's To header value with our tag: our From.
        var local: String
        /// The engine's Contact URI: the Request-URI of our requests.
        var target: String
        var cseq = 1
    }

    let port: UInt16
    private let fd: Int32
    private let stopped = OSAllocatedUnfairLock(initialState: false)
    private let answerLock = OSAllocatedUnfairLock<String?>(initialState: "200 OK")
    private let received = OSAllocatedUnfairLock(initialState: [Request]())
    private let answers = OSAllocatedUnfairLock(initialState: [Response]())
    private let dialog = OSAllocatedUnfairLock<Dialog?>(initialState: nil)

    /// Status line for MESSAGEs ("200 OK"); nil = never answer.
    var answer: String? {
        get { answerLock.withLock { $0 } }
        set { answerLock.withLock { $0 = newValue } }
    }

    /// MESSAGE requests received, retransmissions included, in order.
    var messages: [Request] { received.withLock { $0 } }
    var responses: [Response] { answers.withLock { $0 } }
    var hasDialog: Bool { dialog.withLock { $0 != nil } }

    /// Status lines of the answers to the request with this Call-ID.
    func responses(to callID: String) -> [String] {
        responses.filter { $0.callID == callID }.map(\.statusLine)
    }

    init() throws {
        let sock = socket(AF_INET, SOCK_DGRAM, 0)
        guard sock >= 0 else { throw EngineError.unsupported("socket") }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let ok = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(sock, $0, len) == 0 && getsockname(sock, $0, &len) == 0
            }
        }
        guard ok else { close(sock); throw EngineError.unsupported("bind") }
        var tv = timeval(tv_sec: 0, tv_usec: 100_000)
        setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        fd = sock
        port = UInt16(bigEndian: addr.sin_port)
        Thread.detachNewThread { [self] in self.serve() }
    }

    func stop() { stopped.withLock { $0 = true } }

    private func serve() {
        var buf = [UInt8](repeating: 0, count: 65_536)
        while !stopped.withLock({ $0 }) {
            var from = sockaddr_in()
            var fromLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &from) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buf, buf.count, 0, $0, &fromLen) }
            }
            guard n > 0 else { continue }
            handle(Array(buf[0..<n]), from: from)
        }
        close(fd)
    }

    private func handle(_ data: [UInt8], from: sockaddr_in) {
        let separator: [UInt8] = [13, 10, 13, 10]
        let range = data.firstRange(of: separator)
        let head = String(decoding: data[..<(range?.lowerBound ?? data.count)], as: UTF8.self)
        let body = range.map { Array(data[$0.upperBound...]) } ?? []
        let lines = head.components(separatedBy: "\r\n")
        guard let first = lines.first else { return }
        let request = Request(requestLine: first, headers: Array(lines.dropFirst()), body: body, size: data.count)
        if first.hasPrefix("SIP/2.0") {
            answers.withLock { $0.append(Response(callID: request.header("Call-ID") ?? "", statusLine: first)) }
            return
        }
        let method = String(first.prefix { $0 != " " })
        guard method != "ACK" else { return }
        var to = request.header("To") ?? ""
        if !to.lowercased().contains("tag=") { to += ";tag=msg-stub-\(UInt32.random(in: 1...UInt32.max))" }

        func reply(_ status: String, extra: [String] = [], contentType: String? = nil, body: String = "") {
            var msg = "SIP/2.0 \(status)\r\n"
            for line in request.headers {
                let name = line.prefix { $0 != ":" }.trimmingCharacters(in: .whitespaces).lowercased()
                if ["via", "v", "from", "f", "call-id", "i", "cseq"].contains(name) { msg += line + "\r\n" }
            }
            msg += "To: \(to)\r\n"
            for h in extra { msg += h + "\r\n" }
            if let contentType { msg += "Content-Type: \(contentType)\r\n" }
            msg += "Content-Length: \(body.utf8.count)\r\n\r\n" + body
            send(Array(msg.utf8), to: from)
        }

        switch method {
        case "MESSAGE":
            received.withLock { $0.append(request) }
            if let status = answer { reply(status) }
        case "INVITE":
            var target = "sip:127.0.0.1"
            if let contact = request.header("Contact"), let lt = contact.firstIndex(of: "<"),
               let gt = contact[lt...].firstIndex(of: ">") {
                target = String(contact[contact.index(after: lt)..<gt])
            }
            let d = Dialog(callID: request.header("Call-ID") ?? "", remote: request.header("From") ?? "",
                           local: to, target: target)
            dialog.withLock { $0 = d }
            let sdp = "v=0\r\no=stub 1 1 IN IP4 127.0.0.1\r\ns=stub\r\nc=IN IP4 127.0.0.1\r\nt=0 0\r\n"
                + "m=audio 4998 RTP/AVP 0\r\na=rtpmap:0 PCMU/8000\r\na=sendrecv\r\n"
            reply("200 OK", extra: ["Contact: <sip:stub@127.0.0.1:\(port)>"], contentType: "application/sdp", body: sdp)
        default:
            reply("200 OK")
        }
    }

    /// Sends a MESSAGE to the engine on 127.0.0.1:`port` the way Asterisk relays an SMS from
    /// chan_dongle: `From: "<displayName>" <sip:<fromNumber>@127.0.0.1:<stub port>>`, To and
    /// Request-URI `sip:<user>@127.0.0.1:<port>`, the given Content-Type (nil: none) and body.
    /// Returns the Call-ID (answers: `responses(to:)`).
    @discardableResult
    func sendMessage(toPort port: Int, user: String, fromNumber: String, displayName: String?,
                     contentType: String?, body: [UInt8]) -> String {
        let callID = "msg-\(UInt32.random(in: 1...UInt32.max))@127.0.0.1"
        let name = displayName.map { "\"\($0)\" " } ?? ""
        var head = "MESSAGE sip:\(user)@127.0.0.1:\(port) SIP/2.0\r\n"
        head += "Via: SIP/2.0/UDP 127.0.0.1:\(self.port);branch=z9hG4bK-msg-\(UInt32.random(in: 1...UInt32.max));rport\r\n"
        head += "Max-Forwards: 70\r\n"
        head += "From: \(name)<sip:\(fromNumber)@127.0.0.1:\(self.port)>;tag=msg-from-\(UInt32.random(in: 1...UInt32.max))\r\n"
        head += "To: <sip:\(user)@127.0.0.1:\(port)>\r\n"
        head += "Call-ID: \(callID)\r\nCSeq: 1 MESSAGE\r\n"
        if let contentType { head += "Content-Type: \(contentType)\r\n" }
        head += "Content-Length: \(body.count)\r\n\r\n"
        send(Array(head.utf8) + body, toPort: port)
        return callID
    }

    /// Sends a MESSAGE inside the call the engine set up with the stub (after its INVITE).
    /// Returns the Call-ID, nil when there is no call.
    @discardableResult
    func sendInDialogMessage(toPort port: Int, contentType: String, body: [UInt8]) -> String? {
        guard let d = dialog.withLock({ d -> Dialog? in
            d?.cseq += 1
            return d
        }) else { return nil }
        var head = "MESSAGE \(d.target) SIP/2.0\r\n"
        head += "Via: SIP/2.0/UDP 127.0.0.1:\(self.port);branch=z9hG4bK-msg-\(UInt32.random(in: 1...UInt32.max));rport\r\n"
        head += "Max-Forwards: 70\r\nFrom: \(d.local)\r\nTo: \(d.remote)\r\n"
        head += "Call-ID: \(d.callID)\r\nCSeq: \(d.cseq) MESSAGE\r\n"
        head += "Content-Type: \(contentType)\r\nContent-Length: \(body.count)\r\n\r\n"
        send(Array(head.utf8) + body, toPort: port)
        return d.callID
    }

    private func send(_ bytes: [UInt8], toPort port: Int) {
        var dest = sockaddr_in()
        dest.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        dest.sin_family = sa_family_t(AF_INET)
        dest.sin_addr.s_addr = inet_addr("127.0.0.1")
        dest.sin_port = in_port_t(UInt16(port).bigEndian)
        send(bytes, to: dest)
    }

    private func send(_ bytes: [UInt8], to dest: sockaddr_in) {
        var dest = dest
        _ = withUnsafePointer(to: &dest) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(fd, bytes, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
    }
}

extension EventLog {
    func messageStatuses(_ id: MessageID) -> [MessageSendResult] {
        all.compactMap { if case let .messageStatus(i, r) = $0, i == id { return r }; return nil }
    }

    var receivedMessages: [IncomingMessage] {
        all.compactMap { if case let .messageReceived(m) = $0 { return m }; return nil }
    }
}

/// The SMS text of the chan_dongle fixture.
private let cyrillicText = "Привет, это тест из chan_dongle"

/// An enabled account on 127.0.0.1 that does not register (messages and calls only).
private func localAccount(_ user: String) -> AccountConfig {
    AccountConfig(displayName: "Acc \(user)", username: user, domain: "127.0.0.1", registerWithServer: false, mwi: false)
}

// MARK: - tests that run pjsua (part of the serialized "Engine (pjsua)" suite)

extension EngineTests {
    /// A MESSAGE goes out as text/plain;charset=utf-8 with the exact UTF-8 bytes to the dialled
    /// URI, and the stub's 200 becomes `.accepted(200)` once. The `id:` form reports the
    /// caller's id. A text of `Engine.maxMessageBytes` fits into one request.
    @Test func messageSentAndAccepted() async throws {
        let stub = try MessageStub()
        defer { stub.stop() }
        let engine = await makeEngine()
        let log = EventLog()
        let consumer = log.consume(engine)
        defer { consumer.cancel() }
        try await engine.start(network: Self.network)
        let account = localAccount("101")
        try await engine.addAccount(account, password: "")
        let target = "sip:102@127.0.0.1:\(stub.port)"
        let dial = try #require(DialString.parse(target, account: account))

        let id = try await engine.sendMessage(cyrillicText, to: dial, from: account.id)
        #expect(await waitUntil(timeout: 5) { !log.messageStatuses(id).isEmpty })
        #expect(log.messageStatuses(id) == [.accepted(code: 200)])
        let request = try #require(stub.messages.first)
        #expect(request.size - request.body.count < 600, "headers: \(request.size - request.body.count) bytes")
        #expect(request.requestLine == "MESSAGE \(target) SIP/2.0")
        // PJSIP prints To/From URIs without the port (RFC 3261 Table 1).
        #expect(request.header("To") == "<sip:102@127.0.0.1>", "To: \(request.header("To") ?? "-")")
        #expect(request.header("Content-Type")?.lowercased().replacingOccurrences(of: " ", with: "")
                == "text/plain;charset=utf-8", "Content-Type: \(request.header("Content-Type") ?? "-")")
        #expect(request.body == Array(cyrillicText.utf8))
        #expect(request.header("From")?.contains("sip:101@127.0.0.1") == true)

        let chosen = MessageID()
        #expect(try await engine.sendMessage("second", to: dial, from: account.id, id: chosen) == chosen)
        #expect(await waitUntil(timeout: 5) { log.messageStatuses(chosen) == [.accepted(code: 200)] })

        // The longest text allowed still fits into one request with all its headers.
        let longest = String(repeating: "Ж", count: Engine.maxMessageBytes / 2)
        let big = try await engine.sendMessage(longest, to: dial, from: account.id)
        #expect(await waitUntil(timeout: 5) { !log.messageStatuses(big).isEmpty })
        #expect(log.messageStatuses(big) == [.accepted(code: 200)])
        #expect(stub.messages.last?.body == Array(longest.utf8))
        let size = stub.messages.last?.size ?? 0
        #expect(size <= 4000, "request of \(size) bytes")

        try await Task.sleep(for: .milliseconds(300))
        #expect(log.messageStatuses(id).count == 1)
        await engine.stop()
    }

    /// A final non-2xx answer is `.failed` with its code and reason phrase; no answer at all is
    /// 408 after the transaction timeout (shortened to 2 s); a request that cannot be sent is
    /// `.failed(code: 0, ...)` with the transport error. Each id gets exactly one status.
    @Test func messageFailuresCarryCodeAndReason() async throws {
        let stub = try MessageStub()
        defer { stub.stop() }
        let engine = await makeEngine()
        await engine.setTestTimings(transactionTimeoutMs: 2000)
        let log = EventLog()
        let consumer = log.consume(engine)
        defer { consumer.cancel() }
        try await engine.start(network: Self.network)
        let account = localAccount("101")
        try await engine.addAccount(account, password: "")
        let dial = DialString(uri: "sip:102@127.0.0.1:\(stub.port)", display: "102")

        var ids: [MessageID] = []
        for (answer, expected) in [("404 Not Found", MessageSendResult.failed(code: 404, reason: "Not Found")),
                                   ("480 Temporarily Unavailable", .failed(code: 480, reason: "Temporarily Unavailable"))] {
            stub.answer = answer
            let id = try await engine.sendMessage("hello", to: dial, from: account.id)
            ids.append(id)
            #expect(await waitUntil(timeout: 5) { !log.messageStatuses(id).isEmpty })
            #expect(log.messageStatuses(id) == [expected])
        }

        stub.answer = nil
        let silent = try await engine.sendMessage("anyone there?", to: dial, from: account.id)
        ids.append(silent)
        #expect(await waitUntil(timeout: 8) { !log.messageStatuses(silent).isEmpty })
        #expect(log.messageStatuses(silent) == [.failed(code: 408, reason: "Request Timeout")])
        #expect(stub.messages.filter { $0.body == Array("anyone there?".utf8) }.count >= 2)   // retransmitted

        // sendto to the broadcast address fails at once (as without a network). pjsua reports
        // it through on_pager_status2 inside pjsua_im_send, then returns the error: one status,
        // no throw.
        let local = MessageID()
        let returned = try await engine.sendMessage("x", to: DialString(uri: "sip:102@255.255.255.255:5060", display: "102"),
                                                    from: account.id, id: local)
        #expect(returned == local)
        ids.append(local)
        #expect(await waitUntil(timeout: 5) { !log.messageStatuses(local).isEmpty })
        let result = try #require(log.messageStatuses(local).first)
        if case let .failed(code, reason) = result {
            #expect(code == 0)
            #expect(!reason.isEmpty)
        } else {
            Issue.record("local failure reported as \(result)")
        }

        try await Task.sleep(for: .milliseconds(500))
        for id in ids { #expect(log.messageStatuses(id).count == 1, "\(id): \(log.messageStatuses(id))") }
        await engine.stop()
    }

    /// A MESSAGE whose answer has not come when the engine stops fails with
    /// `Engine.messageInterruptedReason`, once.
    @Test func messagePendingAtStopIsInterrupted() async throws {
        let stub = try MessageStub()
        defer { stub.stop() }
        stub.answer = nil
        let engine = await makeEngine()
        let log = EventLog()
        let consumer = log.consume(engine)
        defer { consumer.cancel() }
        try await engine.start(network: Self.network)
        let account = localAccount("101")
        try await engine.addAccount(account, password: "")
        let id = try await engine.sendMessage("late", to: DialString(uri: "sip:102@127.0.0.1:\(stub.port)", display: "102"),
                                              from: account.id)
        #expect(await waitUntil { !stub.messages.isEmpty })
        await engine.stop()
        #expect(await waitUntil { !log.messageStatuses(id).isEmpty })
        try await Task.sleep(for: .milliseconds(200))
        #expect(log.messageStatuses(id) == [.failed(code: 0, reason: Engine.messageInterruptedReason)])
    }

    /// What `sendMessage` refuses before anything is sent.
    @Test func sendMessageValidation() async throws {
        let engine = await makeEngine()
        let account = localAccount("101")
        let dial = DialString(uri: "sip:102@127.0.0.1:5999", display: "102")
        await #expect(throws: EngineError.notStarted) {
            try await engine.sendMessage("hi", to: dial, from: account.id)
        }
        try await engine.start(network: Self.network)
        await #expect(throws: EngineError.unknownAccount(account.id)) {
            try await engine.sendMessage("hi", to: dial, from: account.id)
        }
        try await engine.addAccount(account, password: "")
        for (text, uri) in [("", dial.uri),
                            (String(repeating: "a", count: Engine.maxMessageBytes + 1), dial.uri),
                            (String(repeating: "Ж", count: Engine.maxMessageBytes / 2 + 1), dial.uri),
                            ("hi", "tel:+375291234567"),
                            ("hi", "sip:")] {
            do {
                _ = try await engine.sendMessage(text, to: DialString(uri: uri, display: ""), from: account.id)
                Issue.record("sent \(text.utf8.count) bytes to \(uri)")
            } catch let error as EngineError {
                guard case .invalidArgument = error else { Issue.record("\(error)"); continue }
            }
        }
        await engine.stop()
    }

    /// An SMS relayed by Asterisk from chan_dongle: Cyrillic text/plain;charset=utf-8 from
    /// "+375291234567" arrives byte-exact as `.messageReceived` on the addressed account, and
    /// the engine answers 200. Without a charset and with invalid UTF-8 (lossy) too.
    @Test func incomingCyrillicMessageFromChanDongle() async throws {
        let stub = try MessageStub()
        defer { stub.stop() }
        let engine = await makeEngine()
        let log = EventLog()
        let consumer = log.consume(engine)
        defer { consumer.cancel() }
        try await engine.start(network: Self.network)
        let account = localAccount("102")
        try await engine.addAccount(account, password: "")
        let port = await engine.localPort(of: .udp)

        let before = Date()
        let callID = stub.sendMessage(toPort: port, user: "102", fromNumber: "+375291234567", displayName: "+375291234567",
                                      contentType: "text/plain;charset=utf-8", body: Array(cyrillicText.utf8))
        #expect(await waitUntil(timeout: 5) { !log.receivedMessages.isEmpty })
        #expect(await waitUntil(timeout: 5) { stub.responses(to: callID).contains("SIP/2.0 200 OK") })
        let message = try #require(log.receivedMessages.first)
        #expect(message.accountID == account.id)
        #expect(Array(message.text.utf8) == Array(cyrillicText.utf8))
        #expect(message.remote.number == "+375291234567")
        #expect(message.remote.displayName == "+375291234567")
        #expect(message.remote.uri == "sip:+375291234567@127.0.0.1")     // no port in From (RFC 3261 Table 1)
        #expect(message.receivedAt >= before.addingTimeInterval(-1) && message.receivedAt <= Date())

        stub.sendMessage(toPort: port, user: "102", fromNumber: "1001", displayName: nil,
                         contentType: "text/plain", body: Array("no charset".utf8))
        #expect(await waitUntil(timeout: 5) { log.receivedMessages.count == 2 })
        #expect(log.receivedMessages.last?.text == "no charset")
        #expect(log.receivedMessages.last?.remote.number == "1001")
        #expect(log.receivedMessages.last?.remote.displayName == nil)

        stub.sendMessage(toPort: port, user: "102", fromNumber: "1001", displayName: nil,
                         contentType: "text/plain; charset=UTF-8", body: [0x48, 0x69, 0xFF, 0x21])
        #expect(await waitUntil(timeout: 5) { log.receivedMessages.count == 3 })
        #expect(log.receivedMessages.last?.text == "Hi\u{FFFD}!")

        try await Task.sleep(for: .milliseconds(300))
        #expect(log.receivedMessages.count == 3)             // retransmissions absorbed
        await engine.stop()
    }

    /// Bodies other than text/plain are answered 415 (with Accept) and produce no event; a
    /// MESSAGE without a body gets 200 and no event either.
    @Test func incomingNonTextMessageIsRejectedWith415() async throws {
        let stub = try MessageStub()
        defer { stub.stop() }
        let engine = await makeEngine()
        let log = EventLog()
        let consumer = log.consume(engine)
        defer { consumer.cancel() }
        try await engine.start(network: Self.network)
        let account = localAccount("102")
        try await engine.addAccount(account, password: "")
        let port = await engine.localPort(of: .udp)

        for type in ["application/octet-stream", "text/html"] {
            let callID = stub.sendMessage(toPort: port, user: "102", fromNumber: "+375291234567", displayName: nil,
                                          contentType: type, body: [0x00, 0x01, 0xD0, 0x9F])
            #expect(await waitUntil(timeout: 5) { !stub.responses(to: callID).isEmpty }, "\(type)")
            #expect(stub.responses(to: callID).first == "SIP/2.0 415 Unsupported Media Type", "\(type)")
        }
        let empty = stub.sendMessage(toPort: port, user: "102", fromNumber: "+375291234567", displayName: nil,
                                     contentType: nil, body: [])
        #expect(await waitUntil(timeout: 5) { stub.responses(to: empty).contains("SIP/2.0 200 OK") })
        try await Task.sleep(for: .milliseconds(500))
        #expect(log.receivedMessages.isEmpty)
        await engine.stop()
    }

    /// Two accounts: each MESSAGE is reported for the account its Request-URI and To name.
    @Test func secondAccountReceivesItsOwnMessage() async throws {
        let stub = try MessageStub()
        defer { stub.stop() }
        let engine = await makeEngine()
        let log = EventLog()
        let consumer = log.consume(engine)
        defer { consumer.cancel() }
        try await engine.start(network: Self.network)
        let first = localAccount("102")
        let second = localAccount("103")
        try await engine.addAccount(first, password: "")
        try await engine.addAccount(second, password: "")
        let port = await engine.localPort(of: .udp)

        stub.sendMessage(toPort: port, user: "103", fromNumber: "200", displayName: "Two Hundred",
                         contentType: "text/plain;charset=utf-8", body: Array("for 103".utf8))
        #expect(await waitUntil(timeout: 5) { log.receivedMessages.count == 1 })
        stub.sendMessage(toPort: port, user: "102", fromNumber: "200", displayName: "Two Hundred",
                         contentType: "text/plain;charset=utf-8", body: Array("for 102".utf8))
        #expect(await waitUntil(timeout: 5) { log.receivedMessages.count == 2 })
        let byText = Dictionary(log.receivedMessages.map { ($0.text, $0.accountID) }, uniquingKeysWith: { a, _ in a })
        #expect(byText["for 103"] == second.id)
        #expect(byText["for 102"] == first.id)
        #expect(log.receivedMessages.first?.remote.displayName == "Two Hundred")
        await engine.stop()
    }

    /// A MESSAGE inside a call is reported like one outside (the call's account, the peer from
    /// the dialog); a non-text one inside the call gets 415 too.
    @Test func messageInsideACall() async throws {
        let stub = try MessageStub()
        defer { stub.stop() }
        let engine = await makeEngine()
        let log = EventLog()
        let consumer = log.consume(engine)
        defer { consumer.cancel() }
        try await engine.start(network: Self.network)
        let account = localAccount("101")
        try await engine.addAccount(account, password: "")
        let port = await engine.localPort(of: .udp)
        let call = try await engine.makeCall(to: DialString(uri: "sip:200@127.0.0.1:\(stub.port)", display: "200"),
                                             from: account.id)
        #expect(await waitUntil(timeout: 5) { await engine.calls().first { $0.id == call }?.state == .connected })
        #expect(stub.hasDialog)

        let callID = try #require(stub.sendInDialogMessage(toPort: port, contentType: "text/plain;charset=utf-8",
                                                           body: Array(cyrillicText.utf8)))
        #expect(await waitUntil(timeout: 5) { !log.receivedMessages.isEmpty })
        #expect(stub.responses(to: callID).contains("SIP/2.0 200 OK"))
        let message = try #require(log.receivedMessages.first)
        #expect(message.accountID == account.id)
        #expect(message.text == cyrillicText)
        #expect(message.remote.number == "200")

        let mark = stub.responses(to: callID).count
        stub.sendInDialogMessage(toPort: port, contentType: "application/octet-stream", body: [1, 2, 3])
        #expect(await waitUntil(timeout: 5) { stub.responses(to: callID).count > mark })
        #expect(stub.responses(to: callID).dropFirst(mark).first == "SIP/2.0 415 Unsupported Media Type")
        try await Task.sleep(for: .milliseconds(300))
        #expect(log.receivedMessages.count == 1)
        try await engine.hangup(call)
        #expect(await waitUntil { await engine.calls().isEmpty })
        await engine.stop()
    }
}

// MARK: - pure mappings

@Suite("Text message mappings")
struct MessageMappingTests {
    @Test func statusMapping() {
        #expect(MessageMapping.result(code: 200, reason: "OK", answered: true) == .accepted(code: 200))
        #expect(MessageMapping.result(code: 202, reason: "Accepted", answered: true) == .accepted(code: 202))
        #expect(MessageMapping.result(code: 404, reason: "Not Found", answered: true) == .failed(code: 404, reason: "Not Found"))
        #expect(MessageMapping.result(code: 486, reason: "", answered: true) == .failed(code: 486, reason: "Busy Here"))
        #expect(MessageMapping.result(code: 302, reason: "Moved Temporarily", answered: true)
                == .failed(code: 302, reason: "Moved Temporarily"))
        // a server's 503 is a SIP answer; pjsua's own 503/502 without a response is a local failure
        #expect(MessageMapping.result(code: 503, reason: "Service Unavailable", answered: true)
                == .failed(code: 503, reason: "Service Unavailable"))
        #expect(MessageMapping.result(code: 503, reason: "Connection refused", answered: false)
                == .failed(code: 0, reason: "Connection refused"))
        #expect(MessageMapping.result(code: 502, reason: "", answered: false) == .failed(code: 0, reason: "Bad Gateway"))
        #expect(MessageMapping.result(code: 408, reason: "Request Timeout", answered: false)
                == .failed(code: 408, reason: "Request Timeout"))
    }

    @Test func incomingMapping() {
        let account = AccountID()
        let at = Date()
        let m = MessageMapping.incoming(account: account, from: "\"Иван\" <sip:+375291234567@pbx.example.com>",
                                        mimeType: "TEXT/Plain", body: "Привет", at: at)
        #expect(m == IncomingMessage(accountID: account,
                                     remote: RemoteParty(displayName: "Иван", uri: "sip:+375291234567@pbx.example.com",
                                                         number: "+375291234567"),
                                     text: "Привет", receivedAt: at))
        #expect(MessageMapping.incoming(account: account, from: "<sip:102@pbx>", mimeType: "text/plain", body: "",
                                        at: at) == nil)
        #expect(MessageMapping.incoming(account: account, from: "<sip:102@pbx>", mimeType: "", body: "", at: at) == nil)
        #expect(MessageMapping.incoming(account: account, from: "<sip:102@pbx>", mimeType: "application/octet-stream",
                                        body: "x", at: at) == nil)
        #expect(MessageMapping.incoming(account: account, from: "<sip:102@pbx;transport=tcp>", mimeType: "text/plain",
                                        body: "x", at: at)?.remote.number == "102")
    }
}
