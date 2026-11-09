import Foundation
import os
import Testing
@testable import MacroSIPCore

// IPv6 dual stack (docs/ENGINE.md "IPv6", ADR 0014): the per-account IP protocol, the family
// decision, IPv6 transports and accounts bound to them, IPv6 media, incoming requests over IPv6.
// Everything runs on loopback ([::1] and 127.0.0.1); nothing leaves the Mac.

// MARK: - IPv6 SIP stub

/// A SIP stub on [::1]: one UDP socket and one TCP listener, and with `dualStack` a UDP socket on
/// 127.0.0.1 with the same port number, so an account at "localhost:<port>" reaches it over either
/// family. Answers REGISTER with 200 (Contacts listed; the status in `registerAnswers` for a family
/// that has one, e.g. "503 Service Unavailable"; an un-REGISTER `unregisterDelay` seconds late),
/// INVITE with 200 and an answer in the offer's family (`IN IP6 ::1` or `IN IP4 127.0.0.1`; only 180
/// with `ringOnly`), everything else with 200; requests that arrive on a family in `silentFamilies` are
/// recorded and left unanswered. Records every request with the family and transport it came over. Can send
/// INVITE and MESSAGE to the engine from its UDP sockets; their responses are recorded, a 2xx to
/// INVITE is ACKed and the call hung up with BYE.
final class IPv6Stub: Sendable {
    struct Request: Sendable {
        var method: String
        var family: IPFamily
        var transport: String           // "UDP" or "TCP"
        var via: String                 // top Via value
        var contact: String             // first Contact value
        var cseq: String
        var body: String
        /// REGISTER with Expires 0 (or every Contact with expires=0): an un-REGISTER.
        var unregister = false
        /// The Event header ("message-summary", "presence").
        var event = ""
        var at = Date()
    }

    struct Response: Sendable {
        var status: String              // "SIP/2.0 200 OK"
        var callID: String
        var body: String
    }

    let port: UInt16
    let tcpPort: UInt16
    let rtpPort: UInt16
    private let udp6: Int32
    private let udp4: Int32?
    private let tcp: Int32
    private let rtp6: Int32
    private let stopped = OSAllocatedUnfairLock(initialState: false)
    private let silent = OSAllocatedUnfairLock(initialState: Set<IPFamily>())
    private let answers4REGISTER = OSAllocatedUnfairLock(initialState: [IPFamily: String]())
    private let unregisterLag = OSAllocatedUnfairLock(initialState: TimeInterval(0))
    private let ringing = OSAllocatedUnfairLock(initialState: false)
    /// Headers of the INVITE left ringing (`ringOnly`), for the 487 after a CANCEL.
    private let ringingInvite = OSAllocatedUnfairLock<([String], String)?>(initialState: nil)
    private let received = OSAllocatedUnfairLock(initialState: [Request]())
    private let answers = OSAllocatedUnfairLock(initialState: [Response]())

    var requests: [Request] { received.withLock { $0 } }
    var responses: [Response] { answers.withLock { $0 } }
    /// REGISTER requests with a new CSeq (retransmissions left out), in order.
    var registers: [Request] {
        var seen: Set<String> = []
        return requests.filter { $0.method == "REGISTER" && seen.insert($0.cseq).inserted }
    }
    var silentFamilies: Set<IPFamily> {
        get { silent.withLock { $0 } }
        set { silent.withLock { $0 = newValue } }
    }
    /// REGISTER answers other than 200 per family ("503 Service Unavailable").
    var registerAnswers: [IPFamily: String] {
        get { answers4REGISTER.withLock { $0 } }
        set { answers4REGISTER.withLock { $0 = newValue } }
    }
    /// Seconds before an un-REGISTER is answered.
    var unregisterDelay: TimeInterval {
        get { unregisterLag.withLock { $0 } }
        set { unregisterLag.withLock { $0 = newValue } }
    }
    var ringOnly: Bool {
        get { ringing.withLock { $0 } }
        set { ringing.withLock { $0 = newValue } }
    }
    /// REGISTERs that add a binding (not un-REGISTERs), in order.
    var bindingRegisters: [Request] { registers.filter { !$0.unregister } }

    init(dualStack: Bool = false) throws {
        var attempt = 0
        while true {
            attempt += 1
            let (fd6, p) = try IPv6Stub.bindSocket(.ipv6, type: SOCK_DGRAM, port: 0)
            if dualStack {
                guard let (fd4, _) = try? IPv6Stub.bindSocket(.ipv4, type: SOCK_DGRAM, port: p) else {
                    close(fd6)
                    if attempt < 20 { continue }
                    throw EngineError.unsupported("no port free on both families")
                }
                udp4 = fd4
            } else {
                udp4 = nil
            }
            udp6 = fd6
            port = p
            break
        }
        (tcp, tcpPort) = try IPv6Stub.bindSocket(.ipv6, type: SOCK_STREAM, port: 0)
        guard listen(tcp, 8) == 0 else { throw EngineError.unsupported("listen") }
        (rtp6, rtpPort) = try IPv6Stub.bindSocket(.ipv6, type: SOCK_DGRAM, port: 0)
        let udp6 = udp6, udp4 = udp4
        Thread.detachNewThread { [self] in self.serveUDP(udp6, family: .ipv6) }
        if let udp4 { Thread.detachNewThread { [self] in self.serveUDP(udp4, family: .ipv4) } }
        Thread.detachNewThread { [self] in self.acceptTCP() }
    }

    func stop() { stopped.withLock { $0 = true } }
    private var isStopped: Bool { stopped.withLock { $0 } }

    // MARK: sockets

    static func address(_ family: IPFamily, port: UInt16) -> (sockaddr_storage, socklen_t) {
        var storage = sockaddr_storage()
        switch family {
        case .ipv6:
            withUnsafeMutablePointer(to: &storage) {
                $0.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { a in
                    a.pointee.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
                    a.pointee.sin6_family = sa_family_t(AF_INET6)
                    a.pointee.sin6_port = in_port_t(port.bigEndian)
                    a.pointee.sin6_addr = in6addr_loopback
                }
            }
            return (storage, socklen_t(MemoryLayout<sockaddr_in6>.size))
        case .ipv4:
            withUnsafeMutablePointer(to: &storage) {
                $0.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { a in
                    a.pointee.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                    a.pointee.sin_family = sa_family_t(AF_INET)
                    a.pointee.sin_port = in_port_t(port.bigEndian)
                    a.pointee.sin_addr.s_addr = inet_addr("127.0.0.1")
                }
            }
            return (storage, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }

    private static func bindSocket(_ family: IPFamily, type: Int32, port: UInt16) throws -> (Int32, UInt16) {
        let fd = socket(family == .ipv6 ? AF_INET6 : AF_INET, type, 0)
        guard fd >= 0 else { throw EngineError.unsupported("socket") }
        var one: Int32 = 1
        if family == .ipv6 { setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &one, socklen_t(MemoryLayout<Int32>.size)) }
        if type == SOCK_STREAM { setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size)) }
        var (addr, len) = address(family, port: port)
        let ok = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) == 0 && getsockname(fd, $0, &len) == 0 }
        }
        guard ok else { close(fd); throw EngineError.unsupported("bind") }
        let bound = withUnsafePointer(to: &addr) { p -> UInt16 in
            family == .ipv6
                ? p.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { UInt16(bigEndian: $0.pointee.sin6_port) }
                : p.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt16(bigEndian: $0.pointee.sin_port) }
        }
        var tv = timeval(tv_sec: 0, tv_usec: 100_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        return (fd, bound)
    }

    private static func sendUDP(_ fd: Int32, _ text: String, to dest: sockaddr_storage, _ len: socklen_t) {
        var dest = dest
        let bytes = Array(text.utf8)
        _ = withUnsafePointer(to: &dest) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, bytes, bytes.count, 0, $0, len) }
        }
    }

    private func serveUDP(_ fd: Int32, family: IPFamily) {
        var buf = [UInt8](repeating: 0, count: 65_536)
        while !isStopped {
            var from = sockaddr_storage()
            var fromLen = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let n = withUnsafeMutablePointer(to: &from) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buf, buf.count, 0, $0, &fromLen) }
            }
            guard n > 0 else { continue }
            let peer = from, peerLen = fromLen
            handle(String(decoding: buf[0..<n], as: UTF8.self), family: family, transport: "UDP") { reply in
                IPv6Stub.sendUDP(fd, reply, to: peer, peerLen)
            }
        }
        close(fd)
        if family == .ipv6 { close(rtp6) }
    }

    private func acceptTCP() {
        while !isStopped {
            var pfd = pollfd(fd: tcp, events: Int16(POLLIN), revents: 0)
            guard poll(&pfd, 1, 100) > 0 else { continue }
            let conn = accept(tcp, nil, nil)
            guard conn >= 0 else { continue }
            Thread.detachNewThread { [self] in self.serveTCP(conn) }
        }
        close(tcp)
    }

    private func serveTCP(_ fd: Int32) {
        var pending: [UInt8] = []
        var buf = [UInt8](repeating: 0, count: 65_536)
        while !isStopped {
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&pfd, 1, 100) > 0 else { continue }
            let n = read(fd, &buf, buf.count)
            guard n > 0 else { break }
            pending += buf[0..<n]
            while let message = IPv6Stub.nextMessage(&pending) {
                handle(message, family: .ipv6, transport: "TCP") { reply in
                    let bytes = Array(reply.utf8)
                    _ = bytes.withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count) }
                }
            }
        }
        close(fd)
    }

    /// One complete message (headers and Content-Length bytes of body) from a TCP stream.
    private static func nextMessage(_ data: inout [UInt8]) -> String? {
        while data.first == 13 || data.first == 10 { data.removeFirst() }     // keep-alive CRLFs
        let separator: [UInt8] = [13, 10, 13, 10]
        guard data.count >= 4, let end = (0...(data.count - 4)).first(where: { Array(data[$0..<($0 + 4)]) == separator })
        else { return nil }
        let head = String(decoding: data[0..<end], as: UTF8.self)
        var length = 0
        for line in head.components(separatedBy: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let name = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
            if name == "content-length" || name == "l" { length = Int(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0 }
        }
        let total = end + 4 + length
        guard data.count >= total else { return nil }
        let message = String(decoding: data[0..<total], as: UTF8.self)
        data.removeFirst(total)
        return message
    }

    // MARK: SIP

    private func handle(_ text: String, family: IPFamily, transport: String, reply send: @escaping (String) -> Void) {
        let parts = text.components(separatedBy: "\r\n\r\n")
        let head = parts.first ?? text
        let body = parts.dropFirst().joined(separator: "\r\n\r\n")
        let lines = head.components(separatedBy: "\r\n")
        guard let first = lines.first else { return }
        var echoed: [String] = [], toLine = "", cseq = "", topVia = "", contacts: [String] = [], callID = ""
        var fromLine = "", expiresZero = false, expiresHeaderZero = false, event = ""
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            switch name {
            case "via", "v":
                echoed.append(line)
                if topVia.isEmpty { topVia = value }
            case "from", "f": echoed.append(line); fromLine = line
            case "call-id", "i": echoed.append(line); callID = value
            case "cseq": echoed.append(line); cseq = value
            case "to", "t": toLine = line
            case "contact", "m": contacts.append(value)
            case "expires": if value == "0" { expiresZero = true; expiresHeaderZero = true }
            case "event", "o": event = value
            default: break
            }
        }
        if first.hasPrefix("SIP/2.0") {
            handleResponse(first, body: body, via: topVia, from: fromLine, to: toLine, callID: callID, cseq: cseq,
                           contact: contacts.first ?? "", send: send)
            return
        }
        let method = String(first.prefix { $0 != " " })
        let unregister = method == "REGISTER" && !contacts.isEmpty && contacts.allSatisfy { c in
            let lower = c.lowercased()
            return lower.contains("expires=0") || (!lower.contains("expires=") && expiresHeaderZero)
        }
        let request = Request(method: method, family: family, transport: transport, via: topVia,
                              contact: contacts.first ?? "", cseq: cseq, body: body,
                              unregister: unregister || (method == "REGISTER" && contacts.isEmpty && expiresHeaderZero),
                              event: event)
        received.withLock { $0.append(request) }
        guard method != "ACK", !silentFamilies.contains(family) else { return }
        let inDialog = toLine.lowercased().contains("tag=")
        if !inDialog { toLine += ";tag=v6-stub-\(UInt32.random(in: 1...UInt32.max))" }
        func reply(_ status: String, extra: [String] = [], body: String = "", echo: [String]? = nil, to: String? = nil) {
            var msg = "SIP/2.0 \(status)\r\n" + (echo ?? echoed).joined(separator: "\r\n") + "\r\n" + (to ?? toLine) + "\r\n"
            for h in extra { msg += h + "\r\n" }
            if !body.isEmpty { msg += "Content-Type: application/sdp\r\n" }
            msg += "Content-Length: \(body.utf8.count)\r\n\r\n" + body
            send(msg)
        }
        switch method {
        case "REGISTER":
            if let status = registerAnswers[family], !unregister { reply(status); return }
            let listed = expiresZero ? [] : contacts.map { "Contact: \($0);expires=299" }
            let delay = unregister ? unregisterDelay : 0
            if delay > 0 {
                DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
                    reply("200 OK", extra: listed + ["Expires: \(expiresZero ? 0 : 300)"])
                }
            } else {
                reply("200 OK", extra: listed + ["Expires: \(expiresZero ? 0 : 300)"])
            }
        case "INVITE":
            if ringOnly && !inDialog {
                reply("100 Trying")
                reply("180 Ringing")
                let pending = (echoed, toLine)
                ringingInvite.withLock { $0 = pending }
                return
            }
            let conn = sdpConnection(body).hasPrefix("IN IP4") ? "IN IP4 127.0.0.1" : "IN IP6 ::1"
            let sdp = "v=0\r\no=stub 1 \(Int.random(in: 2...1_000_000)) \(conn)\r\ns=stub\r\nc=\(conn)\r\nt=0 0\r\n"
                + "m=audio \(rtpPort) RTP/AVP 0\r\na=rtpmap:0 PCMU/8000\r\na=sendrecv\r\n"
            let host = family == .ipv6 ? "[::1]" : "127.0.0.1"
            reply("200 OK", extra: ["Contact: <sip:stub@\(host):\(port)\(transport == "TCP" ? ";transport=tcp" : "")>"], body: sdp)
        case "CANCEL":
            reply("200 OK")
            if let (echo, to) = ringingInvite.withLock({ $0 }) {
                ringingInvite.withLock { $0 = nil }
                reply("487 Request Terminated", echo: echo.map { $0.replacingOccurrences(of: "CANCEL", with: "INVITE") }, to: to)
            }
        default:
            reply("200 OK")
        }
    }

    private func handleResponse(_ status: String, body: String, via: String, from: String, to: String, callID: String,
                                cseq: String, contact: String, send: (String) -> Void) {
        answers.withLock { $0.append(Response(status: status, callID: callID, body: body)) }
        let code = Int(status.split(separator: " ").dropFirst().first ?? "") ?? 0
        guard code >= 200, cseq.uppercased().hasSuffix("INVITE") else { return }
        let number = cseq.split(separator: " ").first.map(String.init) ?? "1"
        let callHeader = "Call-ID: \(callID)"
        if code >= 300 {
            send("ACK sip:engine SIP/2.0\r\nVia: \(via)\r\nMax-Forwards: 70\r\n\(from)\r\n\(to)\r\n\(callHeader)\r\n"
                 + "CSeq: \(number) ACK\r\nContent-Length: 0\r\n\r\n")
            return
        }
        var target = "sip:engine"
        if let lt = contact.firstIndex(of: "<"), let gt = contact.firstIndex(of: ">") {
            target = String(contact[contact.index(after: lt)..<gt])
        }
        let viaHost = via.split(separator: " ").dropFirst().first.map { String($0.prefix { $0 != ";" }) } ?? "[::1]"
        for (method, n) in [("ACK", number), ("BYE", String((Int(number) ?? 1) + 1))] {
            let branch = "z9hG4bK-v6-\(UInt32.random(in: 1...UInt32.max))"
            send("\(method) \(target) SIP/2.0\r\nVia: SIP/2.0/UDP \(viaHost);branch=\(branch);rport\r\nMax-Forwards: 70\r\n"
                 + "\(from)\r\n\(to)\r\n\(callHeader)\r\nCSeq: \(n) \(method)\r\nContent-Length: 0\r\n\r\n")
        }
    }

    /// Sends a request from the stub's UDP socket of `family` to the engine on loopback `port`.
    /// Returns its Call-ID.
    @discardableResult
    private func sendRequest(_ method: String, toPort port: Int, user: String, family: IPFamily,
                             contentType: String, body: String) -> String {
        let host = family == .ipv6 ? "[::1]" : "127.0.0.1"
        let callID = "v6-stub-\(UInt32.random(in: 1...UInt32.max))@stub"
        var msg = "\(method) sip:\(user)@\(host):\(port) SIP/2.0\r\n"
        msg += "Via: SIP/2.0/UDP \(host):\(self.port);branch=z9hG4bK-v6-\(UInt32.random(in: 1...UInt32.max));rport\r\n"
        msg += "Max-Forwards: 70\r\n"
        msg += "From: <sip:200@\(host)>;tag=v6-from-\(UInt32.random(in: 1...UInt32.max))\r\n"
        msg += "To: <sip:\(user)@\(host)>\r\n"
        msg += "Call-ID: \(callID)\r\nCSeq: 1 \(method)\r\n"
        if method == "INVITE" { msg += "Contact: <sip:200@\(host):\(self.port)>\r\n" }
        msg += "Content-Type: \(contentType)\r\nContent-Length: \(body.utf8.count)\r\n\r\n" + body
        let (dest, len) = IPv6Stub.address(family, port: UInt16(port))
        IPv6Stub.sendUDP(family == .ipv6 ? udp6 : (udp4 ?? udp6), msg, to: dest, len)
        return callID
    }

    /// An INVITE whose offer has `c=IN IP6 ::1` (or `IN IP4 127.0.0.1` with `ipv4Offer`).
    @discardableResult
    func sendInvite(toPort port: Int, user: String, family: IPFamily = .ipv6, ipv4Offer: Bool = false) -> String {
        let conn = ipv4Offer ? "IN IP4 127.0.0.1" : "IN IP6 ::1"
        let sdp = "v=0\r\no=stub 1 1 \(conn)\r\ns=stub\r\nc=\(conn)\r\nt=0 0\r\n"
            + "m=audio \(rtpPort) RTP/AVP 0\r\na=rtpmap:0 PCMU/8000\r\na=sendrecv\r\n"
        return sendRequest("INVITE", toPort: port, user: user, family: family, contentType: "application/sdp", body: sdp)
    }

    @discardableResult
    func sendMessage(toPort port: Int, user: String, text: String, family: IPFamily = .ipv6) -> String {
        sendRequest("MESSAGE", toPort: port, user: user, family: family, contentType: "text/plain", body: text)
    }

    func responses(to callID: String) -> [Response] { responses.filter { $0.callID == callID } }
}

/// The `c=` value of an SDP body ("IN IP6 ::1"), "" when there is none.
func sdpConnection(_ body: String) -> String {
    body.components(separatedBy: "\r\n").first { $0.hasPrefix("c=") }.map { String($0.dropFirst(2)) } ?? ""
}

/// What getaddrinfo (AF_UNSPEC, as pj_getaddrinfo asks) returns first for `host`.
func systemFirstFamily(_ host: String) -> IPFamily? {
    var hints = addrinfo()
    hints.ai_family = AF_UNSPEC
    var result: UnsafeMutablePointer<addrinfo>?
    guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else { return nil }
    defer { freeaddrinfo(result) }
    switch first.pointee.ai_family {
    case AF_INET6: return .ipv6
    case AF_INET: return .ipv4
    default: return nil
    }
}

// MARK: - values (no pjsua)

@Suite("IPv6 values")
struct IPv6ValueTests {
    @Test func ipProtocolDecodesOldJSONAsAuto() throws {
        let cfg = AccountConfig(displayName: "A", username: "1", domain: "d", ipProtocol: .ipv6)
        let data = try JSONEncoder().encode(cfg)
        #expect(String(decoding: data, as: UTF8.self).contains("\"ipProtocol\":\"ipv6\""))
        #expect(try JSONDecoder().decode(AccountConfig.self, from: data) == cfg)
        var dict = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        dict["ipProtocol"] = nil
        let old = try JSONDecoder().decode(AccountConfig.self, from: JSONSerialization.data(withJSONObject: dict))
        #expect(old.ipProtocol == .auto)
        dict["ipProtocol"] = "ipv5"
        let future = try JSONDecoder().decode(AccountConfig.self, from: JSONSerialization.data(withJSONObject: dict))
        #expect(future.ipProtocol == .auto && future.username == "1")
        #expect(AccountConfig(displayName: "N", username: "1", domain: "d").ipProtocol == .auto)
    }

    @Test func literalFamilies() {
        for h in ["192.0.2.1", "127.0.0.1", "10.0.0.1"] { #expect(IPFamilyPolicy.literalFamily(h) == .ipv4, "\(h)") }
        for h in ["::1", "[::1]", "2001:db8::1", "[2001:db8::1]", "[::ffff:10.1.2.3]", "fe80::1%en0"] {
            #expect(IPFamilyPolicy.literalFamily(h) == .ipv6, "\(h)")
        }
        for h in ["localhost", "pbx.example.com", "", "10.0.0", "[pbx]"] { #expect(IPFamilyPolicy.literalFamily(h) == nil, "\(h)") }
    }

    /// The first hop is the outbound proxy when one is set, otherwise the registrar (or the domain).
    @Test func firstHop() {
        func hop(_ a: AccountConfig) -> String {
            let h = IPFamilyPolicy.firstHop(of: a)
            return "\(h.host)" + (h.port.map { ":\($0)" } ?? "")
        }
        #expect(hop(AccountConfig(displayName: "", username: "1", domain: "pbx.example.com")) == "pbx.example.com")
        #expect(hop(AccountConfig(displayName: "", username: "1", domain: "d", registrar: "[2001:db8::5]:5070")) == "2001:db8::5:5070")
        #expect(hop(AccountConfig(displayName: "", username: "1", domain: "[::1]", transport: .tls)) == "::1")
        #expect(hop(AccountConfig(displayName: "", username: "1", domain: "[::1]",
                                  outboundProxy: "sip:proxy.example.com:5080;lr")) == "proxy.example.com:5080")
        #expect(hop(AccountConfig(displayName: "", username: "1", domain: "d",
                                  outboundProxy: "<sips:edge@192.0.2.7;transport=tls>")) == "192.0.2.7")
    }

    /// IPv4 only with an IPv6 literal (and the other way round) contradicts itself: the editor shows it,
    /// the engine refuses the account. Auto never conflicts.
    @Test func conflicts() {
        func a(_ server: String, _ p: IPProtocol, proxy: String? = nil) -> AccountConfig {
            AccountConfig(displayName: "", username: "1", domain: server, outboundProxy: proxy, ipProtocol: p)
        }
        #expect(IPFamilyPolicy.conflict(in: a("[2001:db8::1]", .ipv4)) == .ipv6)
        #expect(IPFamilyPolicy.conflict(in: a("192.0.2.1:5060", .ipv6)) == .ipv4)
        #expect(IPFamilyPolicy.conflict(in: a("[2001:db8::1]", .ipv6)) == nil)
        #expect(IPFamilyPolicy.conflict(in: a("[2001:db8::1]", .auto)) == nil)
        #expect(IPFamilyPolicy.conflict(in: a("pbx.example.com", .ipv4)) == nil)
        // The proxy is the first hop: it decides.
        #expect(IPFamilyPolicy.conflict(in: a("[2001:db8::1]", .ipv4, proxy: "192.0.2.9")) == nil)
        #expect(IPFamilyPolicy.conflict(in: a("192.0.2.1", .ipv4, proxy: "[2001:db8::9]")) == .ipv6)
    }

    /// The decision with a fake resolver: literals pick their family, IPv4/IPv6 only pick theirs, Auto
    /// with a host name takes the first resolved family that has a transport, IPv4 when nothing resolves,
    /// IPv4 without asking when DNS SRV is in effect and the host has no port, and no lookup at all when
    /// only one family has a transport.
    @Test func familyDecision() {
        let both: Set<IPFamily> = [.ipv4, .ipv6]
        let asked = OSAllocatedUnfairLock(initialState: [String]())
        func decide(_ a: AccountConfig, _ answer: [IPFamily], available: Set<IPFamily> = both, srv: Bool = false) -> IPFamily {
            IPFamilyPolicy.decide(a, available: available, srv: srv) { host in
                asked.withLock { $0.append(host) }
                return answer
            }
        }
        func a(_ server: String, _ p: IPProtocol = .auto, registrar: String? = nil, proxy: String? = nil) -> AccountConfig {
            AccountConfig(displayName: "", username: "1", domain: server, registrar: registrar, outboundProxy: proxy, ipProtocol: p)
        }
        #expect(decide(a("[2001:db8::1]"), [.ipv4]) == .ipv6)
        #expect(decide(a("192.0.2.1"), [.ipv6]) == .ipv4)
        #expect(asked.withLock { $0 }.isEmpty)
        #expect(decide(a("pbx.example.com", .ipv6), [.ipv4]) == .ipv6)
        #expect(decide(a("pbx.example.com", .ipv4), [.ipv6]) == .ipv4)
        #expect(asked.withLock { $0 }.isEmpty)

        #expect(decide(a("pbx.example.com"), [.ipv6, .ipv4]) == .ipv6)
        #expect(decide(a("pbx.example.com"), [.ipv4, .ipv6]) == .ipv4)
        #expect(decide(a("pbx.example.com"), [.ipv6]) == .ipv6)
        #expect(decide(a("pbx.example.com"), []) == .ipv4)                                     // offline: IPv4
        #expect(decide(a("pbx.example.com"), [.ipv6, .ipv4], available: [.ipv4, .ipv6]) == .ipv6)
        #expect(decide(a("d", registrar: "reg.example.com:5070"), [.ipv6]) == .ipv6)
        #expect(asked.withLock { $0 } == ["pbx.example.com", "pbx.example.com", "pbx.example.com", "pbx.example.com",
                                          "pbx.example.com", "reg.example.com"])

        asked.withLock { $0 = [] }
        // No IPv6 transport for this account: IPv4 without asking (and the other way round).
        #expect(decide(a("pbx.example.com"), [.ipv6, .ipv4], available: [.ipv4]) == .ipv4)
        #expect(decide(a("pbx.example.com"), [.ipv4, .ipv6], available: [.ipv6]) == .ipv6)
        // DNS SRV in effect, no port: getaddrinfo cannot follow SRV, so IPv4; with a port the host is asked.
        #expect(decide(a("pbx.example.com"), [.ipv6], srv: true) == .ipv4)
        #expect(asked.withLock { $0 }.isEmpty)
        #expect(decide(a("pbx.example.com:5060"), [.ipv6], srv: true) == .ipv6)
        #expect(asked.withLock { $0 } == ["pbx.example.com"])
        // The proxy is the first hop.
        #expect(decide(a("[2001:db8::1]", proxy: "sip:edge.example.com;lr"), [.ipv4]) == .ipv4)

        #expect(IPFamilyPolicy.followsResolver(a("pbx.example.com"), srv: false))
        #expect(!IPFamilyPolicy.followsResolver(a("pbx.example.com"), srv: true))
        #expect(IPFamilyPolicy.followsResolver(a("pbx.example.com:5060"), srv: true))
        #expect(!IPFamilyPolicy.followsResolver(a("pbx.example.com", .ipv6), srv: false))
        #expect(!IPFamilyPolicy.followsResolver(a("[::1]"), srv: false))
    }

    /// The system resolver lists the families getaddrinfo returns, in its order, without duplicates.
    @Test func systemResolverFollowsGetaddrinfo() {
        let families = IPFamilyResolver.system("localhost")
        #expect(families.first == systemFirstFamily("localhost"))
        #expect(Set(families).count == families.count)
        #expect(IPFamilyResolver.system("::1") == [.ipv6])
        #expect(IPFamilyResolver.system("127.0.0.1") == [.ipv4])
    }

    /// An IPv6 account is bound to the IPv6 twin of its transport, offers IPv6 media only and uses no
    /// STUN (SDP from the registrar's view); an IPv4 account keeps pjsua's media default and STUN. A bind
    /// address of the other family is not given to RTP.
    @Test func mappingByFamily() throws {
        let ids = TransportIDs(udp: 0, tcp: 1, tls: 2, tlsNoVerify: 3, udp6: 4, tcp6: 5, tls6: 6, tls6NoVerify: 7)
        func map(_ a: AccountConfig, _ family: IPFamily, bind: String? = nil) throws -> [PJAccountSettings] {
            let s = try AccountMapping.settings(for: a, password: "pw", network: .default, transports: ids,
                                                bindAddress: bind, family: family)
            return [s, AccountMapping.withPJConfig(s) { AccountMapping.readBack($0) }]
        }
        let host = AccountConfig(displayName: "", username: "1", domain: "pbx.example.com")
        for x in try map(host, .ipv6, bind: "::1") {
            #expect(x.transportID == 4 && x.mediaIPv6Only)
            #expect(!x.sipSTUN && !x.mediaSTUN && x.sdpNATRewrite)
            #expect(x.bindAddress == "::1")
        }
        for x in try map(host, .ipv4, bind: "::1") {
            #expect(x.transportID == 0 && !x.mediaIPv6Only && x.sipSTUN && x.mediaSTUN && !x.sdpNATRewrite)
            #expect(x.bindAddress == nil)                                   // the bind address is IPv6
        }
        #expect(try map(host, .ipv6, bind: "127.0.0.1").allSatisfy { $0.bindAddress == nil })
        var tcp = host; tcp.transport = .tcp
        #expect(try map(tcp, .ipv6).allSatisfy { $0.transportID == 5 })
        var tls = host; tls.transport = .tls
        #expect(try map(tls, .ipv6).allSatisfy { $0.transportID == 6 })
        tls.verifyTLSCertificate = false
        #expect(try map(tls, .ipv6).allSatisfy { $0.transportID == 7 })
        // A private IPv6 server is bound to UDP6, with or without a STUN server (no STUN either way).
        let priv = AccountConfig(displayName: "", username: "1", domain: "[fd00::5]")
        for network in [NetworkSettings.default, NetworkSettings(stunServer: nil)] {
            let s = try AccountMapping.settings(for: priv, password: "", network: network, transports: ids, family: .ipv6)
            #expect(s.transportID == 4 && !s.sipSTUN && !s.mediaSTUN)
        }
        // No IPv6 twin: the account cannot be added.
        #expect(throws: EngineError.transportUnavailable(.udp, ipv6: true)) {
            _ = try AccountMapping.settings(for: host, password: "", network: .default,
                                            transports: TransportIDs(udp: 0), family: .ipv6)
        }
        #expect(EngineError.transportUnavailable(.tcp, ipv6: true).description.contains("IPv6"))
    }

    @Test func transportIDsByFamily() {
        let ids = TransportIDs(udp: 0, tcp: 1, tls: 2, tlsNoVerify: 3, udp6: 4, tcp6: nil, tls6: 6, tls6NoVerify: 7)
        let a = AccountConfig(displayName: "", username: "1", domain: "d", transport: .tcp)
        #expect(ids.id(for: a, family: .ipv4) == 1 && ids.id(for: a, family: .ipv6) == nil)
        #expect(ids.families(for: a) == [.ipv4])
        #expect(ids.id(for: .udp, family: .ipv6) == 4 && ids.id(for: .tls, family: .ipv6) == 6)
        #expect(ids.families(for: AccountConfig(displayName: "", username: "1", domain: "d")) == [.ipv4, .ipv6])
    }

    /// The registrar-source trust compares IPv6 addresses in any spelling.
    @Test func registrarSourceComparesIPv6Forms() {
        let registrar = SignallingSource(address: "2001:db8::1", port: 5060, transport: .udp)
        #expect(SignallingSource(address: "[2001:DB8:0::1]", port: 5060, transport: .udp).isSamePeer(as: registrar))
        #expect(!SignallingSource(address: "2001:db8::2", port: 5060, transport: .udp).isSamePeer(as: registrar))
        #expect(SignallingSource.proxy("sip:[2001:db8::1]:5070;lr", transport: .udp)
                == SignallingSource(address: "2001:db8::1", port: 5070, transport: .udp))
        #expect(registrar.description == "[2001:db8::1]:5060/udp")
    }

    /// The primary route includes the IPv6 source address: a new temporary address is a change.
    @Test func networkPathComparesIPv6Address() {
        let a = NetworkPath(satisfied: true, interface: "en0", address: "192.0.2.10", address6: "2001:db8::10", gateway: "192.0.2.1")
        var b = a
        b.address6 = "2001:db8::11"
        #expect(b.primaryDiffers(from: a) && b.routeDiffers(from: a))
        #expect(!a.primaryDiffers(from: a))
        // Without accounts on IPv6 a new IPv6 address is no change.
        #expect(!b.primaryDiffers(from: a, ipv6: false) && !b.routeDiffers(from: a, ipv6: false))
        var c = b
        c.address = "192.0.2.11"
        #expect(c.primaryDiffers(from: a, ipv6: false))
        #expect(a.summary.contains("2001:db8::10"))
        #expect(NetworkPath.isUsableIPv6Source("2001:db8::10"))
        #expect(!NetworkPath.isUsableIPv6Source("fe80::1") && !NetworkPath.isUsableIPv6Source("::1")
                && !NetworkPath.isUsableIPv6Source("::"))
    }
}

// MARK: - pjsua tests (part of the serialized "Engine (pjsua)" suite)

extension EngineTests {
    /// An account at [::1] that does not register.
    func localIPv6Account(_ user: String) -> AccountConfig {
        AccountConfig(displayName: "V6 \(user)", username: user, domain: "[::1]", registerWithServer: false, mwi: false)
    }

    /// Bind address rules: an IPv6 bind address creates the IPv6 transports only (UDP6 required), an
    /// IPv4 one the IPv4 transports only, none both; an account of a family without transports is refused.
    @Test func bindAddressDecidesTransportFamilies() async throws {
        for bind in ["::1", "[::1]"] {
            let engine = await makeEngine(bindAddress: bind)
            try await engine.start(network: Self.network)
            let ids = await engine.transportIDsForTests()
            #expect(ids.udp == nil && ids.tcp == nil && ids.tls == nil && ids.tlsNoVerify == nil, "\(ids)")
            #expect(ids.udp6 != nil && ids.tcp6 != nil && ids.tls6 != nil && ids.tls6NoVerify != nil, "\(ids)")
            #expect(await engine.localPort(of: .udp) == 0)
            #expect(await engine.localPort(of: .udp, family: .ipv6) > 0)
            #expect(await engine.localPort(of: .tls, family: .ipv6) > 0)
            let v4 = AccountConfig(displayName: "4", username: "1", domain: "127.0.0.1", enabled: false)
            await #expect(throws: EngineError.transportUnavailable(.udp)) { try await engine.addAccount(v4, password: "") }
            try await engine.addAccount(localIPv6Account("6"), password: "")
            await engine.stop()
        }

        let v4only = await makeEngine(bindAddress: "127.0.0.1")
        try await v4only.start(network: Self.network)
        let ids = await v4only.transportIDsForTests()
        #expect(ids.udp != nil && ids.udp6 == nil && ids.tcp6 == nil && ids.tls6 == nil && ids.tls6NoVerify == nil, "\(ids)")
        await #expect(throws: EngineError.transportUnavailable(.udp, ipv6: true)) {
            try await v4only.addAccount(self.localIPv6Account("6"), password: "")
        }
        // A host name with no IPv6 transport takes IPv4 without a lookup.
        let named = AccountConfig(displayName: "N", username: "1", domain: "localhost", enabled: false)
        try await v4only.addAccount(named, password: "")
        #expect(await v4only.accountFamilyForTests(named.id) == .ipv4)
        await v4only.stop()

        let all = await makeEngine(bindAddress: nil)
        try await all.start(network: Self.network)
        let both = await all.transportIDsForTests()
        #expect(both.udp != nil && both.tcp != nil && both.tls != nil && both.tlsNoVerify != nil, "\(both)")
        #expect(both.udp6 != nil && both.tcp6 != nil && both.tls6 != nil && both.tls6NoVerify != nil, "\(both)")
        await all.stop()
    }

    /// Both families use the configured local port (pjlib sets IPV6_V6ONLY, so [::]:P and 0.0.0.0:P
    /// coexist). When the IPv6 UDP port is taken, the engine still starts: IPv4 works, IPv6 accounts of
    /// that transport are refused.
    @Test func ipv6TransportFailureIsNotFatal() async throws {
        // A free port P on both families, then [::]:P held by another socket.
        var blocker: Int32 = -1
        var port: UInt16 = 0
        for _ in 0..<20 {
            let fd = socket(AF_INET6, SOCK_DGRAM, 0)
            var one: Int32 = 1
            setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &one, socklen_t(MemoryLayout<Int32>.size))
            var addr = sockaddr_in6()
            addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            addr.sin6_family = sa_family_t(AF_INET6)
            addr.sin6_addr = in6addr_any
            var len = socklen_t(MemoryLayout<sockaddr_in6>.size)
            let bound = withUnsafeMutablePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) == 0 && getsockname(fd, $0, &len) == 0 }
            }
            let candidate = UInt16(bigEndian: addr.sin6_port)
            // The same port must be free for IPv4 UDP and for TCP on both families.
            let probes = [(AF_INET, SOCK_DGRAM), (AF_INET, SOCK_STREAM), (AF_INET6, SOCK_STREAM)].allSatisfy { af, type in
                let p = socket(af, type, 0)
                defer { close(p) }
                var storage = sockaddr_storage()
                let size: Int
                if af == AF_INET6 {
                    size = MemoryLayout<sockaddr_in6>.size
                    withUnsafeMutablePointer(to: &storage) { $0.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                        $0.pointee.sin6_len = UInt8(size); $0.pointee.sin6_family = sa_family_t(AF_INET6)
                        $0.pointee.sin6_port = in_port_t(candidate.bigEndian); $0.pointee.sin6_addr = in6addr_any
                    } }
                    setsockopt(p, IPPROTO_IPV6, IPV6_V6ONLY, &one, socklen_t(MemoryLayout<Int32>.size))
                } else {
                    size = MemoryLayout<sockaddr_in>.size
                    withUnsafeMutablePointer(to: &storage) { $0.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                        $0.pointee.sin_len = UInt8(size); $0.pointee.sin_family = sa_family_t(AF_INET)
                        $0.pointee.sin_port = in_port_t(candidate.bigEndian)
                    } }
                }
                return withUnsafePointer(to: &storage) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(p, $0, socklen_t(size)) == 0 } }
            }
            if bound && probes { blocker = fd; port = candidate; break }
            close(fd)
        }
        #expect(blocker >= 0)
        var net = Self.network
        net.localPort = port
        let engine = await makeEngine(bindAddress: nil)
        try await engine.start(network: net)
        var ids = await engine.transportIDsForTests()
        #expect(ids.udp != nil && ids.udp6 == nil && ids.tcp6 != nil, "\(ids)")
        #expect(await engine.localPort(of: .udp) == Int(port))
        #expect(await engine.localPort(of: .tcp, family: .ipv6) == Int(port))
        await #expect(throws: EngineError.transportUnavailable(.udp, ipv6: true)) {
            try await engine.addAccount(self.localIPv6Account("6"), password: "")
        }
        await engine.stop()

        close(blocker)
        try await engine.start(network: net)
        ids = await engine.transportIDsForTests()
        #expect(ids.udp != nil && ids.udp6 != nil, "\(ids)")
        #expect(await engine.localPort(of: .udp) == Int(port))
        #expect(await engine.localPort(of: .udp, family: .ipv6) == Int(port))
        await engine.stop()
    }

    /// IPv4 only with an IPv6 server address (and the other way round) is refused with
    /// `.invalidArgument`, not retried forever.
    @Test func contradictoryIPProtocolIsRefused() async throws {
        let engine = await makeEngine(bindAddress: nil)
        try await engine.start(network: Self.network)
        func isInvalidArgument(_ error: EngineError?) -> Bool {
            if case .invalidArgument? = error { return true }
            return false
        }
        let a = AccountConfig(displayName: "X", username: "1", domain: "[::1]", enabled: false, ipProtocol: .ipv4)
        let e1 = await #expect(throws: EngineError.self) { try await engine.addAccount(a, password: "") }
        #expect(isInvalidArgument(e1), "\(String(describing: e1))")
        var b = a
        b.domain = "127.0.0.1"
        b.ipProtocol = .ipv6
        let e2 = await #expect(throws: EngineError.self) { try await engine.addAccount(b, password: "") }
        #expect(isInvalidArgument(e2), "\(String(describing: e2))")
        b.ipProtocol = .auto
        try await engine.addAccount(b, password: "")
        b.domain = "[::1]"
        b.ipProtocol = .ipv4
        let e3 = await #expect(throws: EngineError.self) { try await engine.updateAccount(b, password: nil) }
        #expect(isInvalidArgument(e3), "\(String(describing: e3))")
        await engine.stop()
    }

    /// An account at [::1] registers over UDP6: Via and Contact carry [::1], the live pjsua_acc_config
    /// has the UDP6 transport, IPv6-only media, no STUN. A MESSAGE from it goes out over UDP6.
    @Test func ipv6AccountRegistersOverUDP6() async throws {
        let stub = try IPv6Stub()
        defer { stub.stop() }
        let engine = await makeEngine(bindAddress: "::1")
        let log = EventLog()
        let consumer = log.consume(engine)
        defer { consumer.cancel() }
        try await engine.start(network: Self.network)
        let port6 = await engine.localPort(of: .udp, family: .ipv6)
        let account = AccountConfig(displayName: "R6", username: "1006", domain: "[::1]",
                                    registrar: "[::1]:\(stub.port)", mwi: false)
        try await engine.addAccount(account, password: "pw")
        #expect(await waitUntil { await engine.registrationState(of: account.id).isRegistered })
        let register = try #require(stub.registers.first)
        #expect(register.family == .ipv6 && register.transport == "UDP")
        #expect(register.via.hasPrefix("SIP/2.0/UDP [::1]:\(port6)"), "\(register.via)")
        #expect(register.contact.contains("sip:1006@[::1]:\(port6)"), "\(register.contact)")

        let ids = await engine.transportIDsForTests()
        let live = try #require(await engine.liveAccountSettingsForTests(account.id))
        #expect(live.transportID == ids.udp6)
        #expect(live.mediaIPv6Only && !live.sipSTUN && !live.mediaSTUN)
        #expect(live.bindAddress == "::1")
        #expect(await engine.accountFamilyForTests(account.id) == .ipv6)

        let id = try await engine.sendMessage("hello over IPv6", to: DialString(uri: "sip:300@[::1]:\(stub.port)", display: "300"),
                                              from: account.id)
        #expect(await waitUntil { log.messageStatuses(id) == [.accepted(code: 200)] })
        let message = try #require(stub.requests.first { $0.method == "MESSAGE" })
        #expect(message.family == .ipv6 && message.body == "hello over IPv6")
        await engine.stop()
    }

    /// The same over TCP6: the stub's TCP listener on [::1] receives the REGISTER.
    @Test func ipv6AccountRegistersOverTCP6() async throws {
        let stub = try IPv6Stub()
        defer { stub.stop() }
        let engine = await makeEngine(bindAddress: "::1")
        try await engine.start(network: Self.network)
        let account = AccountConfig(displayName: "T6", username: "1007", domain: "[::1]",
                                    registrar: "[::1]:\(stub.tcpPort)", transport: .tcp, mwi: false)
        try await engine.addAccount(account, password: "pw")
        #expect(await waitUntil { await engine.registrationState(of: account.id).isRegistered })
        let register = try #require(stub.registers.first)
        #expect(register.family == .ipv6 && register.transport == "TCP")
        #expect(register.via.hasPrefix("SIP/2.0/TCP [::1]:"), "\(register.via)")
        #expect(register.contact.contains("@[::1]:") && register.contact.lowercased().contains("transport=tcp"),
                "\(register.contact)")
        let ids = await engine.transportIDsForTests()
        #expect(await engine.liveAccountSettingsForTests(account.id)?.transportID == ids.tcp6)
        await engine.stop()
    }

    /// An outgoing call of an IPv6 account offers `c=IN IP6` and its RTP socket is IPv6; a call to
    /// ourselves over [::1] reaches the account, is answered with IPv6 and carries RTP both ways.
    @Test func ipv6CallOffersIPv6MediaAndCarriesRTP() async throws {
        let stub = try IPv6Stub()
        defer { stub.stop() }
        let engine = await makeEngine(bindAddress: "::1")
        let log = EventLog()
        let consumer = log.consume(engine)
        defer { consumer.cancel() }
        try await engine.start(network: Self.network)
        let account = localIPv6Account("loop")
        try await engine.addAccount(account, password: "")
        let port6 = await engine.localPort(of: .udp, family: .ipv6)

        let call = try await engine.makeCall(to: DialString(uri: "sip:300@[::1]:\(stub.port)", display: "300"), from: account.id)
        #expect(await waitUntil { await engine.calls().first { $0.id == call }?.state == .connected })
        let invite = try #require(stub.requests.first { $0.method == "INVITE" })
        #expect(invite.family == .ipv6 && sdpConnection(invite.body) == "IN IP6 ::1", "\(invite.body)")
        #expect(await engine.localRTPAddress(of: call) == "::1")
        try await engine.hangup(call)
        #expect(await waitUntil { await engine.calls().isEmpty })

        let before = log.all.count
        let out = try await engine.makeCall(to: DialString(uri: "sip:loop@[::1]:\(port6)", display: "loop"), from: account.id)
        func incoming() -> CallInfo? {
            log.all.dropFirst(before).lazy.compactMap { if case let .incomingCall(c) = $0 { return c }; return nil }.first
        }
        #expect(await waitUntil { incoming() != nil })
        let inc = try #require(incoming())
        #expect(inc.accountID == account.id)
        try await engine.answer(inc.id)
        #expect(await waitUntil {
            let calls = await engine.calls()
            return calls.count == 2 && calls.allSatisfy { $0.state == .connected && $0.codec != nil }
        })
        #expect(await engine.localRTPAddress(of: out) == "::1")
        #expect(await engine.localRTPAddress(of: inc.id) == "::1")
        #expect(await waitUntil {
            let a = try? await engine.mediaStats(out), b = try? await engine.mediaStats(inc.id)
            return (a?.rxPackets ?? 0) > 10 && (a?.txPackets ?? 0) > 10 && (b?.rxPackets ?? 0) > 10
        })
        try await engine.hangup(out)
        #expect(await waitUntil { await engine.calls().isEmpty })
        await engine.stop()
    }

    /// Incoming requests over IPv6 reach the account bound to the IPv6 transport, those over IPv4 the
    /// IPv4 one (two accounts with the same user and domain). Every offer is answered in its own family:
    /// `IN IP6` to the IPv6 account with IPv6, `IN IP4` to the IPv6 account with IPv4, and `IN IP6` to
    /// the IPv4 account with IPv6 (pjsua's default for IPv4 accounts, as before). A MESSAGE over UDP6
    /// reaches the IPv6 account.
    @Test func incomingOverIPv6ReachesTheIPv6Account() async throws {
        let stub = try IPv6Stub(dualStack: true)
        defer { stub.stop() }
        let engine = await makeEngine(bindAddress: nil)
        let log = EventLog()
        let consumer = log.consume(engine)
        defer { consumer.cancel() }
        try await engine.start(network: Self.network)
        let a4 = AccountConfig(displayName: "A4", username: "100", domain: "pbx.test", registerWithServer: false,
                               mwi: false, ipProtocol: .ipv4)
        var a6 = a4
        a6.id = AccountID()
        a6.displayName = "A6"
        a6.ipProtocol = .ipv6
        try await engine.addAccount(a4, password: "")
        try await engine.addAccount(a6, password: "")
        let port4 = await engine.localPort(of: .udp)
        let port6 = await engine.localPort(of: .udp, family: .ipv6)
        func incoming(after count: Int) -> CallInfo? {
            log.all.dropFirst(count).lazy.compactMap { if case let .incomingCall(c) = $0 { return c }; return nil }.first
        }

        for (family, port, ipv4Offer, expected, answer) in [
            (IPFamily.ipv6, port6, false, a6.id, "IN IP6"), (.ipv4, port4, false, a4.id, "IN IP6"),
            (.ipv6, port6, true, a6.id, "IN IP4"),
        ] {
            let mark = log.all.count
            let callID = stub.sendInvite(toPort: port, user: "100", family: family, ipv4Offer: ipv4Offer)
            #expect(await waitUntil { incoming(after: mark) != nil })
            let call = try #require(incoming(after: mark))
            #expect(call.accountID == expected, "\(family) offer \(ipv4Offer ? "IP4" : "IP6")")
            try await engine.answer(call.id)
            #expect(await waitUntil { stub.responses(to: callID).contains { $0.status.hasPrefix("SIP/2.0 200") } })
            let ok = try #require(stub.responses(to: callID).first { $0.status.hasPrefix("SIP/2.0 200") })
            #expect(sdpConnection(ok.body).hasPrefix(answer), "answer \(ok.body)")
            #expect(await waitUntil { await engine.calls().isEmpty })
        }

        let messageID = stub.sendMessage(toPort: port6, user: "100", text: "over IPv6")
        #expect(await waitUntil { !log.receivedMessages.isEmpty })
        #expect(log.receivedMessages.first?.accountID == a6.id)
        #expect(log.receivedMessages.first?.text == "over IPv6")
        #expect(await waitUntil { stub.responses(to: messageID).contains { $0.status.hasPrefix("SIP/2.0 200") } })
        await engine.stop()
    }

    /// Auto with a host name follows the first address getaddrinfo returns ("localhost": usually ::1);
    /// IPv4 only and IPv6 only keep their family. The stub listens on both families with one port.
    @Test func autoFollowsSystemResolverForHostNames() async throws {
        let expected = try #require(systemFirstFamily("localhost"))
        for (choice, family) in [(IPProtocol.auto, expected), (.ipv4, .ipv4), (.ipv6, .ipv6)] {
            let stub = try IPv6Stub(dualStack: true)
            defer { stub.stop() }
            let engine = await makeEngine(bindAddress: nil)
            try await engine.start(network: Self.network)
            let account = AccountConfig(displayName: "L", username: "1008", domain: "localhost",
                                        registrar: "localhost:\(stub.port)", mwi: false, ipProtocol: choice)
            try await engine.addAccount(account, password: "pw")
            #expect(await waitUntil { await engine.registrationState(of: account.id).isRegistered }, "\(choice)")
            #expect(await engine.accountFamilyForTests(account.id) == family, "\(choice)")
            #expect(stub.registers.first?.family == family, "\(choice): \(stub.registers.map(\.family))")
            #expect(stub.registers.first?.via.contains("[") == (family == .ipv6), "\(stub.registers.first?.via ?? "")")
            await engine.stop()
        }
    }

    /// An Auto account whose host name resolves to both families, registered over UDP. (`answer`: what
    /// the injected resolver returns.)
    func startAutoLocalhost(_ stub: IPv6Stub, answer: OSAllocatedUnfairLock<[IPFamily]>, transport: TransportKind = .udp,
                            mwi: Bool = false, bind: String? = nil) async throws -> (Engine, AccountConfig, TimedEventLog, Task<Void, Never>) {
        let engine = await makeEngine(bindAddress: bind)
        let log = TimedEventLog()
        let consumer = log.consume(engine)
        await engine.setTestTimings(transactionTimeoutMs: 2000)
        await engine.setFamilyResolverForTests { _ in answer.withLock { $0 } }
        try await engine.start(network: Self.network)
        let port = transport == .tcp ? stub.tcpPort : stub.port
        // The domain carries the port, so MWI SUBSCRIBEs (to the account's own URI) reach the stub too.
        let account = AccountConfig(displayName: "L", username: "1009", domain: "localhost:\(port)",
                                    transport: transport, mwi: mwi)
        try await engine.addAccount(account, password: "pw")
        return (engine, account, log, consumer)
    }

    /// Registered, and bound to `family`.
    func registered(_ engine: Engine, _ id: AccountID, over family: IPFamily) async -> Bool {
        let bound = await engine.accountFamilyForTests(id)
        let state = await engine.registrationState(of: id)
        return bound == family && state.isRegistered
    }

    func logLines(_ log: TimedEventLog, containing text: String) -> [String] {
        log.all.compactMap { if case let .log(_, t) = $0.1, t.contains(text) { return t }; return nil }
    }

    /// A move as the registrar and the UI see it, after `since`: the old binding is un-REGISTERed over
    /// `from` and answered, only then the account REGISTERs over `to` (at least `lag` later: the
    /// un-REGISTER's answer is awaited), and the account shows `.registering` from the start of the move
    /// and `.registered` only after that REGISTER; no `.unregistered` in between.
    func expectMove(_ stub: IPv6Stub, _ log: TimedEventLog, _ id: AccountID, from: IPFamily, to: IPFamily,
                    since: Date, lag: TimeInterval = 0, unregisters: Bool = true,
                    sourceLocation: SourceLocation = #_sourceLocation) {
        let after = stub.registers.filter { $0.at >= since }
        let register = after.first { !$0.unregister && $0.family == to }
        #expect(register != nil, "no REGISTER over \(to): \(after.map { "\($0.family) \($0.unregister)" })",
                sourceLocation: sourceLocation)
        guard let register else { return }
        if unregisters {
            let unregister = after.last { $0.unregister && $0.family == from && $0.at <= register.at }
            #expect(unregister != nil, "no un-REGISTER over \(from) before it", sourceLocation: sourceLocation)
            if let unregister {
                #expect(register.at.timeIntervalSince(unregister.at) >= lag, "REGISTER \(register.at.timeIntervalSince(unregister.at)) s after the un-REGISTER",
                        sourceLocation: sourceLocation)
            }
        }
        let states = log.registrations(id).filter { $0.0 >= since }
        let moving = states.firstIndex { $0.1 == .registering }
        let done = states.lastIndex { if case .registered = $0.1 { return true }; return false }
        #expect(moving != nil && done != nil && moving! < done!, "states \(states.map(\.1))", sourceLocation: sourceLocation)
        if let moving, let done {
            #expect(states[done].0 >= register.at, "registered before the new REGISTER", sourceLocation: sourceLocation)
            let between = states[moving..<done].map(\.1)
            #expect(!between.contains(.unregistered), "states \(between)", sourceLocation: sourceLocation)
            #expect(!states[moving..<done].contains { if case .registered = $0.1 { return $0.0 < register.at }; return false },
                    "states \(between)", sourceLocation: sourceLocation)
        }
    }

    /// The family of an Auto host name is decided again on a network change; the move happens after the
    /// round, awaits the un-REGISTER of the old binding (answered late here) and then registers over the
    /// new family; `allow_sdp_nat_rewrite` follows the family (pjsua_acc_modify does not copy it).
    @Test func familyIsDecidedAgainOnNetworkChange() async throws {
        let stub = try IPv6Stub(dualStack: true)
        defer { stub.stop() }
        let answer = OSAllocatedUnfairLock(initialState: [IPFamily.ipv4, .ipv6])
        let (engine, account, log, consumer) = try await startAutoLocalhost(stub, answer: answer)
        defer { consumer.cancel() }
        let ids = await engine.transportIDsForTests()
        #expect(await waitUntil { await engine.registrationState(of: account.id).isRegistered })
        #expect(stub.bindingRegisters.last?.family == .ipv4)
        #expect(await engine.liveAccountSettingsForTests(account.id)?.sdpNATRewrite == false)

        answer.withLock { $0 = [.ipv6, .ipv4] }
        stub.unregisterDelay = 0.6
        let since = Date()
        await engine.simulateNetworkChange()
        #expect(await waitUntil { await self.registered(engine, account.id, over: .ipv6) })
        expectMove(stub, log, account.id, from: .ipv4, to: .ipv6, since: since, lag: 0.5)
        let live = try #require(await engine.liveAccountSettingsForTests(account.id))
        #expect(live.transportID == ids.udp6 && live.sdpNATRewrite && live.mediaIPv6Only)

        answer.withLock { $0 = [.ipv4, .ipv6] }
        stub.unregisterDelay = 0
        let back = Date()
        await engine.simulateNetworkChange()
        #expect(await waitUntil { await self.registered(engine, account.id, over: .ipv4) })
        expectMove(stub, log, account.id, from: .ipv6, to: .ipv4, since: back)
        #expect(await engine.liveAccountSettingsForTests(account.id)?.sdpNATRewrite == false)
        await engine.stop()
    }

    /// Changing the IP protocol in the editor (updateAccount) moves the account the same way; an
    /// update with nothing relevant changed (what the app does when the default account changes)
    /// keeps the family, sends no un-REGISTER and keeps a family Auto fell back to.
    @Test func ipProtocolChangeMovesTheAccount() async throws {
        let stub = try IPv6Stub(dualStack: true)
        defer { stub.stop() }
        let answer = OSAllocatedUnfairLock(initialState: [IPFamily.ipv4, .ipv6])
        let (engine, account, log, consumer) = try await startAutoLocalhost(stub, answer: answer)
        defer { consumer.cancel() }
        #expect(await waitUntil { await engine.registrationState(of: account.id).isRegistered })
        var six = account
        six.ipProtocol = .ipv6
        stub.unregisterDelay = 0.6
        let since = Date()
        try await engine.updateAccount(six, password: nil)
        #expect(await waitUntil { await self.registered(engine, account.id, over: .ipv6) })
        expectMove(stub, log, account.id, from: .ipv4, to: .ipv6, since: since, lag: 0.5)
        #expect(await engine.liveAccountSettingsForTests(account.id)?.sdpNATRewrite == true)

        // Same settings again (the default account changed): no move, no un-REGISTER.
        let mark = stub.registers.count
        six.isDefaultOutgoing = true
        try await engine.updateAccount(six, password: nil)
        try await Task.sleep(for: .milliseconds(500))
        #expect(stub.registers.dropFirst(mark).allSatisfy { !$0.unregister && $0.family == .ipv6 })
        #expect(await engine.accountFamilyForTests(account.id) == .ipv6)
        await engine.stop()
    }

    /// Auto follows the system order for the first REGISTER; when that gets no answer at all (here: the
    /// IPv6 side of the server is silent), it moves to the other family at once and registers there.
    /// The working family then stays (sticky) until the next network change: a later retry stays on it,
    /// and so does an update that changes nothing relevant.
    @Test func autoFallsBackToTheOtherFamilyWithoutAnswer() async throws {
        let stub = try IPv6Stub(dualStack: true)
        defer { stub.stop() }
        stub.silentFamilies = [.ipv6]
        let answer = OSAllocatedUnfairLock(initialState: [IPFamily.ipv6, .ipv4])
        let (engine, account, log, consumer) = try await startAutoLocalhost(stub, answer: answer)
        defer { consumer.cancel() }
        #expect(await waitUntil(timeout: 6) { await engine.registrationState(of: account.id).isRegistered })
        #expect(stub.bindingRegisters.map(\.family).prefix(1) == [.ipv6])
        #expect(stub.bindingRegisters.last?.family == .ipv4)
        #expect(await engine.accountFamilyForTests(account.id) == .ipv4)
        #expect(!logLines(log, containing: "no answer over IPv6; trying IPv4").isEmpty)

        var updated = account
        updated.isDefaultOutgoing = true
        let before = stub.registers.count
        try await engine.updateAccount(updated, password: nil)
        try await Task.sleep(for: .milliseconds(500))
        #expect(await engine.accountFamilyForTests(account.id) == .ipv4)
        #expect(stub.registers.dropFirst(before).allSatisfy { $0.family == .ipv4 && !$0.unregister })

        // IPv4 goes silent too; the backoff retry stays on IPv4 (the resolver still says IPv6 first),
        // and only its failure moves the account back to IPv6, which answers again.
        stub.silentFamilies = [.ipv4]
        let mark = stub.bindingRegisters.count
        try await engine.setRegistered(account.id, true)
        #expect(await waitUntil(timeout: 10) { await engine.registrationState(of: account.id).isRegistered
            && stub.bindingRegisters.count > mark + 2 })
        let families = stub.bindingRegisters.dropFirst(mark).map(\.family)
        #expect(Array(families.prefix(3)) == [.ipv4, .ipv4, .ipv6], "\(families)")
        await engine.stop()
    }

    /// A network change whose REGISTER gets no answer over the account's family: the fallback is
    /// recorded during the round and the account moves as soon as the round ends, not a backoff later.
    @Test func fallbackAfterARoundMovesWhenTheRoundEnds() async throws {
        let stub = try IPv6Stub(dualStack: true)
        defer { stub.stop() }
        let answer = OSAllocatedUnfairLock(initialState: [IPFamily.ipv6, .ipv4])
        let (engine, account, _, consumer) = try await startAutoLocalhost(stub, answer: answer)
        defer { consumer.cancel() }
        #expect(await waitUntil { await engine.registrationState(of: account.id).isRegistered })
        #expect(await engine.accountFamilyForTests(account.id) == .ipv6)
        stub.silentFamilies = [.ipv6]
        let started = Date()
        await engine.simulateNetworkChange()
        #expect(await waitUntil(timeout: 6) { stub.bindingRegisters.contains { $0.family == .ipv4 && $0.at > started } })
        let v4 = try #require(stub.bindingRegisters.first { $0.family == .ipv4 && $0.at > started })
        // Round REGISTER timeout (2 s) and the move; the old path waited for a 2 s backoff and a
        // second 2 s IPv6 timeout first.
        #expect(v4.at.timeIntervalSince(started) < 3.5, "\(v4.at.timeIntervalSince(started)) s")
        #expect(await waitUntil { await engine.registrationState(of: account.id).isRegistered })
        await engine.stop()
    }

    /// A TCP connection that is refused counts as no answer: the account moves to IPv6 at once.
    @Test func autoFallsBackWhenTheConnectionIsRefused() async throws {
        let stub = try IPv6Stub()                                      // TCP on [::1] only
        defer { stub.stop() }
        let answer = OSAllocatedUnfairLock(initialState: [IPFamily.ipv4, .ipv6])
        let (engine, account, _, consumer) = try await startAutoLocalhost(stub, answer: answer, transport: .tcp)
        defer { consumer.cancel() }
        #expect(await waitUntil(timeout: 4) { await engine.registrationState(of: account.id).isRegistered })
        #expect(stub.registers.last?.family == .ipv6 && stub.registers.last?.transport == "TCP")
        #expect(await engine.accountFamilyForTests(account.id) == .ipv6)
        await engine.stop()
    }

    /// A server that answers is no reason to try the other family, even with a temporary failure it
    /// sends itself (503: retried with backoff, on the same family). Only no answer at all is (the
    /// REGISTER result has no rdata).
    @Test func autoKeepsTheFamilyWhenTheServerAnswers() async throws {
        let stub = try IPv6Stub(dualStack: true)
        defer { stub.stop() }
        stub.registerAnswers = [.ipv6: "503 Service Unavailable"]
        let answer = OSAllocatedUnfairLock(initialState: [IPFamily.ipv6, .ipv4])
        let (engine, account, _, consumer) = try await startAutoLocalhost(stub, answer: answer)
        defer { consumer.cancel() }
        #expect(await waitUntil {
            if case .reconnecting = await engine.registrationState(of: account.id) { return true }
            return false
        })
        // The first retry comes after 2 s: still IPv6.
        #expect(await waitUntil(timeout: 4) { stub.bindingRegisters.count >= 2 })
        #expect(stub.registers.allSatisfy { $0.family == .ipv6 }, "\(stub.registers.map(\.family))")
        #expect(await engine.accountFamilyForTests(account.id) == .ipv6)
        await engine.stop()
    }

    /// An account is never moved to the other family while it has a call (the dialog would keep the
    /// old family's peer and lose its transport): the round keeps it, the move waits for the call to
    /// end, then the account moves (un-REGISTER, REGISTER) as any move does.
    @Test func familyMoveWaitsForTheAccountsCalls() async throws {
        let stub = try IPv6Stub(dualStack: true)
        defer { stub.stop() }
        let answer = OSAllocatedUnfairLock(initialState: [IPFamily.ipv4, .ipv6])
        let (engine, account, log, consumer) = try await startAutoLocalhost(stub, answer: answer)
        defer { consumer.cancel() }
        #expect(await waitUntil { await engine.registrationState(of: account.id).isRegistered })
        let call = try await engine.makeCall(to: DialString(uri: "sip:300@localhost:\(stub.port)", display: "300"), from: account.id)
        #expect(await waitUntil { await engine.calls().first { $0.id == call }?.state == .connected })

        answer.withLock { $0 = [.ipv6, .ipv4] }
        await engine.simulateNetworkChange()
        #expect(await waitUntil { await engine.ipChangeStateForTests().running == nil })
        try await Task.sleep(for: .milliseconds(1500))
        #expect(await engine.accountFamilyForTests(account.id) == .ipv4)
        #expect(stub.bindingRegisters.allSatisfy { $0.family == .ipv4 })
        #expect(await engine.calls().first { $0.id == call }?.state == .connected)

        let since = Date()
        try await engine.hangup(call)
        #expect(await waitUntil { await engine.calls().isEmpty })
        #expect(await waitUntil(timeout: 4) { await self.registered(engine, account.id, over: .ipv6) })
        expectMove(stub, log, account.id, from: .ipv4, to: .ipv6, since: since)
        await engine.stop()
    }

    /// IPv6 appearing while a round runs (here: its REGISTER waits for an answer) must not touch the
    /// account until the round ends: the round completes on its own REGISTER result (not the 7 s safety
    /// timer), and only then the account moves to IPv6 and ends up registered there.
    @Test func ipv6AppearingDuringARoundWaitsForTheRound() async throws {
        let stub = try IPv6Stub(dualStack: true)
        defer { stub.stop() }
        let answer = OSAllocatedUnfairLock(initialState: [IPFamily.ipv4, .ipv6])
        let (engine, account, log, consumer) = try await startAutoLocalhost(stub, answer: answer)
        defer { consumer.cancel() }
        await engine.setIPv6AddressAssignedForTests { $0 == "2001:db8::10" }
        func path(_ v6: String) -> NetworkPath {
            NetworkPath(satisfied: true, interface: "en0", address: "192.168.1.20", address6: v6, gateway: "192.168.1.1")
        }
        #expect(await waitUntil { await engine.registrationState(of: account.id).isRegistered })
        await engine.applyPathForTests(path(""))
        #expect(await waitUntil { await engine.ipChangeStateForTests().running == nil })
        #expect(await waitUntil { await engine.registrationState(of: account.id).isRegistered })

        stub.registerAnswers = [.ipv4: "503 Service Unavailable"]     // the round's REGISTER fails over IPv4...
        stub.silentFamilies = [.ipv4]                                  // ...after 2 s without an answer
        let started = Date()
        await engine.simulateNetworkChange()
        #expect(await engine.ipChangeStateForTests().running != nil)
        answer.withLock { $0 = [.ipv6, .ipv4] }
        await engine.applyPathForTests(path("2001:db8::10"))           // IPv6 appeared, no IPv6 account
        try await Task.sleep(for: .milliseconds(300))
        #expect(await engine.accountFamilyForTests(account.id) == .ipv4)    // not during the round
        stub.silentFamilies = []
        stub.registerAnswers = [:]
        #expect(await waitUntil(timeout: 5) { await engine.ipChangeStateForTests().running == nil })
        #expect(Date().timeIntervalSince(started) < 5, "the round ended by its safety timer")
        #expect(logLines(log, containing: "no completion report").isEmpty)
        #expect(await waitUntil(timeout: 6) { await self.registered(engine, account.id, over: .ipv6) })
        #expect(stub.bindingRegisters.last?.family == .ipv6)
        await engine.stop()
    }

    /// DNS SRV in effect, no port: Auto starts with IPv4; with no answer over IPv4 it falls back to
    /// IPv6 (the only other chance), and a network change undoes that (back to IPv4 first).
    @Test func srvFallbackIsUndoneAtANetworkChange() async throws {
        let stub = try IPv6Stub(dualStack: true)
        defer { stub.stop() }
        let dns = try DNSStub(records: [
            "_sip._udp.example.test": [.srv(target: "pbx.example.test", port: stub.port)],
            "pbx.example.test": [.a("127.0.0.1"), .aaaa("::1")],
        ])
        defer { dns.stop() }
        stub.silentFamilies = [.ipv4]
        let engine = await makeEngine(bindAddress: nil)
        await engine.setTestTimings(transactionTimeoutMs: 2000)
        var net = Self.network
        net.dnsSRV = true
        net.nameserver = "127.0.0.1:\(dns.port)"
        try await engine.start(network: net)
        let account = AccountConfig(displayName: "S", username: "1001", domain: "example.test", mwi: false)
        try await engine.addAccount(account, password: "pw")
        #expect(await waitUntil(timeout: 6) { await self.registered(engine, account.id, over: .ipv6) })
        let mark = Date()
        await engine.simulateNetworkChange()
        #expect(await waitUntil(timeout: 6) { stub.bindingRegisters.contains { $0.family == .ipv4 && $0.at > mark } },
                "\(stub.registers.map { "\($0.family) \($0.unregister)" })")
        await engine.stop()
    }

    /// After a move, the voicemail (MWI) and presence subscriptions are made anew over the new family
    /// (their dialogs keep the transport they were created with).
    @Test func subscriptionsFollowAFamilyMove() async throws {
        let stub = try IPv6Stub(dualStack: true)
        defer { stub.stop() }
        let answer = OSAllocatedUnfairLock(initialState: [IPFamily.ipv4, .ipv6])
        let (engine, account, _, consumer) = try await startAutoLocalhost(stub, answer: answer, mwi: true)
        defer { consumer.cancel() }
        #expect(await waitUntil { await engine.registrationState(of: account.id).isRegistered })
        try await engine.subscribePresence(uri: "sip:200@localhost:\(stub.port)")
        func subscribes(_ event: String, _ family: IPFamily) -> Int {
            stub.requests.filter { $0.method == "SUBSCRIBE" && $0.event.hasPrefix(event) && $0.family == family }.count
        }
        #expect(await waitUntil { subscribes("message-summary", .ipv4) > 0 && subscribes("presence", .ipv4) > 0 },
                "\(stub.requests.map { "\($0.method) \($0.event) \($0.family)" })")

        answer.withLock { $0 = [.ipv6, .ipv4] }
        await engine.simulateNetworkChange()
        #expect(await waitUntil { await engine.accountFamilyForTests(account.id) == .ipv6 })
        #expect(await waitUntil { subscribes("message-summary", .ipv6) > 0 }, "\(stub.requests.map { "\($0.method) \($0.event) \($0.family)" })")
        #expect(await waitUntil { subscribes("presence", .ipv6) > 0 }, "\(stub.requests.map { "\($0.method) \($0.event) \($0.family)" })")
        await engine.stop()
    }

    /// Family lookups never block the engine: a slow resolver delays neither `addAccount` nor a round;
    /// one lookup runs per host however many accounts or triggers want it, and its answer is cached
    /// for a while. A new account waits for its lookup before its first REGISTER (at most the lookup
    /// wait), then registers over what the lookup said.
    @Test func familyLookupsDoNotBlockTheEngine() async throws {
        let stub = try IPv6Stub(dualStack: true)
        defer { stub.stop() }
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let slow = OSAllocatedUnfairLock(initialState: 0.0)
        let engine = await makeEngine(bindAddress: nil)
        await engine.setFamilyResolverForTests { _ in
            calls.withLock { $0 += 1 }
            Thread.sleep(forTimeInterval: slow.withLock { $0 })
            return [.ipv6, .ipv4]
        }
        try await engine.start(network: Self.network)
        slow.withLock { $0 = 1 }
        let a = AccountConfig(displayName: "A", username: "1", domain: "localhost:\(stub.port)", mwi: false)
        let b = AccountConfig(displayName: "B", username: "2", domain: "localhost:\(stub.port)", mwi: false)
        let started = ContinuousClock.now
        try await engine.addAccount(a, password: "pw")
        try await engine.addAccount(b, password: "pw")
        #expect(ContinuousClock.now - started < .milliseconds(500))
        #expect(stub.registers.isEmpty)                           // the first REGISTER waits for the lookup
        #expect(await waitUntil(timeout: 4) {
            let one = await engine.registrationState(of: a.id).isRegistered
            let two = await engine.registrationState(of: b.id).isRegistered
            return one && two
        })
        #expect(stub.bindingRegisters.allSatisfy { $0.family == .ipv6 }, "\(stub.registers.map(\.family))")
        #expect(calls.withLock { $0 } == 1)                       // one lookup for both accounts

        // Cached: an update that changes the server back to the same host asks nobody.
        var moved = a
        moved.registrar = "localhost:\(stub.port)"
        try await engine.updateAccount(moved, password: nil)
        #expect(calls.withLock { $0 } == 1)

        let round = ContinuousClock.now
        await engine.simulateNetworkChange()                      // the cache is dropped; lookups again
        #expect(ContinuousClock.now - round < .milliseconds(500))
        #expect(await waitUntil(timeout: 3) { calls.withLock { $0 } == 2 })
        await engine.stop()
    }

    /// IPv6 address changes (pure rules through injected paths): IPv6 appearing or a new address
    /// without IPv6 accounts starts no round; with an IPv6 account a new temporary address whose
    /// predecessor is still assigned is a non-primary change (it waits for a ringing outgoing call),
    /// while losing the address is primary, also when the address stays assigned but the path has no
    /// IPv6 route any more.
    @Test func ipv6AddressChangesStartRoundsOnlyWhenTheyMatter() async throws {
        let stub = try IPv6Stub()
        defer { stub.stop() }
        let assigned = OSAllocatedUnfairLock(initialState: Set<String>())
        let engine = await makeEngine(bindAddress: nil)
        await engine.setIPv6AddressAssignedForTests { address in assigned.withLock { $0.contains(address) } }
        try await engine.start(network: Self.network)
        func path(_ v6: String, route: Bool = true) -> NetworkPath {
            NetworkPath(satisfied: true, interface: "en0", address: "192.168.1.20", address6: v6, gateway: "192.168.1.1",
                        ipv6Route: route)
        }
        func settle() async { _ = await waitUntil { await engine.ipChangeStateForTests().running == nil } }
        func rounds() async -> UInt64 { await engine.ipChangeStateForTests().rounds }
        await engine.applyPathForTests(path(""))                           // a new primary route
        await settle()
        var count = await rounds()
        assigned.withLock { $0 = ["2001:db8::10"] }
        await engine.applyPathForTests(path("2001:db8::10"))               // IPv6 appeared, no IPv6 account
        await settle()
        #expect(await rounds() == count)
        assigned.withLock { $0 = ["2001:db8::10", "2001:db8::11"] }
        await engine.applyPathForTests(path("2001:db8::11"))               // rotated, no IPv6 account
        await settle()
        #expect(await rounds() == count)

        let account = localIPv6Account("6")
        try await engine.addAccount(account, password: "")
        stub.ringOnly = true
        let call = try await engine.makeCall(to: DialString(uri: "sip:300@[::1]:\(stub.port)", display: "300"), from: account.id)
        #expect(await waitUntil { await engine.calls().first { $0.id == call }?.state == .early })
        assigned.withLock { $0 = ["2001:db8::11", "2001:db8::12"] }
        await engine.applyPathForTests(path("2001:db8::12"))               // rotated, ::11 still assigned
        #expect(await engine.ipChangeStateForTests().postponed)
        #expect(await rounds() == count)
        #expect(await engine.calls().first { $0.id == call }?.state == .early)

        // The address stays assigned (an RA lifetime has not run out) but the path has no IPv6 route.
        await engine.applyPathForTests(path("", route: false))             // IPv6 lost: primary, at once
        #expect(await waitUntil { await rounds() == count + 1 })
        count += 1
        await settle()
        try? await engine.hangup(call)
        #expect(await waitUntil(timeout: 5) { await engine.calls().isEmpty })
        await engine.stop()
    }

    /// A network change with the engine on all interfaces restarts the IPv6 listeners too; the IPv6
    /// account registers again over UDP6.
    @Test func networkChangeRestartsIPv6Listeners() async throws {
        let stub = try IPv6Stub()
        defer { stub.stop() }
        let engine = await makeEngine(bindAddress: nil)
        let log = EventLog()
        let consumer = log.consume(engine)
        defer { consumer.cancel() }
        try await engine.start(network: Self.network)
        let account = AccountConfig(displayName: "R6", username: "1010", domain: "[::1]",
                                    registrar: "[::1]:\(stub.port)", mwi: false)
        try await engine.addAccount(account, password: "pw")
        #expect(await waitUntil { await engine.registrationState(of: account.id).isRegistered })
        let ids = await engine.transportIDsForTests()
        let count = stub.registers.count
        await engine.simulateNetworkChange()
        #expect(await waitUntil { stub.registers.count > count })
        #expect(await waitUntil { await engine.ipChangeStateForTests().running == nil })
        #expect(stub.registers.last?.family == .ipv6)
        let restarted = log.all.compactMap { e -> String? in
            if case let .log(_, t) = e, t.contains("listener"), t.contains("restarted") { return t }
            return nil
        }
        for id in [ids.udp6, ids.tcp6, ids.tls6, ids.tls6NoVerify].compactMap({ $0 }) {
            #expect(restarted.contains { $0.contains("listener \(id) restarted (ok)") }, "\(restarted)")
        }
        #expect(await engine.registrationState(of: account.id).isRegistered)
        await engine.stop()
    }

    /// ICE honours an IPv6 bind address (scripts/pjsip-patches/0001: the IPv6 ICE component binds to the
    /// account's IPv6 bound address, as the IPv4 one does, and keeps a loopback candidate when that is
    /// where it is bound). With `bindAddress` "::1" the offer's only IPv6 candidate is ::1, and a call
    /// between two ICE legs on loopback negotiates ICE over IPv6 and carries RTP.
    @Test func iceOverIPv6HonoursTheBindAddress() async throws {
        let stub = try IPv6Stub()
        defer { stub.stop() }
        let engine = await makeEngine(bindAddress: "::1")
        let log = EventLog()
        let consumer = log.consume(engine)
        defer { consumer.cancel() }
        var net = Self.network
        net.useICE = true
        try await engine.start(network: net)
        let account = localIPv6Account("ice")
        try await engine.addAccount(account, password: "")
        let probe = try await engine.makeCall(to: DialString(uri: "sip:300@[::1]:\(stub.port)", display: "300"), from: account.id)
        #expect(await waitUntil(timeout: 8) { stub.requests.contains { $0.method == "INVITE" } })
        let offer = try #require(stub.requests.first { $0.method == "INVITE" }).body
        let v6 = offer.components(separatedBy: "\r\n").filter { $0.hasPrefix("a=candidate:") }.compactMap { line -> String? in
            let f = line.split(separator: " ")
            return f.count > 7 && f[4].contains(":") ? String(f[4]) : nil
        }
        #expect(!v6.isEmpty && v6.allSatisfy { $0 == "::1" }, "IPv6 candidates \(v6)")
        #expect(sdpConnection(offer) == "IN IP6 ::1", "\(offer)")
        try? await engine.hangup(probe)
        #expect(await waitUntil { await engine.calls().isEmpty })

        let port6 = await engine.localPort(of: .udp, family: .ipv6)
        let mark = log.all.count
        let out = try await engine.makeCall(to: DialString(uri: "sip:ice@[::1]:\(port6)", display: "ice"), from: account.id)
        func incoming() -> CallInfo? {
            log.all.dropFirst(mark).lazy.compactMap { if case let .incomingCall(c) = $0 { return c }; return nil }.first
        }
        #expect(await waitUntil { incoming() != nil })
        let inc = try #require(incoming())
        try await engine.answer(inc.id)
        #expect(await waitUntil(timeout: 8) {
            let a = try? await engine.mediaStats(out), b = try? await engine.mediaStats(inc.id)
            return (a?.rxPackets ?? 0) > 10 && (b?.rxPackets ?? 0) > 10
        })
        #expect(await engine.localRTPAddress(of: out) == "::1")
        try await engine.hangup(out)
        #expect(await waitUntil { await engine.calls().isEmpty })
        await engine.stop()
    }

    /// With ICE on (PJSIP patched: scripts/pjsip-patches/0001-ipv6-ice-bind-any.patch), an IPv6 call
    /// gathers IPv6 host candidates: the offer is `c=IN IP6` with an IPv6 default candidate, lists IPv6
    /// `typ host` candidates (and IPv4 ones from pjsua's second component), and the call to a peer
    /// without ICE connects with RTP over IPv6. Without the patch the IPv6 ICE socket could not be
    /// bound ("::ffff:0.0.0.0") and the offer had IPv4 candidates only. pjnath leaves out ::1 (and
    /// link-local addresses other than the default one), so the IPv6 candidate is the Mac's default
    /// IPv6 address: link-local or global, never loopback.
    @Test func iceGathersIPv6CandidatesOverIPv6() async throws {
        let stub = try IPv6Stub()
        defer { stub.stop() }
        let engine = await makeEngine(bindAddress: nil)
        var net = Self.network
        net.useICE = true
        try await engine.start(network: net)
        let account = localIPv6Account("ice")
        try await engine.addAccount(account, password: "")
        let live = try #require(await engine.liveAccountSettingsForTests(account.id))
        #expect(live.iceEnabled && live.mediaIPv6Only)
        let call = try await engine.makeCall(to: DialString(uri: "sip:300@[::1]:\(stub.port)", display: "300"), from: account.id)
        #expect(await waitUntil(timeout: 8) { await engine.calls().first { $0.id == call }?.state == .connected })
        let offer = try #require(stub.requests.first { $0.method == "INVITE" }).body
        let connection = sdpConnection(offer)
        #expect(connection.hasPrefix("IN IP6 "), "\(offer)")
        let hosts = offer.components(separatedBy: "\r\n").filter { $0.hasPrefix("a=candidate:") }.compactMap { line -> String? in
            let f = line.split(separator: " ")
            return f.count > 7 && f[7] == "host" ? String(f[4]) : nil
        }
        #expect(hosts.contains { $0.contains(":") }, "IPv6 host candidates: \(hosts)")
        #expect(hosts.contains(String(connection.dropFirst("IN IP6 ".count))), "default \(connection), hosts \(hosts)")
        #expect(await waitUntil { ((try? await engine.mediaStats(call))?.txPackets ?? 0) > 10 })
        #expect(await engine.localRTPAddress(of: call).contains(":"))
        try await engine.hangup(call)
        #expect(await waitUntil { await engine.calls().isEmpty })
        await engine.stop()
    }
}
