import Foundation
import os
import Testing
@testable import MacroSIPCore

// Release 26.2 engine work (docs/ENGINE.md "Network options", "Deny incoming calls",
// "Codecs"): RTP port window, rport, DNS SRV, deny rules, the added codecs.

// MARK: - DNS stub

/// A DNS server on 127.0.0.1 (one UDP socket, random port) that answers SRV and A queries
/// from a fixed table and NXDOMAIN for everything else. Records every question as
/// "SRV _sip._udp.example.test" / "A pbx.example.test".
final class DNSStub: Sendable {
    enum Record: Sendable {
        case srv(target: String, port: UInt16)
        case a(String)
    }

    let port: UInt16
    private let fd: Int32
    private let records: [String: [Record]]
    private let stopped = OSAllocatedUnfairLock(initialState: false)
    private let asked = OSAllocatedUnfairLock(initialState: [String]())

    var queries: [String] { asked.withLock { $0 } }

    init(records: [String: [Record]]) throws {
        self.records = Dictionary(uniqueKeysWithValues: records.map { ($0.key.lowercased(), $0.value) })
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
        var buf = [UInt8](repeating: 0, count: 2048)
        while !stopped.withLock({ $0 }) {
            var from = sockaddr_in()
            var fromLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &from) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buf, buf.count, 0, $0, &fromLen) }
            }
            guard n > 12, let reply = answer(Array(buf[0..<n])) else { continue }
            _ = withUnsafePointer(to: &from) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, reply, reply.count, 0, $0, fromLen) }
            }
        }
        close(fd)
    }

    private static func encodeName(_ name: String) -> [UInt8] {
        var out: [UInt8] = []
        for label in name.split(separator: ".") {
            out.append(UInt8(label.utf8.count))
            out += Array(label.utf8)
        }
        return out + [0]
    }

    private static func u16(_ v: Int) -> [UInt8] { [UInt8((v >> 8) & 0xff), UInt8(v & 0xff)] }

    private func answer(_ q: [UInt8]) -> [UInt8]? {
        // Question name (uncompressed labels), type, class.
        var i = 12
        var labels: [String] = []
        while i < q.count, q[i] != 0 {
            let len = Int(q[i])
            guard i + 1 + len <= q.count else { return nil }
            labels.append(String(decoding: q[(i + 1)..<(i + 1 + len)], as: UTF8.self))
            i += 1 + len
        }
        guard i + 5 <= q.count else { return nil }
        let qtype = Int(q[i + 1]) << 8 | Int(q[i + 2])
        let questionEnd = i + 5
        let name = labels.joined(separator: ".").lowercased()
        let typeName = qtype == 33 ? "SRV" : qtype == 1 ? "A" : qtype == 28 ? "AAAA" : "TYPE\(qtype)"
        asked.withLock { $0.append("\(typeName) \(name)") }

        var answers: [[UInt8]] = []
        for record in records[name] ?? [] {
            var rr: [UInt8] = [0xc0, 0x0c]                     // name: pointer to the question
            switch record {
            case let .srv(target, port) where qtype == 33:
                let rdata = DNSStub.u16(0) + DNSStub.u16(0) + DNSStub.u16(Int(port)) + DNSStub.encodeName(target)
                rr += DNSStub.u16(33) + DNSStub.u16(1) + [0, 0, 0, 60] + DNSStub.u16(rdata.count) + rdata
            case let .a(address) where qtype == 1:
                let octets = address.split(separator: ".").compactMap { UInt8($0) }
                rr += DNSStub.u16(1) + DNSStub.u16(1) + [0, 0, 0, 60] + DNSStub.u16(4) + octets
            default:
                continue
            }
            answers.append(rr)
        }
        let known = records[name] != nil
        // QR, AA, RD (copied), RA; NXDOMAIN for unknown names, NOERROR/no data otherwise.
        let flags1: UInt8 = 0x84 | (q[2] & 0x01)
        let flags2: UInt8 = known ? 0x80 : 0x83
        var out: [UInt8] = [q[0], q[1], flags1, flags2] + DNSStub.u16(1) + DNSStub.u16(answers.count) + DNSStub.u16(0) + DNSStub.u16(0)
        out += q[12..<questionEnd]
        for a in answers { out += a }
        return out
    }
}

// MARK: - value tests (no pjsua)

@Suite("26.2 engine values")
struct Engine262ValueTests {
    @Test func networkSettingsDecodeOldJSONWithDefaults() throws {
        let old = #"{"stunServer":"stun.example.com:3478","localPort":5070,"keepAliveSeconds":20,"useICE":true,"echoCancellation":false}"#
        let n = try JSONDecoder().decode(NetworkSettings.self, from: Data(old.utf8))
        #expect(n.stunServer == "stun.example.com:3478" && n.localPort == 5070 && n.keepAliveSeconds == 20)
        #expect(n.useICE && !n.echoCancellation)
        #expect(n.rtpPortStart == 4000 && n.rtpPortCount == 1000)
        #expect(n.useRport && !n.dnsSRV && n.nameserver == nil)
        // A file without STUN keeps STUN off (nil), as before.
        let noStun = try JSONDecoder().decode(NetworkSettings.self, from: Data(#"{"localPort":0}"#.utf8))
        #expect(noStun.stunServer == nil && noStun.keepAliveSeconds == 15 && noStun.echoCancellation)

        var all = NetworkSettings(rtpPortStart: 20000, rtpPortCount: 200, useRport: false, dnsSRV: true, nameserver: "10.0.0.1")
        all.stunServer = nil
        let back = try JSONDecoder().decode(NetworkSettings.self, from: JSONEncoder().encode(all))
        #expect(back == all)
    }

    @Test func rtpRangeValidationAndMapping() {
        #expect(NetworkSettings.isValidRTPRange(start: 4000, count: 1000))
        #expect(NetworkSettings.isValidRTPRange(start: 1024, count: 8))
        #expect(NetworkSettings.isValidRTPRange(start: 65528, count: 8))
        #expect(!NetworkSettings.isValidRTPRange(start: 1023, count: 10))
        #expect(!NetworkSettings.isValidRTPRange(start: 65529, count: 8))
        #expect(!NetworkSettings.isValidRTPRange(start: 60000, count: 6000))
        #expect(!NetworkSettings.isValidRTPRange(start: 4000, count: 7))
        func eff(_ start: Int, _ count: Int) -> String {
            let r = NetworkSettings(rtpPortStart: start, rtpPortCount: count).effectiveRTPRange
            return "\(r.start)+\(r.count)"
        }
        #expect(eff(80, 10) == "1024+10")
        #expect(eff(65000, 5000) == "65000+536")
        #expect(eff(70000, 0) == "65528+8")
        #expect(eff(4000, 1000) == "4000+1000")
        // pjsua: RTP in port...port+range, RTCP = RTP + 1, so the last RTP port is start + count - 2.
        #expect(AccountMapping.rtpPortRange(count: 1000) == 998)
        #expect(AccountMapping.rtpPortRange(count: 2) == 1)

        let s = try? AccountMapping.settings(
            for: AccountConfig(displayName: "x", username: "1", domain: "d"), password: "",
            network: NetworkSettings(rtpPortStart: 30000, rtpPortCount: 100), transports: TransportIDs(udp: 0))
        #expect(s?.rtpPort == 30000 && s?.rtpPortRange == 98 && s?.randomizeRTPPort == true)
    }

    @Test func networkSettingsRestartRules() {
        let base = NetworkSettings.default
        func changed(_ f: (inout NetworkSettings) -> Void) -> NetworkSettings { var n = base; f(&n); return n }
        // Live.
        #expect(!changed { $0.useRport = false }.needsRestart(from: base))
        #expect(!changed { $0.keepAliveSeconds = 60 }.needsRestart(from: base))
        #expect(!changed { $0.useICE = true }.needsRestart(from: base))
        #expect(!changed { $0.nameserver = "10.0.0.1" }.needsRestart(from: base))       // SRV off: unused
        // Restart.
        #expect(changed { $0.rtpPortStart = 5000 }.needsRestart(from: base))
        #expect(changed { $0.rtpPortCount = 10 }.needsRestart(from: base))
        #expect(changed { $0.dnsSRV = true }.needsRestart(from: base))
        let srv = changed { $0.dnsSRV = true }
        #expect(changed { $0.dnsSRV = true; $0.nameserver = "10.0.0.1" }.needsRestart(from: srv))
        #expect(changed { $0.localPort = 5070 }.needsRestart(from: base))
        #expect(changed { $0.stunServer = nil }.needsRestart(from: base))
        #expect(changed { $0.echoCancellation = false }.needsRestart(from: base))
    }

    @Test func nameserverParsing() {
        #expect(DNSServers.parse("10.0.0.1") == [DNSServer(host: "10.0.0.1")])
        #expect(DNSServers.parse(" 10.0.0.1:5353, 8.8.8.8 ;1.1.1.1") == [
            DNSServer(host: "10.0.0.1", port: 5353), DNSServer(host: "8.8.8.8"), DNSServer(host: "1.1.1.1")])
        #expect(DNSServers.parse("[2001:db8::1]:54 2001:db8::2") == [
            DNSServer(host: "2001:db8::1", port: 54), DNSServer(host: "2001:db8::2")])
        #expect(DNSServers.parse("fe80::1%en0 10.0.0.1:0 10.0.0.2:x") == [])
        #expect(DNSServers.parse("1.1.1.1 2.2.2.2 3.3.3.3 4.4.4.4 5.5.5.5").count == 4)
        #expect(DNSServers.parse(nil).isEmpty && DNSServers.parse("  ").isEmpty)
        let conf = "# comment\nsearch example.com\nnameserver 192.168.1.1\nnameserver fe80::1%en0\nnameserver 2001:db8::53\n"
        #expect(DNSServers.resolvConf(conf) == [DNSServer(host: "192.168.1.1"), DNSServer(host: "2001:db8::53")])
        #expect(DNSServers.forSettings(NetworkSettings(dnsSRV: false, nameserver: "10.0.0.1")).isEmpty)
        #expect(DNSServers.forSettings(NetworkSettings(dnsSRV: true, nameserver: "10.0.0.1")) == [DNSServer(host: "10.0.0.1")])
    }

    @Test func anonymousCallers() {
        #expect(CallOptions.isAnonymous(fromURI: "sip:anonymous@anonymous.invalid", privacy: nil))
        #expect(CallOptions.isAnonymous(fromURI: "sip:Anonymous@pbx.example.com", privacy: nil))
        #expect(CallOptions.isAnonymous(fromURI: "sip:unknown@pbx.example.com;user=phone", privacy: nil))
        #expect(CallOptions.isAnonymous(fromURI: "sip:pbx.example.com", privacy: nil))
        #expect(CallOptions.isAnonymous(fromURI: "sip:@pbx.example.com", privacy: nil))
        #expect(CallOptions.isAnonymous(fromURI: "sip:100@pbx.example.com", privacy: "id"))
        #expect(CallOptions.isAnonymous(fromURI: "sip:100@pbx.example.com", privacy: "header; ID"))
        #expect(!CallOptions.isAnonymous(fromURI: "sip:100@pbx.example.com", privacy: "none"))
        #expect(!CallOptions.isAnonymous(fromURI: "sip:100@pbx.example.com", privacy: nil))
    }

    @Test func denyRules() {
        let known = CallOptions(denyIncoming: .notInContacts, knownNumbers: ["+375291112233", "alice", "101"])
            .withNormalizedKnownNumbers()
        #expect(known.denial(fromURI: "sip:375291112233@pbx", privacy: nil) == nil)
        #expect(known.denial(fromURI: "sip:+375291112233@pbx", privacy: nil) == nil)
        #expect(known.denial(fromURI: "sip:Alice@pbx", privacy: nil) == nil)
        #expect(known.denial(fromURI: "sip:101@pbx;user=phone", privacy: nil) == nil)
        #expect(known.denial(fromURI: "sip:102@pbx", privacy: nil)?.code == 603)
        #expect(known.denial(fromURI: "sip:anonymous@anonymous.invalid", privacy: nil)?.code == 603)
        #expect(known.denial(fromURI: "sip:101@pbx", privacy: "id")?.code == 603)
        // Not normalised by the engine yet: still found.
        #expect(CallOptions(denyIncoming: .notInContacts, knownNumbers: ["+375 29 111-22-33"])
            .denial(fromURI: "sip:375291112233@pbx", privacy: nil) == nil)

        let everyone = CallOptions(denyIncoming: .everyone)
        #expect(everyone.denial(fromURI: "sip:101@pbx", privacy: nil).map { "\($0.code) \($0.reason)" } == "603 Decline")
        let anonymous = CallOptions(denyIncoming: .anonymous)
        #expect(anonymous.denial(fromURI: "sip:101@pbx", privacy: nil) == nil)
        #expect(anonymous.denial(fromURI: "sip:anonymous@anonymous.invalid", privacy: nil)
            .map { "\($0.code) \($0.reason)" } == "433 Anonymity Disallowed")
        #expect(CallOptions().denial(fromURI: "sip:anonymous@x", privacy: "id") == nil)
        #expect(CallOptions.knownNumberKey("+375 (29) 111-22-33") == "375291112233")
        #expect(CallOptions.knownNumberKey("sip:Bob@host") == "bob")
    }

    @Test func callOptionsJSON() throws {
        let o = CallOptions(denyIncoming: .anonymous, knownNumbers: ["101"])
        let json = String(decoding: try JSONEncoder().encode(o), as: UTF8.self)
        #expect(json.contains("\"denyIncoming\":\"anonymous\""))
        #expect(!json.contains("knownNumbers") && !json.contains("101"))
        let back = try JSONDecoder().decode(CallOptions.self, from: Data(json.utf8))
        #expect(back.denyIncoming == .anonymous && back.knownNumbers.isEmpty)
        let old = try JSONDecoder().decode(CallOptions.self, from: Data(#"{"doNotDisturb":true}"#.utf8))
        #expect(old.denyIncoming == .nobody && old.doNotDisturb)
        let future = try JSONDecoder().decode(CallOptions.self, from: Data(#"{"denyIncoming":"robots"}"#.utf8))
        #expect(future.denyIncoming == .nobody)
    }

    @Test func codecDisplayOrder() {
        let list = [CodecInfo(id: "speex/8000/1", priority: 0), CodecInfo(id: "PCMA/8000/1", priority: 0),
                    CodecInfo(id: "GSM/8000/1", priority: 0), CodecInfo(id: "opus/48000/2", priority: 254),
                    CodecInfo(id: "L16/8000/1", priority: 0), CodecInfo(id: "G7221/16000/1", priority: 0),
                    CodecInfo(id: "PCMU/8000/1", priority: 253)]
        #expect(CodecMapping.unique([CodecInfo(id: "G7221/16000/1", priority: 0), CodecInfo(id: "G7221/16000/1", priority: 200),
                                     CodecInfo(id: "GSM/8000/1", priority: 0)])
                == [CodecInfo(id: "G7221/16000/1", priority: 200), CodecInfo(id: "GSM/8000/1", priority: 0)])
        #expect(CodecMapping.displayOrder(list).map(\.id) == [
            "opus/48000/2", "PCMU/8000/1", "PCMA/8000/1", "G7221/16000/1", "GSM/8000/1", "speex/8000/1", "L16/8000/1"])
    }
}

// MARK: - pjsua tests (part of the serialized "Engine (pjsua)" suite)

extension EngineTests {
    func startLoopback(network: NetworkSettings, codecs: [String] = Engine.defaultCodecOrder,
                       options: CallOptions = CallOptions()) async throws -> (Loopback, Task<Void, Never>) {
        let engine = await makeEngine()
        let log = EventLog()
        let consumer = log.consume(engine)
        try await engine.start(network: network, codecPriorities: codecs, callOptions: options)
        let account = AccountConfig(displayName: "L", username: "loop", domain: "127.0.0.1", enabled: false)
        try await engine.addAccount(account, password: "")
        let port = await engine.localPort(of: .udp)
        return (Loopback(engine: engine, log: log, account: account, port: port), consumer)
    }

    /// Every codec of 26.2 is built and listed (disabled, after G.711); a call between two legs
    /// that both have only GSM negotiates GSM and carries RTP.
    @Test func addedCodecsListedAndGSMNegotiates() async throws {
        let (lb, consumer) = try await startLoopback(network: Self.network, codecs: ["GSM/8000/1"])
        defer { consumer.cancel() }
        let engine = lb.engine
        let codecs = await engine.codecs()
        let ids = codecs.map(\.id)
        for id in Engine.optionalCodecs { #expect(ids.contains(id), "\(id) missing from \(ids)") }
        #expect(Set(ids).count == ids.count, "duplicate ids: \(ids)")
        #expect(!ids.contains { $0.uppercased().hasPrefix("G729") })
        #expect(codecs.first == CodecInfo(id: "GSM/8000/1", priority: 254))
        #expect(codecs.dropFirst().allSatisfy { $0.priority == 0 })

        let (out, inc) = try await lb.connectedCall("gsm")
        #expect(await lb.call(out)?.codec == "GSM/8000")
        #expect(await lb.call(inc)?.codec == "GSM/8000")
        #expect(await waitUntil {
            let s = try? await engine.mediaStats(out)
            return (s?.rxPackets ?? 0) > 10 && (s?.txPackets ?? 0) > 10
        })
        try await engine.hangup(out)
        #expect(await waitUntil { await engine.calls().isEmpty })

        // Back to the defaults: the 26.2 codecs are off, listed after G.711 in their order.
        try await engine.setCodecPriorities([])
        let defaults = await engine.codecs()
        #expect(defaults.prefix(4).map(\.id) == Engine.defaultCodecOrder)
        #expect(Array(defaults.dropFirst(4).prefix(Engine.optionalCodecs.count).map(\.id)) == Engine.optionalCodecs)
        #expect(defaults.dropFirst(4).allSatisfy { $0.priority == 0 })
        await engine.stop()
    }

    /// The RTP (and RTCP) ports of both legs of a loopback call lie in the configured window;
    /// a new window needs a restart and is used after it.
    @Test func rtpPortsStayInConfiguredWindow() async throws {
        for (start, count) in [(42_000, 10), (43_100, 8)] {
            var net = Self.network
            net.rtpPortStart = start
            net.rtpPortCount = count
            let (lb, consumer) = try await startLoopback(network: net)
            let engine = lb.engine
            let (out, inc) = try await lb.connectedCall("rtp\(start)")
            let ports = [await engine.localRTPPort(of: out), await engine.localRTPPort(of: inc)]
            for p in ports {
                #expect((start...(start + count - 2)).contains(p), "RTP port \(p) outside \(start)+\(count)")
            }
            #expect(Set(ports).count == 2)

            var other = net
            other.keepAliveSeconds = 30
            #expect(try await engine.applyNetworkSettings(other) == .applied)
            other.rtpPortStart = start + 100
            #expect(try await engine.applyNetworkSettings(other) == .needsRestart)

            try await engine.hangup(out)
            #expect(await waitUntil { await engine.calls().isEmpty })
            await engine.stop()
            consumer.cancel()
        }
    }

    /// Via of REGISTER carries ";rport" with `useRport` and not without it; switching applies
    /// to the next request without a restart.
    @Test func rportFollowsSetting() async throws {
        let stub = try NetworkStub()
        defer { stub.stop() }
        let engine = await makeEngine()
        var net = Self.network
        net.useRport = false
        try await engine.start(network: net)
        let account = AccountConfig(displayName: "R", username: "1001", domain: "127.0.0.1",
                                    registrar: "127.0.0.1:\(stub.port)", enabled: true)
        try await engine.addAccount(account, password: "pw")
        #expect(await waitUntil { await engine.registrationState(of: account.id).isRegistered })
        let first = try #require(stub.registers.first)
        #expect(!first.via.lowercased().contains("rport"), "\(first.via)")
        #expect(await engine.rportEnabled() == false)

        net.useRport = true
        #expect(try await engine.applyNetworkSettings(net) == .applied)
        let before = stub.registers.count
        try await engine.setRegistered(account.id, true)
        #expect(await waitUntil { stub.registers.count > before })
        let second = try #require(stub.registers.last)
        #expect(second.via.lowercased().contains(";rport"), "\(second.via)")

        await engine.stop()
        #expect(await engine.rportEnabled() == true)
    }

    /// With DNS SRV on and the DNS stub as nameserver, an account whose registrar is a bare
    /// domain registers at the host and port of `_sip._udp.<domain>`; without SRV there is
    /// no SIP resolver at all.
    @Test func dnsSRVResolvesRegistrar() async throws {
        let sip = try NetworkStub()
        defer { sip.stop() }
        let dns = try DNSStub(records: [
            "_sip._udp.example.test": [.srv(target: "pbx.example.test", port: sip.port)],
            "pbx.example.test": [.a("127.0.0.1")],
        ])
        defer { dns.stop() }

        let plain = await makeEngine()
        try await plain.start(network: Self.network)
        #expect(await plain.resolverState().enabled == false)
        await plain.stop()

        let engine = await makeEngine()
        var net = Self.network
        net.dnsSRV = true
        net.nameserver = "127.0.0.1:\(dns.port)"
        try await engine.start(network: net)
        let state = await engine.resolverState()
        #expect(state.enabled && state.servers == [DNSServer(host: "127.0.0.1", port: dns.port)])

        let account = AccountConfig(displayName: "D", username: "1001", domain: "example.test", enabled: true)
        try await engine.addAccount(account, password: "pw")
        #expect(await waitUntil { await engine.registrationState(of: account.id).isRegistered })
        #expect(dns.queries.contains("SRV _sip._udp.example.test"), "\(dns.queries)")
        #expect(sip.registers.count >= 1)

        // DNS settings need a restart; rport does not.
        var other = net
        other.nameserver = "127.0.0.2"
        #expect(try await engine.applyNetworkSettings(other) == .needsRestart)
        await engine.stop()
    }

    /// Deny rules: "everyone" and "not in contacts" answer 603 Decline, "anonymous" 433
    /// Anonymity Disallowed, before anything rings (no `.incomingCall`, a log line);
    /// the caller sees the same code. A known number and a non-anonymous caller ring.
    @Test func denyIncomingRules() async throws {
        let (lb, consumer) = try await startLoopback(network: Self.network, options: CallOptions(denyIncoming: .everyone))
        defer { consumer.cancel() }
        let engine = lb.engine
        func deniedEnd(after count: Int, code: Int) -> CallInfo? {
            lb.log.all.dropFirst(count).lazy.compactMap { e -> CallInfo? in
                if case let .callEnded(c, _) = e, c.direction == .incoming, case .disconnected(code, _) = c.state { return c }
                return nil
            }.first
        }
        func denyLogs(after count: Int) -> [String] {
            lb.log.all.dropFirst(count).compactMap { if case let .log(_, t) = $0, t.contains(" denied with ") { return t }; return nil }
        }

        // Everyone: 603.
        var mark = lb.log.all.count
        var out = try await lb.dial("a")
        #expect(await waitUntil { deniedEnd(after: mark, code: 603) != nil })
        #expect(await waitUntil { lb.ended { $0.id == out }?.state == .disconnected(code: 603, reason: "Decline") })
        #expect(deniedEnd(after: mark, code: 603)?.state == .disconnected(code: 603, reason: "Decline"))
        #expect(lb.incoming(after: mark) == nil)
        #expect(denyLogs(after: mark).contains { $0.contains("from loop denied with 603 Decline") })

        // Not in contacts: unknown -> 603; known (as the app spells it) -> rings.
        await engine.setCallOptions(CallOptions(denyIncoming: .notInContacts, knownNumbers: ["101", "+375291112233"]))
        mark = lb.log.all.count
        out = try await lb.dial("b")
        #expect(await waitUntil { deniedEnd(after: mark, code: 603) != nil })
        #expect(lb.incoming(after: mark) == nil)
        await engine.setCallOptions(CallOptions(denyIncoming: .notInContacts, knownNumbers: ["LOOP"]))
        mark = lb.log.all.count
        out = try await lb.dial("c")
        #expect(await waitUntil { lb.incoming(after: mark) != nil })
        try await engine.hangup(out)
        #expect(await waitUntil { await engine.calls().isEmpty })

        // Anonymous: a named caller rings; "anonymous" and Privacy: id get 433.
        await engine.setCallOptions(CallOptions(denyIncoming: .anonymous))
        mark = lb.log.all.count
        out = try await lb.dial("d")
        #expect(await waitUntil { lb.incoming(after: mark) != nil })
        try await engine.hangup(out)
        #expect(await waitUntil { await engine.calls().isEmpty })

        let anon = AccountConfig(displayName: "A", username: "anonymous", domain: "127.0.0.1", enabled: false)
        try await engine.addAccount(anon, password: "")
        mark = lb.log.all.count
        out = try await engine.makeCall(to: DialString(uri: "sip:loop@127.0.0.1:\(lb.port)", display: "loop"), from: anon.id)
        #expect(await waitUntil { deniedEnd(after: mark, code: 433) != nil })
        #expect(deniedEnd(after: mark, code: 433)?.state == .disconnected(code: 433, reason: "Anonymity Disallowed"))
        #expect(await waitUntil { lb.ended { $0.id == out }.map { if case .disconnected(433, _) = $0.state { true } else { false } } ?? false })
        #expect(lb.incoming(after: mark) == nil)

        let stub = try NetworkStub()
        defer { stub.stop() }
        for (privacy, expected) in [("Privacy: id", "433"), ("Privacy: none", "")] {
            mark = lb.log.all.count
            let responses = stub.snapshot.responses.count
            stub.sendInvite(toPort: lb.port, user: "loop", fromUser: "200", extraHeaders: [privacy])
            if expected == "433" {
                #expect(await waitUntil { stub.snapshot.responses.dropFirst(responses).contains { $0.hasPrefix("SIP/2.0 433") } })
                #expect(await waitUntil { deniedEnd(after: mark, code: 433)?.remote.number == "200" })
                #expect(lb.incoming(after: mark) == nil)
            } else {
                #expect(await waitUntil { lb.incoming(after: mark)?.remote.number == "200" })
                let ringing = try #require(lb.incoming(after: mark))
                try await engine.reject(ringing.id, code: 486)
            }
        }
        #expect(await waitUntil { await engine.calls().isEmpty })
        await engine.stop()
    }
}
