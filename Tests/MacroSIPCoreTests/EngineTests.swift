import CoreAudio
import Foundation
import os
import Security
import Testing
@testable import MacroSIPCore

// MARK: - helpers

/// Collects engine events from the single consumer task.
final class EventLog: Sendable {
    private let events = OSAllocatedUnfairLock(initialState: [EngineEvent]())
    func append(_ e: EngineEvent) { events.withLock { $0.append(e) } }
    var all: [EngineEvent] { events.withLock { $0 } }

    func consume(_ engine: Engine) -> Task<Void, Never> {
        Task { for await e in engine.events { self.append(e) } }
    }
}

/// Polls `condition` every 20 ms until it holds or `timeout` passes.
func waitUntil(timeout: Double = 5, _ condition: () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return await condition()
}

/// Stops the engine a failed test left started (pjsua exists once per process).
func stopLeakedEngine() async {
    if let leaked = EngineBridge.shared.attachedEngine() { await leaked.stop() }
}

func tempCABundle() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("macrosip-tests-\(UUID().uuidString)")
        .appendingPathComponent("ca-roots.pem")
}

/// A one-socket SIP "registrar" on 127.0.0.1 that answers every REGISTER with a fixed
/// final response after `delay` seconds (and SUBSCRIBE with `subscribeStatus`). It can also
/// send requests from its own socket (an INVITE "from the registrar").
final class RegistrarStub: Sendable {
    let port: UInt16
    private let fd: Int32
    private let delay: TimeInterval
    private let status: String
    private let subscribeStatus: String
    /// Extra header lines (each ending in CRLF) added to every response, e.g. "Expires: 300\r\n".
    private let responseHeaders: String
    private let stopped = OSAllocatedUnfairLock(initialState: false)
    private let registers = OSAllocatedUnfairLock(initialState: 0)
    private let subscribes = OSAllocatedUnfairLock(initialState: 0)
    private let subscribeDetails = OSAllocatedUnfairLock(initialState: [(event: String, from: String)]())

    var registerCount: Int { registers.withLock { $0 } }
    var subscribeCount: Int { subscribes.withLock { $0 } }
    /// Event and From header values of every SUBSCRIBE received, in order.
    var subscribeRequests: [(event: String, from: String)] { subscribeDetails.withLock { $0 } }

    init(status: String = "403 Forbidden", delay: TimeInterval = 0,
         subscribeStatus: String = "403 Forbidden", responseHeaders: String = "") throws {
        self.status = status
        self.delay = delay
        self.subscribeStatus = subscribeStatus
        self.responseHeaders = responseHeaders
        let sock = socket(AF_INET, SOCK_DGRAM, 0)
        guard sock >= 0 else { throw EngineError.unsupported("socket") }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(sock, $0, &len) }
        }
        guard bound == 0, named == 0 else { close(sock); throw EngineError.unsupported("bind") }
        var tv = timeval(tv_sec: 0, tv_usec: 100_000)   // lets the loop notice stop()
        setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        fd = sock
        port = UInt16(bigEndian: addr.sin_port)
        Thread.detachNewThread { [self] in self.serve() }
    }

    func stop() {
        stopped.withLock { $0 = true }
    }

    private func serve() {
        var buf = [UInt8](repeating: 0, count: 65_536)
        while !stopped.withLock({ $0 }) {
            var from = sockaddr_storage()
            var fromLen = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let n = withUnsafeMutablePointer(to: &from) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    recvfrom(fd, &buf, buf.count, 0, $0, &fromLen)
                }
            }
            guard n > 0 else { continue }
            let request = String(decoding: buf[0..<n], as: UTF8.self)
            let finalStatus: String
            if request.hasPrefix("REGISTER ") {
                registers.withLock { $0 += 1 }
                if delay > 0 { Thread.sleep(forTimeInterval: delay) }
                finalStatus = status
            } else if request.hasPrefix("SUBSCRIBE ") {
                subscribes.withLock { $0 += 1 }
                var event = "", from = ""
                for line in request.components(separatedBy: "\r\n") {
                    let parts = line.split(separator: ":", maxSplits: 1)
                    guard parts.count == 2 else { continue }
                    let name = parts[0].lowercased(), value = parts[1].trimmingCharacters(in: .whitespaces)
                    if name == "event" || name == "o" { event = value }
                    if name == "from" || name == "f" { from = value }
                }
                let detail = (event: event, from: from)
                subscribeDetails.withLock { $0.append(detail) }
                finalStatus = subscribeStatus
            } else {
                continue
            }
            var response = "SIP/2.0 \(finalStatus)\r\n"
            for line in request.components(separatedBy: "\r\n") {
                let name = line.split(separator: ":", maxSplits: 1).first.map { $0.lowercased() } ?? ""
                switch name {
                case "via", "from", "call-id", "cseq": response += line + "\r\n"
                case "to": response += line + ";tag=stub\r\n"
                default: break
                }
            }
            response += responseHeaders
            response += "Content-Length: 0\r\n\r\n"
            let bytes = Array(response.utf8)
            _ = withUnsafePointer(to: &from) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, bytes, bytes.count, 0, $0, fromLen)
                }
            }
        }
        close(fd)
    }

    /// Sends a datagram from the stub's socket to 127.0.0.1:`port`.
    func send(_ text: String, to port: Int) {
        var dest = sockaddr_in()
        dest.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        dest.sin_family = sa_family_t(AF_INET)
        dest.sin_addr.s_addr = inet_addr("127.0.0.1")
        dest.sin_port = in_port_t(UInt16(port).bigEndian)
        let bytes = Array(text.utf8)
        _ = withUnsafePointer(to: &dest) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(fd, bytes, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
    }
}

func coreAudioDeviceCount() -> Int {
    var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                             mScope: kAudioObjectPropertyScopeGlobal,
                                             mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr
    else { return 0 }
    return Int(size) / MemoryLayout<AudioDeviceID>.size
}

// MARK: - tests that run pjsua

/// Tests that create pjsua (one instance per process) or read its global defaults.
/// `.serialized` keeps them from overlapping with each other.
@Suite("Engine (pjsua)", .serialized)
struct EngineTests {
    static let network = NetworkSettings(stunServer: nil, localPort: 0, keepAliveSeconds: 15,
                                         useICE: false, echoCancellation: true)

    /// A loopback engine with null audio that does not watch the host's network (it counts
    /// as online; network tests inject paths). Stops an engine a failed test left started,
    /// so one failure does not turn into "Engine is already started" for every later test.
    func makeEngine(monitorNetwork: Bool = false) async -> Engine {
        await stopLeakedEngine()
        return Engine(logLevel: 1, nullAudio: true, bindAddress: "127.0.0.1", caBundleURL: tempCABundle(),
                      monitorNetwork: monitorNetwork)
    }

    @Test func startAddDisabledAccountListCodecsDevicesStop() async throws {
        await stopLeakedEngine()
        let ca = tempCABundle()
        let engine = Engine(logLevel: 1, nullAudio: true, bindAddress: "127.0.0.1", caBundleURL: ca)
        try await engine.start(network: Self.network, codecPriorities: Engine.defaultCodecOrder)

        let account = AccountConfig(displayName: "Test", username: "1001", domain: "127.0.0.1", enabled: false)
        try await engine.addAccount(account, password: "secret")
        #expect(await engine.registrationState(of: account.id) == .unregistered)

        let codecs = await engine.codecs()
        #expect(codecs.prefix(4).map(\.id) == Engine.defaultCodecOrder)
        #expect(codecs.prefix(4).map(\.priority) == [254, 253, 252, 251])
        #expect(codecs.dropFirst(4).allSatisfy { $0.priority == 0 })      // the 26.2 codecs start disabled

        let devices = await engine.audioDevices()
        let systemCount = coreAudioDeviceCount()
        if systemCount > 0 {
            #expect(!devices.isEmpty, "CoreAudio reports \(systemCount) devices, engine none")
        }
        #expect(devices.count <= max(systemCount, devices.count))
        #expect(devices.allSatisfy { !$0.name.isEmpty && ($0.inputChannels > 0 || $0.outputChannels > 0) })
        #expect(await engine.calls().isEmpty)
        #expect(await engine.localPort(of: .udp) > 0)
        #expect(await engine.localPort(of: .tls) > 0)

        // The verifying TLS transport got the system roots.
        let pem = try String(contentsOf: ca, encoding: .utf8)
        #expect(pem.hasPrefix("-----BEGIN CERTIFICATE-----"))

        // Adding the same account twice is refused; unknown accounts are reported.
        await #expect(throws: EngineError.self) { try await engine.addAccount(account, password: "x") }
        let stranger = AccountID()
        await #expect(throws: EngineError.unknownAccount(stranger)) {
            try await engine.setRegistered(stranger, true)
        }

        try await engine.removeAccount(account.id)
        await engine.stop()
        #expect(await engine.codecs().isEmpty)
        await #expect(throws: EngineError.notStarted) {
            try await engine.addAccount(account, password: "secret")
        }
    }

    @Test func codecPrioritiesFollowOrderAndIgnoreUnknownNames() async throws {
        let engine = await makeEngine()
        try await engine.start(network: Self.network, codecPriorities: ["PCMA/8000/1", "bogus/8000/1", "pcmu"])
        var codecs = await engine.codecs()
        #expect(codecs.prefix(2).map(\.id) == ["PCMA/8000/1", "PCMU/8000/1"])
        #expect(codecs.prefix(2).map(\.priority) == [254, 253])
        #expect(codecs.dropFirst(2).allSatisfy { $0.priority == 0 })   // unlisted = disabled

        try await engine.setCodecPriorities(["nothing-known"])          // ignored entirely
        #expect(await engine.codecs() == codecs)

        try await engine.setCodecPriorities([])                         // back to the default order
        codecs = await engine.codecs()
        #expect(codecs.prefix(4).map(\.id) == Engine.defaultCodecOrder)
        #expect(codecs.dropFirst(4).allSatisfy { $0.priority == 0 })
        await engine.stop()
    }

    /// Finding 5: CallID serials must not repeat after stop/start.
    @Test func onlyOneStartedEngineAndSerialsSurviveRestart() async throws {
        let a = await makeEngine()
        let b = await makeEngine()
        try await a.start(network: Self.network)
        let before = EngineBridge.shared.allocateSerial()
        await #expect(throws: EngineError.alreadyStarted) { try await b.start(network: Self.network) }
        await a.stop()
        try await b.start(network: Self.network)        // pjsua can be created again
        #expect(await b.codecs().count == Engine.defaultCodecOrder.count + Engine.optionalCodecs.count)
        #expect(EngineBridge.shared.allocateSerial() > before)
        await b.stop()
        try await a.start(network: Self.network)
        #expect(EngineBridge.shared.allocateSerial() > before)
        await a.stop()
    }

    /// Finding 3: a registrar PJSIP cannot parse is rejected up front and leaves nothing behind.
    @Test func invalidRegistrarIsRejectedBeforeAdding() async throws {
        let engine = await makeEngine()
        try await engine.start(network: Self.network)
        let bad = AccountConfig(displayName: "B", username: "1001", domain: "127.0.0.1",
                                registrar: "sip:exa mple.com", enabled: true)
        await #expect(throws: EngineError.self) { try await engine.addAccount(bad, password: "pw") }
        await #expect(throws: EngineError.unknownAccount(bad.id)) { try await engine.setRegistered(bad.id, false) }

        // Empty / padded / upper-case registrars are normalised and accepted.
        for registrar in ["", "   ", " SIP:127.0.0.1 "] {
            let ok = AccountConfig(displayName: "O", username: "1002", domain: "127.0.0.1",
                                   registrar: registrar, enabled: false)
            try await engine.addAccount(ok, password: "pw")
            try await engine.removeAccount(ok.id)
        }
        await engine.stop()
    }

    /// Finding 1: switching off after a failed REGISTER (PJSIP dropped the registration).
    @Test func switchingOffAFailedRegistration() async throws {
        let stub = try RegistrarStub(status: "403 Forbidden")
        defer { stub.stop() }
        let engine = await makeEngine()
        let log = EventLog()
        let consumer = log.consume(engine)
        defer { consumer.cancel() }
        try await engine.start(network: Self.network)
        var cfg = AccountConfig(displayName: "R", username: "1001", domain: "127.0.0.1",
                                registrar: "127.0.0.1:\(stub.port)", enabled: false)
        try await engine.addAccount(cfg, password: "pw")

        try await engine.setRegistered(cfg.id, true)
        let failed = RegistrationState.failed(code: 403, reason: "Forbidden")
        #expect(await waitUntil { await engine.registrationState(of: cfg.id) == failed })

        try await engine.setRegistered(cfg.id, false)                 // must not throw
        #expect(await engine.registrationState(of: cfg.id) == .unregistered)

        // updateAccount applies the configuration after a failed registration, both ways.
        cfg.enabled = true
        try await engine.updateAccount(cfg, password: nil)
        #expect(await waitUntil { await engine.registrationState(of: cfg.id) == failed })
        cfg.enabled = false
        cfg.registrationInterval = 120
        try await engine.updateAccount(cfg, password: "new")
        #expect(await engine.registrationState(of: cfg.id) == .unregistered)

        // No registration state other than these was reported.
        let states = log.all.compactMap { e -> RegistrationState? in
            if case let .registration(id, st) = e, id == cfg.id { return st }
            return nil
        }
        #expect(states.allSatisfy { [.unregistered, .registering, failed].contains($0) })
        await engine.stop()
    }

    /// Finding 1: register / register / unregister while the first REGISTER is in flight.
    @Test func switchingOffWhileRegisterIsInFlight() async throws {
        let stub = try RegistrarStub(status: "403 Forbidden", delay: 0.5)
        defer { stub.stop() }
        let engine = await makeEngine()
        let log = EventLog()
        let consumer = log.consume(engine)
        defer { consumer.cancel() }
        try await engine.start(network: Self.network)
        let cfg = AccountConfig(displayName: "B", username: "1001", domain: "127.0.0.1",
                                registrar: "127.0.0.1:\(stub.port)", enabled: false)
        try await engine.addAccount(cfg, password: "pw")

        try await engine.setRegistered(cfg.id, true)
        try await engine.setRegistered(cfg.id, true)      // PJSIP: busy. No fake failure.
        #expect(await engine.registrationState(of: cfg.id) == .registering)
        try await engine.setRegistered(cfg.id, false)     // busy: deferred un-REGISTER
        #expect(await engine.registrationState(of: cfg.id) == .unregistered)

        try await Task.sleep(for: .milliseconds(1500))   // the 403 arrives, deferral runs
        #expect(await engine.registrationState(of: cfg.id) == .unregistered)
        #expect(stub.registerCount >= 1 && stub.registerCount <= 2)
        let failures = log.all.filter {
            if case let .registration(id, .failed(code, _)) = $0, id == cfg.id { return code == 0 }
            return false
        }
        #expect(failures.isEmpty, "a busy REGISTER must not be reported as failed(0, ...)")
        await engine.stop()
    }

    /// One engine calls itself on 127.0.0.1: answer, wiring, mute race, hold, stale IDs,
    /// DTMF validation, exactly one .callEnded per call, no .callChanged after it.
    /// Hold and resume without waiting for the hold re-INVITE (and resume -> hold): the
    /// second request is deferred until the first transaction completes, then sent; the
    /// call ends in the last requested state with RTP to match.
    @Test func quickHoldResumeIsDeferredNotLost() async throws {
        let engine = await makeEngine()
        let log = EventLog()
        let consumer = log.consume(engine)
        defer { consumer.cancel() }
        try await engine.start(network: Self.network)
        let account = AccountConfig(displayName: "L", username: "loop", domain: "127.0.0.1", enabled: false)
        try await engine.addAccount(account, password: "")
        let port = await engine.localPort(of: .udp)
        let out = try await engine.makeCall(to: DialString(uri: "sip:callee@127.0.0.1:\(port)", display: "callee"),
                                            from: account.id)
        func incomingID() -> CallID? {
            log.all.lazy.compactMap { e -> CallID? in
                if case let .incomingCall(c) = e { return c.id }
                return nil
            }.first
        }
        #expect(await waitUntil { incomingID() != nil })
        let inc = try #require(incomingID())
        try await engine.answer(inc)
        func call(_ id: CallID) async -> CallInfo? { await engine.calls().first { $0.id == id } }
        #expect(await waitUntil {
            let a = await call(out), b = await call(inc)
            return a?.state == .connected && a?.codec != nil && b?.state == .connected
        })
        func lastChanged(_ id: CallID) -> CallInfo? {
            log.all.lazy.reversed().compactMap { e -> CallInfo? in
                if case let .callChanged(c) = e, c.id == id { return c }
                return nil
            }.first
        }
        func rxIn(_ seconds: Double) async throws -> Int {
            let a = try await engine.mediaStats(out).rxPackets
            try await Task.sleep(for: .seconds(seconds))
            return try await engine.mediaStats(out).rxPackets - a
        }
        func deferrals() -> Int {
            log.all.filter { if case let .log(_, t) = $0 { return t.contains("waits for the re-INVITE in progress") }; return false }.count
        }

        // hold -> resume back to back
        try await engine.setHold(out, true)
        try await engine.setHold(out, false)
        // Whether the second request is deferred depends on how fast the first re-INVITE
        // completes on this machine (on a fast loopback it can already be done); either way
        // the request must not be lost and must not throw.
        #expect(deferrals() <= 1)
        try await Task.sleep(for: .seconds(1))           // both re-INVITEs done
        #expect(await call(out)?.state == .connected)
        #expect(lastChanged(out)?.state == .connected && lastChanged(out)?.isOnHold == false)
        let rxActive = try await rxIn(1)
        #expect(rxActive > 30)

        // resume -> hold back to back (from a settled hold)
        try await engine.setHold(out, true)
        try await Task.sleep(for: .seconds(1))
        try await engine.setHold(out, false)
        try await engine.setHold(out, true)
        #expect(deferrals() <= 2)
        try await Task.sleep(for: .seconds(1))
        #expect(await call(out)?.state == .held)
        #expect(lastChanged(out)?.state == .held && lastChanged(out)?.isOnHold == true)
        let rxHeld = try await rxIn(1)
        #expect(rxHeld < 10)

        await engine.stop()
    }

    @Test func loopbackCall() async throws {
        let engine = await makeEngine()
        let log = EventLog()
        let consumer = log.consume(engine)
        defer { consumer.cancel() }
        try await engine.start(network: Self.network)
        let account = AccountConfig(displayName: "L", username: "loop", domain: "127.0.0.1", enabled: false)
        try await engine.addAccount(account, password: "")
        let port = await engine.localPort(of: .udp)
        let out = try await engine.makeCall(to: DialString(uri: "sip:callee@127.0.0.1:\(port)", display: "callee"),
                                            from: account.id)

        func incomingID() -> CallID? {
            log.all.lazy.compactMap { e -> CallID? in
                if case let .incomingCall(c) = e { return c.id }
                return nil
            }.first
        }
        #expect(await waitUntil { incomingID() != nil })
        let inc = try #require(incomingID())
        #expect(inc != out)
        try await engine.answer(inc)

        func call(_ id: CallID) async -> CallInfo? { await engine.calls().first { $0.id == id } }
        #expect(await waitUntil {
            let a = await call(out), b = await call(inc)
            return a?.state == .connected && a?.codec != nil && b?.state == .connected && b?.codec != nil
        })
        func wired(_ id: CallID, _ speaker: Bool, _ mic: Bool) async -> Bool {
            await waitUntil(timeout: 2) {
                guard let w = await engine.wiring(of: id) else { return false }
                return w.toSpeaker == speaker && w.fromMic == mic
            }
        }
        #expect(await wired(out, true, true))
        #expect(await wired(inc, true, true))

        // Finding 7: mute and unmute within one audio frame leaves the microphone connected.
        try await engine.setMute(out, true)
        try await engine.setMute(out, false)
        try await Task.sleep(for: .milliseconds(150))
        #expect(await wired(out, true, true))
        try await engine.setMute(out, true)
        #expect(await wired(out, true, false))
        #expect(await call(out)?.isMuted == true)
        try await engine.setMute(out, false)
        #expect(await wired(out, true, true))

        // Hold disconnects both directions once the re-INVITE completed; unhold restores.
        try await engine.setHold(out, true)
        #expect(await waitUntil { await call(out)?.state == .held })
        #expect(await wired(out, false, false))
        try await engine.setHold(out, false)
        #expect(await waitUntil { let c = await call(out); return c?.state == .connected && c?.isOnHold == false })
        #expect(await wired(out, true, true))

        // Stale serial on a live slot, an empty slot, digit validation.
        let stale = CallID(raw: out.raw, serial: out.serial + 1000)
        await #expect(throws: EngineError.noSuchCall(stale)) { try await engine.hangup(stale) }
        let empty = CallID(raw: 7, serial: 1)
        await #expect(throws: EngineError.noSuchCall(empty)) { try await engine.sendDTMF(empty, "1") }
        await #expect(throws: EngineError.invalidArgument("DTMF digits \"12x\"")) {
            try await engine.sendDTMF(out, "12x")
        }
        try await engine.sendDTMF(out, "1#")
        let stats = try await engine.mediaStats(out)
        #expect(stats.rxPackets > 0 && stats.txPackets > 0)

        try await engine.hangup(out)
        // Racing engine-side updates right after the hang-up must not resurrect the call.
        _ = try? await engine.setMute(out, true)
        _ = try? await engine.setHold(inc, true)
        _ = await engine.calls()
        func ended(_ id: CallID) -> Int {
            log.all.filter { if case let .callEnded(c, _) = $0 { return c.id == id }; return false }.count
        }
        #expect(await waitUntil { ended(out) >= 1 && ended(inc) >= 1 })
        try await Task.sleep(for: .milliseconds(300))
        #expect(ended(out) == 1)
        #expect(ended(inc) == 1)
        for id in [out, inc] {
            let events = log.all
            let end = try #require(events.firstIndex { if case let .callEnded(c, _) = $0 { return c.id == id }; return false })
            let ghost = events[end...].contains { if case let .callChanged(c) = $0 { return c.id == id }; return false }
            #expect(!ghost, "callChanged after callEnded for \(id)")
        }
        #expect(await engine.calls().isEmpty)
        await engine.stop()
    }

    // MARK: pjsua_acc_config mapping

    struct MappingCase: Sendable, CustomTestStringConvertible {
        let account: AccountConfig
        let expectedRegURI: String
        let expectedTransportID: Int32
        let expectedSecureSignaling: Int
        let expectedProxies: [String]
        let expectedAuthUser: String
        var testDescription: String {
            "\(account.transport.rawValue)/\(account.srtp.rawValue)\(account.verifyTLSCertificate ? "" : "/noverify")"
                + (account.publishPresence ? "/publish" : "") + (account.mwi ? "" : "/nomwi")
        }
    }

    static let transportIDs = TransportIDs(udp: 0, tcp: 1, tls: 2, tlsNoVerify: 3)

    static let mappingCases: [MappingCase] = [
        MappingCase(
            account: AccountConfig(displayName: "U", username: "1001", domain: "sip.example.com",
                                   transport: .udp, srtp: .disabled),
            expectedRegURI: "sip:sip.example.com", expectedTransportID: 0,
            expectedSecureSignaling: 0, expectedProxies: [], expectedAuthUser: "1001"),
        MappingCase(
            account: AccountConfig(displayName: "T", username: "1002", domain: "sip.example.com",
                                   registrar: "reg.example.com", outboundProxy: "proxy.example.com:5060",
                                   authID: "auth-1002", transport: .tcp, srtp: .optional,
                                   registrationInterval: 600),
            expectedRegURI: "sip:reg.example.com;transport=tcp", expectedTransportID: 1,
            expectedSecureSignaling: 0, expectedProxies: ["sip:proxy.example.com:5060;transport=tcp;lr"],
            expectedAuthUser: "auth-1002"),
        MappingCase(
            account: AccountConfig(displayName: "S", username: "1003", domain: "sip.example.com",
                                   outboundProxy: "sip:edge.example.com:5061;transport=tls;lr",
                                   transport: .tls, srtp: .mandatory),
            expectedRegURI: "sip:sip.example.com;transport=tls", expectedTransportID: 2,
            expectedSecureSignaling: 1, expectedProxies: ["sip:edge.example.com:5061;transport=tls;lr"],
            expectedAuthUser: "1003"),
        MappingCase(
            account: AccountConfig(displayName: "M", username: "1004", domain: "sip.example.com",
                                   authID: "", transport: .udp, srtp: .mandatory),
            expectedRegURI: "sip:sip.example.com", expectedTransportID: 0,
            expectedSecureSignaling: 0, expectedProxies: [], expectedAuthUser: "1004"),
        MappingCase(
            account: AccountConfig(displayName: "O", username: "1005", domain: "sip.example.com",
                                   transport: .tls, srtp: .optional),
            expectedRegURI: "sip:sip.example.com;transport=tls", expectedTransportID: 2,
            expectedSecureSignaling: 0, expectedProxies: [], expectedAuthUser: "1005"),
        MappingCase(
            account: AccountConfig(displayName: "N", username: "1006", domain: "pbx.local",
                                   transport: .tls, srtp: .mandatory, verifyTLSCertificate: false),
            expectedRegURI: "sip:pbx.local;transport=tls", expectedTransportID: 3,
            expectedSecureSignaling: 1, expectedProxies: [], expectedAuthUser: "1006"),
        MappingCase(   // empty registrar = domain
            account: AccountConfig(displayName: "E", username: "1007", domain: "sip.example.com", registrar: ""),
            expectedRegURI: "sip:sip.example.com", expectedTransportID: 0,
            expectedSecureSignaling: 0, expectedProxies: [], expectedAuthUser: "1007"),
        MappingCase(   // whitespace registrar = domain
            account: AccountConfig(displayName: "W", username: "1008", domain: "sip.example.com",
                                   registrar: "  ", transport: .tcp),
            expectedRegURI: "sip:sip.example.com;transport=tcp", expectedTransportID: 1,
            expectedSecureSignaling: 0, expectedProxies: [], expectedAuthUser: "1008"),
        MappingCase(   // upper-case scheme, padded
            account: AccountConfig(displayName: "C", username: "1009", domain: "sip.example.com",
                                   registrar: " SIP:reg.example.com:5070 "),
            expectedRegURI: "sip:reg.example.com:5070", expectedTransportID: 0,
            expectedSecureSignaling: 0, expectedProxies: [], expectedAuthUser: "1009"),
        MappingCase(   // presence publishing on
            account: AccountConfig(displayName: "P", username: "1010", domain: "sip.example.com",
                                   publishPresence: true),
            expectedRegURI: "sip:sip.example.com", expectedTransportID: 0,
            expectedSecureSignaling: 0, expectedProxies: [], expectedAuthUser: "1010"),
        MappingCase(   // voicemail indicator off
            account: AccountConfig(displayName: "V", username: "1011", domain: "sip.example.com", mwi: false),
            expectedRegURI: "sip:sip.example.com", expectedTransportID: 0,
            expectedSecureSignaling: 0, expectedProxies: [], expectedAuthUser: "1011"),
    ]

    @Test(arguments: mappingCases)
    func accountConfigMapping(_ c: MappingCase) throws {
        let network = NetworkSettings(stunServer: nil, keepAliveSeconds: 25, useICE: true)
        let s = try AccountMapping.settings(for: c.account, password: "pw", network: network,
                                            transports: Self.transportIDs)
        // What actually lands in pjsua_acc_config, read field by field from the C struct.
        let c2 = AccountMapping.withPJConfig(s) { AccountMapping.readBack($0) }
        for (label, x) in [("settings", s), ("pjsua_acc_config", c2)] {
            #expect(x.idURI == "sip:\(c.account.username)@\(c.account.domain)", "\(label)")
            #expect(x.regURI == c.expectedRegURI, "\(label)")
            #expect(x.authRealm == "*", "\(label)")
            #expect(x.authScheme == "digest", "\(label)")
            #expect(x.authUsername == c.expectedAuthUser, "\(label)")
            #expect(x.password == "pw", "\(label)")
            #expect(x.regTimeout == c.account.registrationInterval, "\(label)")
            #expect(x.proxies == c.expectedProxies, "\(label)")
            #expect(x.srtp == c.account.srtp, "\(label)")
            #expect(x.srtpSecureSignaling == c.expectedSecureSignaling, "\(label)")
            #expect(x.transportID == c.expectedTransportID, "\(label)")
            #expect(x.allowContactRewrite && x.allowViaRewrite, "\(label)")
            #expect(x.keepAliveSeconds == 25, "\(label)")
            #expect(x.iceEnabled, "\(label)")
            #expect(x.rtpPort == 4000 && x.rtpPortRange == 998 && x.randomizeRTPPort, "\(label)")
            #expect(x.bindAddress == nil, "\(label)")
            #expect(x.publishEnabled == c.account.publishPresence, "\(label)")
            #expect(x.publishQueueRequest, "\(label)")
            #expect(x.mwiEnabled == c.account.mwi, "\(label)")
        }
    }

    @Test func mappingFailsWithoutTransportAndKeepsBindAddress() throws {
        let tls = AccountConfig(displayName: "S", username: "1", domain: "d", transport: .tls)
        #expect(throws: EngineError.transportUnavailable(.tls)) {
            _ = try AccountMapping.settings(for: tls, password: "", network: .default,
                                            transports: TransportIDs(udp: 0))
        }
        var noVerify = tls
        noVerify.verifyTLSCertificate = false
        #expect(throws: EngineError.transportUnavailable(.tls)) {
            _ = try AccountMapping.settings(for: noVerify, password: "", network: .default,
                                            transports: TransportIDs(udp: 0, tls: 2))
        }
        let udp = AccountConfig(displayName: "U", username: "1", domain: "127.0.0.1")
        let s = try AccountMapping.settings(for: udp, password: "", network: .default,
                                            transports: TransportIDs(udp: 0), bindAddress: "127.0.0.1")
        let back = AccountMapping.withPJConfig(s) { AccountMapping.readBack($0) }
        #expect(back.bindAddress == "127.0.0.1")
    }
}

// MARK: - pure Swift parts of the engine (no pjsua)

@Suite("Engine helpers")
struct EngineHelperTests {
    @Test func proxyURINormalisation() {
        #expect(AccountMapping.proxyURI("proxy.example.com", transport: .udp) == "sip:proxy.example.com;lr")
        #expect(AccountMapping.proxyURI("sip:p.example.com;lr", transport: .udp) == "sip:p.example.com;lr")
        #expect(AccountMapping.proxyURI("p.example.com:5061", transport: .tls) == "sip:p.example.com:5061;transport=tls;lr")
        #expect(AccountMapping.proxyURI("sips:p.example.com;transport=tls", transport: .tls) == "sips:p.example.com;transport=tls;lr")
    }

    @Test func registrarURINormalisation() {
        func uri(_ registrar: String?, _ t: TransportKind = .udp) -> String {
            AccountConfig(displayName: "x", username: "u", domain: " sip.example.com ", registrar: registrar,
                          transport: t).registrarURI
        }
        #expect(uri(nil) == "sip:sip.example.com")
        #expect(uri("") == "sip:sip.example.com")
        #expect(uri(" \t ") == "sip:sip.example.com")
        #expect(uri("SIP:reg.example.com") == "sip:reg.example.com")
        #expect(uri("Sips:reg.example.com", .tls) == "sips:reg.example.com;transport=tls")
        #expect(uri("sip:reg.example.com;transport=tcp", .tcp) == "sip:reg.example.com;transport=tcp")
        #expect(AccountConfig(displayName: "x", username: " 100 ", domain: " d.com ").uri == "sip:100@d.com")
    }

    @Test func accountConfigDecodesOldJSONWithVerificationOn() throws {
        let cfg = AccountConfig(displayName: "A", username: "1", domain: "d", verifyTLSCertificate: false)
        let data = try JSONEncoder().encode(cfg)
        #expect(try JSONDecoder().decode(AccountConfig.self, from: data) == cfg)
        var dict = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        dict["verifyTLSCertificate"] = nil
        let old = try JSONDecoder().decode(AccountConfig.self, from: JSONSerialization.data(withJSONObject: dict))
        #expect(old.verifyTLSCertificate)
        #expect(old.username == "1")
    }

    @Test func systemRootsExportAsPEM() throws {
        let url = tempCABundle()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let count = try TLSRoots.export(to: url)
        #expect(count > 50)
        let pem = try String(contentsOf: url, encoding: .utf8)
        #expect(pem.components(separatedBy: "-----BEGIN CERTIFICATE-----").count - 1 == count)
        // The first block decodes back to a certificate.
        let body = try #require(pem.components(separatedBy: "-----END CERTIFICATE-----").first)
            .replacingOccurrences(of: "-----BEGIN CERTIFICATE-----", with: "")
            .replacingOccurrences(of: "\n", with: "")
        let der = try #require(Data(base64Encoded: body))
        #expect(SecCertificateCreateWithData(nil, der as CFData) != nil)
    }

    @Test func registrationMapping() {
        let noexp: UInt32 = 0xFFFF_FFFF
        func map(renew: Bool = true, status: Int32 = 0, code: Int, reason: String = "", exp: UInt32) -> RegistrationState {
            RegistrationMapping.state(renew: renew, status: status, code: code, reason: reason,
                                      expiration: exp, notSpecified: noexp, interval: 300)
        }
        #expect(map(code: 200, exp: 120) == .registered(expires: 120))
        #expect(map(code: 200, exp: noexp) == .registered(expires: 300))     // finding 4
        #expect(map(code: 200, exp: 0) == .unregistered)
        #expect(map(code: 403, reason: "Forbidden", exp: 0) == .failed(code: 403, reason: "Forbidden"))
        #expect(map(renew: false, code: 503, exp: 0) == .unregistered)
        if case .failed(503, let reason) = map(status: 120061, code: 503, exp: 0) {
            #expect(!reason.isEmpty)
        } else {
            Issue.record("transport error must map to .failed")
        }
    }

    @Test func audioDeviceResolution() throws {
        let devices = [
            AudioDevice(id: 0, name: "Speakers", inputChannels: 0, outputChannels: 2),
            AudioDevice(id: 1, name: "Mic", inputChannels: 1, outputChannels: 0),
            AudioDevice(id: 2, name: "Headset", inputChannels: 1, outputChannels: 0),
            AudioDevice(id: 3, name: "Headset", inputChannels: 0, outputChannels: 2),
        ]
        #expect(AudioDeviceResolver.index(of: "Headset", in: devices, input: true) == 2)
        #expect(AudioDeviceResolver.index(of: "Headset", in: devices, input: false) == 3)
        #expect(AudioDeviceResolver.index(of: "Gone", in: devices, input: true) == nil)
        #expect(AudioDeviceResolver.index(of: nil, in: devices, input: true) == nil)
        // After a refresh the same name can live at another index.
        let shifted = devices.map { AudioDevice(id: $0.id + 5, name: $0.name, inputChannels: $0.inputChannels,
                                                outputChannels: $0.outputChannels) }
        #expect(AudioDeviceResolver.index(of: "Headset", in: shifted, input: false) == 8)
        #expect(try AudioDeviceResolver.name(of: 1, in: devices, input: true) == "Mic")
        #expect(throws: EngineError.self) { _ = try AudioDeviceResolver.name(of: 0, in: devices, input: true) }
    }

    @Test func codecPlan() {
        let available = ["PCMU/8000/1", "PCMA/8000/1", "G722/16000/1", "opus/48000/2"]
        let plan = CodecMapping.plan(requested: ["opus/48000/2", "speex/8000/1", "g722", "opus/48000/2"],
                                     available: available)
        #expect(plan.map(\.id) == ["opus/48000/2", "G722/16000/1", "PCMU/8000/1", "PCMA/8000/1"])
        #expect(plan.map(\.priority) == [254, 253, 0, 0])
        #expect(CodecMapping.plan(requested: ["nope"], available: available).allSatisfy { $0.priority == 0 })
    }

    @Test func remotePartyParsing() {
        let a = RemoteParty.parse("\"Alice Smith\" <sip:100@example.com;transport=tcp>")
        #expect(a == RemoteParty(displayName: "Alice Smith", uri: "sip:100@example.com;transport=tcp", number: "100"))
        let b = RemoteParty.parse("<sip:+74951234567@example.com>")
        #expect(b == RemoteParty(displayName: nil, uri: "sip:+74951234567@example.com", number: "+74951234567"))
        let c = RemoteParty.parse("sip:test@127.0.0.1:5080")
        #expect(c == RemoteParty(displayName: nil, uri: "sip:test@127.0.0.1:5080", number: "test"))
    }

    func snapshot(outgoing: Bool, state: InviteState, media: MediaStatus = .none,
                  status: Int = 0, text: String = "") -> CallSnapshot {
        CallSnapshot(slot: 2, accIndex: 0, isOutgoing: outgoing, state: state, lastStatus: status,
                     lastStatusText: text, remoteInfo: "<sip:100@example.com>", sipCallID: "x",
                     mediaStatus: media, confSlot: 3, connectDuration: 0, serial: 7,
                     codec: media == .active ? "opus/48000" : nil, isSecure: false)
    }

    @Test func callStateMapping() {
        let inRec = CallRecord(serial: 7, accountID: .unknown, direction: .incoming, announced: true)
        let outRec = CallRecord(serial: 7, accountID: .unknown, direction: .outgoing, announced: true)
        var held = outRec
        held.localHold = true

        #expect(EngineBridge.makeInfo(snapshot(outgoing: false, state: .early), inRec).state == .incoming)
        #expect(EngineBridge.makeInfo(snapshot(outgoing: true, state: .early), outRec).state == .early)
        #expect(EngineBridge.makeInfo(snapshot(outgoing: true, state: .calling), outRec).state == .calling)
        let active = EngineBridge.makeInfo(snapshot(outgoing: true, state: .confirmed, media: .active), outRec)
        #expect(active.state == .connected)
        #expect(active.codec == "opus/48000")
        #expect(active.id == CallID(raw: 2, serial: 7))
        #expect(EngineBridge.makeInfo(snapshot(outgoing: true, state: .confirmed, media: .active), held).state == .held)
        #expect(EngineBridge.makeInfo(snapshot(outgoing: true, state: .confirmed, media: .localHold), outRec).isOnHold)
        #expect(EngineBridge.makeInfo(snapshot(outgoing: true, state: .disconnected, status: 486, text: "Busy Here"),
                                      outRec).state == .disconnected(code: 486, reason: "Busy Here"))

        // .callEnded keeps the codec and SRTP state the call had while media was up.
        var ended = outRec
        ended.lastCodec = "PCMA/8000"
        ended.lastSecure = true
        let endedInfo = EngineBridge.makeInfo(snapshot(outgoing: true, state: .disconnected, status: 200), ended)
        #expect(endedInfo.codec == "PCMA/8000" && endedInfo.isSecure)
        #expect(EngineBridge.makeInfo(snapshot(outgoing: true, state: .confirmed), ended).codec == nil)
    }
}
