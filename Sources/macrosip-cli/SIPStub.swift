import Foundation
import os

/// A minimal SIP server on 127.0.0.1 (UDP) for the self-test: a registrar and a user agent
/// that answers calls, in the style of an Asterisk/res_pjsip PBX.
/// - REGISTER and INVITE without credentials get `401` with a digest challenge (qop=auth,
///   long nonce and opaque); with an `Authorization` header (not checked) REGISTER gets 200
///   and INVITE 100 + 200 with an SDP answer that offers PCMU only, without telephone-event,
///   so RFC 2833 is impossible and DTMF must use SIP INFO.
/// - re-INVITE: 200 with the same SDP; INFO, BYE, OPTIONS: 200; ACK: ignored.
/// It records request sizes and INFO bodies for the checks.
final class SIPStub: Sendable {
    struct Stats: Sendable {
        var registers = 0
        var invites = 0
        /// Sizes of INVITEs (initial and re-INVITEs) that carried an Authorization header.
        var authorizedInviteSizes: [Int] = []
        var infoBodies: [String] = []
        var byes = 0
    }

    let port: UInt16
    /// RTP port in the SDP answer; a bound socket that is never read (no ICMP errors).
    let rtpPort: UInt16
    let challenge: Bool
    private let fd: Int32
    private let rtpFD: Int32
    private let stopped = OSAllocatedUnfairLock(initialState: false)
    private let state = OSAllocatedUnfairLock(initialState: Stats())

    init(challenge: Bool = true) throws {
        (fd, port) = try SIPStub.bindUDP(timeoutMs: 100)
        do {
            (rtpFD, rtpPort) = try SIPStub.bindUDP(timeoutMs: 0)
        } catch {
            close(fd)
            throw error
        }
        self.challenge = challenge
        Thread.detachNewThread { [self] in self.serve() }
    }

    var stats: Stats { state.withLock { $0 } }

    func stop() { stopped.withLock { $0 = true } }

    private static func bindUDP(timeoutMs: Int) throws -> (Int32, UInt16) {
        let sock = socket(AF_INET, SOCK_DGRAM, 0)
        guard sock >= 0 else { throw SelfTest.Failure(description: "stub socket: errno \(errno)") }
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
        guard ok else { close(sock); throw SelfTest.Failure(description: "stub bind: errno \(errno)") }
        if timeoutMs > 0 {
            var tv = timeval(tv_sec: 0, tv_usec: Int32(timeoutMs * 1000))
            setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        }
        return (sock, UInt16(bigEndian: addr.sin_port))
    }

    private func serve() {
        var buf = [UInt8](repeating: 0, count: 65_536)
        while !stopped.withLock({ $0 }) {
            var from = sockaddr_in()
            var fromLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &from) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buf, buf.count, 0, $0, &fromLen) }
            }
            guard n > 0 else { continue }
            handle(String(decoding: buf[0..<n], as: UTF8.self), size: n, from: from)
        }
        close(fd)
        close(rtpFD)
    }

    private func handle(_ text: String, size: Int, from: sockaddr_in) {
        guard let split = text.range(of: "\r\n\r\n") else { return }
        let head = text[..<split.lowerBound]
        let body = String(text[split.upperBound...])
        let lines = head.components(separatedBy: "\r\n")
        guard let requestLine = lines.first, !requestLine.hasPrefix("SIP/2.0") else { return }
        let method = String(requestLine.prefix { $0 != " " })
        guard method != "ACK" else { return }

        var echoed: [String] = []
        var toLine = ""
        var contact: String?
        var authorized = false
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            switch name {
            case "via", "v", "from", "f", "call-id", "i", "cseq": echoed.append(line)
            case "to", "t": toLine = line
            case "contact", "m": contact = contact ?? String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            case "authorization": authorized = true
            default: break
            }
        }
        if !toLine.lowercased().contains("tag=") { toLine += ";tag=stub-\(UInt32.random(in: 1...UInt32.max))" }

        func reply(_ status: String, extra: [String] = [], body: String = "", type: String? = nil) {
            var msg = "SIP/2.0 \(status)\r\n" + echoed.joined(separator: "\r\n") + "\r\n" + toLine + "\r\n"
            for h in extra { msg += h + "\r\n" }
            if let type { msg += "Content-Type: \(type)\r\n" }
            msg += "Server: macrosip-selftest-stub\r\nContent-Length: \(body.utf8.count)\r\n\r\n" + body
            send(msg, to: from)
        }

        let challengeHeader = "WWW-Authenticate: Digest realm=\"asterisk\", "
            + "nonce=\"\(Int(Date().timeIntervalSince1970))/\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())\", "
            + "opaque=\"\(UUID().uuidString.prefix(18).lowercased())\", algorithm=MD5, qop=\"auth\""

        switch method {
        case "REGISTER":
            state.withLock { $0.registers += 1 }
            if challenge && !authorized { reply("401 Unauthorized", extra: [challengeHeader]); return }
            var extra = ["Expires: 300"]
            if let contact { extra.append("Contact: \(contact);expires=300") }
            reply("200 OK", extra: extra)
        case "INVITE":
            let isAuthorized = authorized
            state.withLock {
                $0.invites += 1
                if isAuthorized { $0.authorizedInviteSizes.append(size) }
            }
            if challenge && !authorized { reply("401 Unauthorized", extra: [challengeHeader]); return }
            reply("100 Trying")
            // Mirror the offer's direction (hold: sendonly -> recvonly).
            let direction = body.contains("a=sendonly") ? "recvonly"
                : body.contains("a=inactive") ? "inactive"
                : body.contains("a=recvonly") ? "sendonly" : "sendrecv"
            let sdp = "v=0\r\no=stub 1 1 IN IP4 127.0.0.1\r\ns=stub\r\nc=IN IP4 127.0.0.1\r\nt=0 0\r\n"
                + "m=audio \(rtpPort) RTP/AVP 0\r\na=rtpmap:0 PCMU/8000\r\na=\(direction)\r\n"
            reply("200 OK", extra: ["Contact: <sip:stub@127.0.0.1:\(port)>", "Allow: INVITE, ACK, BYE, CANCEL, INFO, OPTIONS"],
                  body: sdp, type: "application/sdp")
        case "INFO":
            state.withLock { $0.infoBodies.append(body) }
            reply("200 OK")
        case "BYE":
            state.withLock { $0.byes += 1 }
            reply("200 OK")
        default:
            reply("200 OK")
        }
    }

    private func send(_ text: String, to dest: sockaddr_in) {
        var dest = dest
        let bytes = Array(text.utf8)
        _ = withUnsafePointer(to: &dest) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(fd, bytes, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
    }
}
