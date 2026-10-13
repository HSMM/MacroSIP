import AVFoundation
import Foundation
import os
import Testing
@testable import MacroSIPCore

// Milestone 5: conference, recording, presence, Call-Info answer-after.

/// The 44-byte PCM WAV header pjmedia's WAV writer produces.
struct WAVHeader: Equatable {
    var riffSize: UInt32
    var channels: UInt16
    var sampleRate: UInt32
    var bitsPerSample: UInt16
    var dataSize: UInt32
    var fileSize: Int

    static func read(_ url: URL) -> WAVHeader? {
        guard let data = try? Data(contentsOf: url), data.count >= 44,
              data[0..<4] == Data("RIFF".utf8), data[8..<12] == Data("WAVE".utf8),
              data[12..<16] == Data("fmt ".utf8), data[36..<40] == Data("data".utf8) else { return nil }
        func u32(_ o: Int) -> UInt32 { (0..<4).reduce(0) { $0 | UInt32(data[o + $1]) << (8 * UInt32($1)) } }
        func u16(_ o: Int) -> UInt16 { UInt16(data[o]) | UInt16(data[o + 1]) << 8 }
        return WAVHeader(riffSize: u32(4), channels: u16(22), sampleRate: u32(24), bitsPerSample: u16(34),
                         dataSize: u32(40), fileSize: data.count)
    }

    /// Sizes written by the writer's on_destroy match the file.
    var isFinal: Bool {
        dataSize > 0 && Int(dataSize) == fileSize - 44 && Int(riffSize) == fileSize - 8
    }
}

/// RMS of a 16-bit PCM WAV's samples (after the 44-byte header).
func wavRMS(_ url: URL) throws -> Int {
    let data = try Data(contentsOf: url)
    var sum = 0.0
    var n = 0
    var i = 44
    while i + 1 < data.count {
        let v = Double(Int16(bitPattern: UInt16(data[i]) | UInt16(data[i + 1]) << 8))
        sum += v * v
        n += 1
        i += 2
    }
    return n > 0 ? Int((sum / Double(n)).squareRoot()) : 0
}

func tempWAV(_ name: String) -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("macrosip-tests-\(UUID().uuidString)")
        .appendingPathComponent("sub dir")          // created by startRecording
        .appendingPathComponent(name)
}

/// Sends one UDP datagram from 127.0.0.1 (an ephemeral port) to `port`.
func sendUDP(_ text: (UInt16) -> String, to port: Int) throws {
    let sock = socket(AF_INET, SOCK_DGRAM, 0)
    guard sock >= 0 else { throw EngineError.unsupported("socket") }
    defer { close(sock) }
    var local = sockaddr_in()
    local.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    local.sin_family = sa_family_t(AF_INET)
    local.sin_addr.s_addr = inet_addr("127.0.0.1")
    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
    let ok = withUnsafeMutablePointer(to: &local) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(sock, $0, len) == 0 && getsockname(sock, $0, &len) == 0
        }
    }
    guard ok else { throw EngineError.unsupported("bind") }
    var dest = local
    dest.sin_port = in_port_t(UInt16(port).bigEndian)
    let bytes = Array(text(UInt16(bigEndian: local.sin_port)).utf8)
    let sent = withUnsafePointer(to: &dest) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            sendto(sock, bytes, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard sent == bytes.count else { throw EngineError.unsupported("sendto") }
}

/// A presence server on 127.0.0.1: accepts one SUBSCRIBE (200) and sends NOTIFYs with the
/// PIDF bodies the test asks for, in that subscription's dialog.
final class PresenceStub: Sendable {
    let port: UInt16
    private let fd: Int32
    private let stopped = OSAllocatedUnfairLock(initialState: false)
    /// From the SUBSCRIBE: (from, to, callID, contact URI, subscriber address port).
    private let dialog = OSAllocatedUnfairLock<(from: String, to: String, callID: String, target: String, peer: UInt16)?>(initialState: nil)
    private let cseq = OSAllocatedUnfairLock(initialState: 0)

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

    var subscribed: Bool { dialog.withLock { $0 != nil } }

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
            let request = String(decoding: buf[0..<n], as: UTF8.self)
            guard request.hasPrefix("SUBSCRIBE ") else { continue }
            var headers: [String: String] = [:]
            var response = "SIP/2.0 200 OK\r\n"
            for line in request.components(separatedBy: "\r\n") {
                guard let colon = line.firstIndex(of: ":") else { continue }
                let name = line[..<colon].lowercased()
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                if headers[name] == nil { headers[name] = value }
                switch name {
                case "via", "from", "call-id", "cseq": response += line + "\r\n"
                case "to": response += line + ";tag=pres\r\n"
                default: break
                }
            }
            response += "Contact: <sip:buddy@127.0.0.1:\(port)>\r\nExpires: 600\r\nContent-Length: 0\r\n\r\n"
            send(response, to: UInt16(bigEndian: from.sin_port))
            var target = headers["contact"] ?? ""
            if let lt = target.firstIndex(of: "<"), let gt = target.firstIndex(of: ">") {
                target = String(target[target.index(after: lt)..<gt])
            }
            let d = (from: headers["from"] ?? "", to: (headers["to"] ?? "") + ";tag=pres",
                     callID: headers["call-id"] ?? "", target: target, peer: UInt16(bigEndian: from.sin_port))
            dialog.withLock { $0 = d }
        }
        close(fd)
    }

    /// NOTIFY in the subscription's dialog with an Asterisk-style PIDF body.
    func notify(activity: String?, note: String?, open: Bool = true) {
        guard let d = dialog.withLock({ $0 }) else { return }
        let n = cseq.withLock { $0 += 1; return $0 }
        var body = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
            + "<presence entity=\"sip:buddy@127.0.0.1\" xmlns=\"urn:ietf:params:xml:ns:pidf\" "
            + "xmlns:dm=\"urn:ietf:params:xml:ns:pidf:data-model\" xmlns:rpid=\"urn:ietf:params:xml:ns:pidf:rpid\">\n"
        if let note { body += " <note>\(note)</note>\n" }
        body += " <tuple id=\"buddy\"><status><basic>\(open ? "open" : "closed")</basic></status>"
            + "<contact priority=\"1\">sip:buddy@127.0.0.1</contact></tuple>\n"
        if let activity { body += " <dm:person><rpid:activities><rpid:\(activity)/></rpid:activities></dm:person>\n" }
        body += "</presence>\n"
        let msg = "NOTIFY \(d.target) SIP/2.0\r\n"
            + "Via: SIP/2.0/UDP 127.0.0.1:\(port);rport;branch=z9hG4bK-notify-\(n)-\(UUID().uuidString.prefix(8))\r\n"
            + "Max-Forwards: 70\r\n"
            + "From: \(d.to)\r\nTo: \(d.from)\r\nCall-ID: \(d.callID)\r\nCSeq: \(n) NOTIFY\r\n"
            + "Contact: <sip:buddy@127.0.0.1:\(port)>\r\nEvent: presence\r\n"
            + "Subscription-State: active;expires=600\r\nContent-Type: application/pidf+xml\r\n"
            + "Content-Length: \(body.utf8.count)\r\n\r\n" + body
        send(msg, to: d.peer)
    }

    private func send(_ text: String, to port: UInt16) {
        var dest = sockaddr_in()
        dest.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        dest.sin_family = sa_family_t(AF_INET)
        dest.sin_addr.s_addr = inet_addr("127.0.0.1")
        dest.sin_port = in_port_t(port.bigEndian)
        let bytes = Array(text.utf8)
        _ = withUnsafePointer(to: &dest) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(fd, bytes, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
    }
}

// MARK: - tests that run pjsua (part of the serialized "Engine (pjsua)" suite)

extension EngineTests {
    /// Two loopback calls on one engine (four legs): merge (resuming a held leg), per-leg
    /// hold and mute inside the conference, recording with conference partners, split,
    /// a leg ending, and the automatic stop of a recording when its call ends.
    @Test func loopbackConferenceAndRecording() async throws {
        let engine = await makeEngine()
        let log = EventLog()
        // `.callEnded` of a recorded call must refer to a finished WAV: read the header the
        // moment the event arrives.
        let headersAtEnd = OSAllocatedUnfairLock(initialState: [CallID: WAVHeader?]())
        let recordingURLs = OSAllocatedUnfairLock(initialState: [CallID: URL]())
        let consumer = Task {
            for await e in engine.events {
                if case let .callEnded(c, _) = e, c.isRecording, let url = recordingURLs.withLock({ $0[c.id] }) {
                    let header = WAVHeader.read(url)
                    headersAtEnd.withLock { $0[c.id] = header }
                }
                log.append(e)
            }
        }
        defer { consumer.cancel() }
        try await engine.start(network: Self.network)
        let account = AccountConfig(displayName: "L", username: "loop", domain: "127.0.0.1", enabled: false)
        try await engine.addAccount(account, password: "")
        let port = await engine.localPort(of: .udp)

        func incomingIDs() -> [CallID] {
            log.all.compactMap { if case let .incomingCall(c) = $0 { return c.id }; return nil }
        }
        func call(_ id: CallID) async -> CallInfo? { await engine.calls().first { $0.id == id } }
        func connected(_ ids: [CallID]) async -> Bool {
            for id in ids {
                guard let c = await call(id), c.state == .connected, c.codec != nil else { return false }
            }
            return true
        }
        func linked(_ a: CallID, _ b: CallID, _ on: Bool) async -> Bool {
            await waitUntil(timeout: 2) {
                let ab = await engine.isConnected(from: a, to: b)
                let ba = await engine.isConnected(from: b, to: a)
                return ab == on && ba == on
            }
        }
        func wired(_ id: CallID, _ speaker: Bool, _ mic: Bool) async -> Bool {
            await waitUntil(timeout: 2) {
                guard let w = await engine.wiring(of: id) else { return false }
                return w.toSpeaker == speaker && w.fromMic == mic
            }
        }

        // Call 1, then hold it (the UI holds the active call before dialling the next one).
        let out1 = try await engine.makeCall(to: DialString(uri: "sip:a@127.0.0.1:\(port)", display: "a"),
                                             from: account.id)
        #expect(await waitUntil { incomingIDs().count == 1 })
        let inc1 = try #require(incomingIDs().first)
        try await engine.answer(inc1)
        #expect(await waitUntil { await connected([out1, inc1]) })
        try await engine.setHold(out1, true)
        #expect(await waitUntil { await call(out1)?.state == .held })

        // Call 2.
        let out2 = try await engine.makeCall(to: DialString(uri: "sip:b@127.0.0.1:\(port)", display: "b"),
                                             from: account.id)
        #expect(await waitUntil { incomingIDs().count == 2 })
        let inc2 = try #require(incomingIDs().last)
        try await engine.answer(inc2)
        #expect(await waitUntil { await connected([out2, inc2]) })

        // Argument checks.
        await #expect(throws: EngineError.invalidArgument("merge needs at least two calls")) {
            try await engine.merge([out1, out1])
        }
        let stale = CallID(raw: out2.raw, serial: out2.serial + 1000)
        await #expect(throws: EngineError.noSuchCall(stale)) { try await engine.merge([out1, stale]) }
        await #expect(throws: EngineError.invalidArgument("call \(out1) is not in a conference")) {
            try await engine.split(out1)
        }
        await #expect(throws: EngineError.self) {
            try await engine.startRecording(out1, to: URL(fileURLWithPath: "/tmp/x.mp4"))
        }

        // Merge resumes the held leg and links both legs both ways.
        try await engine.merge([out1, out2])
        #expect(await waitUntil {
            let a = await call(out1), b = await call(out2)
            return a?.state == .connected && a?.inConference == true && b?.inConference == true
        })
        #expect(await call(inc1)?.inConference == false)
        #expect(await linked(out1, out2, true))
        #expect(await wired(out1, true, true))
        #expect(await wired(out2, true, true))
        #expect(log.all.contains { if case let .callChanged(c) = $0 { return c.id == out2 && c.inConference }; return false })

        // Mute cuts only the microphone; the other leg still reaches the muted one.
        try await engine.setMute(out1, true)
        #expect(await wired(out1, true, false))
        #expect(await linked(out1, out2, true))

        // Hold cuts a leg off from everything; resume brings it back.
        try await engine.setHold(out2, true)
        #expect(await waitUntil { await call(out2)?.state == .held })
        #expect(await linked(out1, out2, false))
        #expect(await wired(out2, false, false))
        #expect(await call(out2)?.inConference == true)
        try await engine.setHold(out2, false)
        #expect(await waitUntil { await call(out2)?.state == .connected })
        #expect(await linked(out1, out2, true))
        #expect(await wired(out2, true, true))

        // Recording a conference leg: its call, the partner leg, the microphone unless muted.
        let wav1 = tempWAV("conference.wav")
        try await engine.startRecording(out1, to: wav1)
        #expect(await call(out1)?.isRecording == true)
        #expect(await call(out2)?.isRecording == false)
        await #expect(throws: EngineError.invalidArgument("call \(out1) is already being recorded")) {
            try await engine.startRecording(out1, to: wav1)
        }
        #expect(await waitUntil(timeout: 2) {
            let own = await engine.recorderHears(out1, from: out1)
            let partner = await engine.recorderHears(out1, from: out2)
            let mic = await engine.recorderHears(out1, from: nil)
            return own && partner && !mic
        })
        try await engine.setMute(out1, false)
        #expect(await waitUntil(timeout: 2) { await engine.recorderHears(out1, from: nil) })
        try await Task.sleep(for: .milliseconds(600))
        let stopped = try await engine.stopRecording(out1)
        #expect(stopped == RecordingFiles(layout: .mono, mixed: wav1))
        let header = try #require(WAVHeader.read(wav1))
        #expect(header.isFinal, "\(header)")
        #expect(header.channels == 1 && header.bitsPerSample == 16 && header.sampleRate == 16000)
        #expect(header.dataSize >= 16000)          // >= 0.5 s at 16 kHz, 16 bit
        #expect(await call(out1)?.isRecording == false)
        await #expect(throws: EngineError.invalidArgument("call \(out1) is not being recorded")) {
            _ = try await engine.stopRecording(out1)
        }

        // Split the recording leg: both leave the conference (two legs), the split leg keeps
        // mic and speaker, and the recording moves to the remaining leg. A stereo split
        // recording: the remote file gets the call and its partner, the local one the mic.
        let wavSplit = tempWAV("split.wav")
        let splitFiles = RecordingFiles.planned(for: wavSplit, layout: .stereoSplit)
        try await engine.startRecording(out2, to: wavSplit, layout: .stereoSplit)
        #expect(await engine.recordingFiles(of: out1) == splitFiles)      // through the conference
        #expect(await waitUntil(timeout: 2) {
            let own = await engine.recorderHears(out2, from: out2, role: .remote)
            let partner = await engine.recorderHears(out2, from: out1, role: .remote)
            let mic = await engine.recorderHears(out2, from: nil, role: .local)
            let micInRemote = await engine.recorderHears(out2, from: nil, role: .remote)
            let callInLocal = await engine.recorderHears(out2, from: out2, role: .local)
            return own && partner && mic && !micInRemote && !callInLocal
        })
        try await engine.split(out2)
        #expect(await waitUntil {
            let a = await call(out1), b = await call(out2)
            return a?.inConference == false && b?.inConference == false
                && a?.isRecording == true && b?.isRecording == false
        })
        #expect(await linked(out1, out2, false))
        #expect(await wired(out2, true, true))
        #expect(log.all.contains { if case let .callChanged(c) = $0 { return c.id == out1 && c.isRecording }; return false })
        #expect(await waitUntil(timeout: 2) { await engine.recorderHears(out1, from: out1, role: .remote) })
        #expect(await engine.recordingFiles(of: out1) == splitFiles)
        #expect(await engine.recordingFiles(of: out2) == nil)
        try await Task.sleep(for: .milliseconds(300))
        #expect(try await engine.stopRecording(out1) == splitFiles)
        let splitHeaders = [splitFiles.local, splitFiles.remote].map { $0.flatMap(WAVHeader.read) }
        #expect(splitHeaders.allSatisfy { $0?.isFinal == true }, "\(splitHeaders)")
        if let l = splitHeaders[0], let r = splitHeaders[1] {
            #expect(abs(l.fileSize - r.fileSize) <= 640, "local \(l.fileSize), remote \(r.fileSize)")
        }
        #expect(!FileManager.default.fileExists(atPath: wavSplit.path))

        // stopRecording on any leg stops the conference's recording; a second recording of
        // the same conference is refused.
        try await engine.merge([out2, out1])
        #expect(await waitUntil {
            let a = await call(out1), b = await call(out2)
            return a?.inConference == true && b?.inConference == true
        })
        let wav2 = tempWAV("any-leg.wav")
        try await engine.startRecording(out1, to: wav2)
        await #expect(throws: EngineError.invalidArgument("the conference of call \(out2) is already being recorded (by \(out1))")) {
            try await engine.startRecording(out2, to: tempWAV("second.wav"))
        }
        try await Task.sleep(for: .milliseconds(200))
        #expect(try await engine.stopRecording(out2) == RecordingFiles(layout: .mono, mixed: wav2))
        #expect(await call(out1)?.isRecording == false)

        // The recording leg ends: the recording moves to the leg that remains (same file, it
        // keeps growing); the ended leg's .callEnded says isRecording == false. Then the last
        // leg ends: its .callEnded says isRecording and the WAV is final when it arrives.
        let wav3 = tempWAV("moving.wav")
        recordingURLs.withLock { $0[out2] = wav3 }
        try await engine.startRecording(out1, to: wav3)
        try await Task.sleep(for: .milliseconds(300))
        try await engine.hangup(out1)
        #expect(await waitUntil { let b = await call(out2); return b?.isRecording == true && b?.inConference == false })
        let sizeAfterMove = (try? FileManager.default.attributesOfItem(atPath: wav3.path))?[.size] as? Int ?? 0
        try await Task.sleep(for: .milliseconds(600))
        let sizeLater = (try? FileManager.default.attributesOfItem(atPath: wav3.path))?[.size] as? Int ?? 0
        #expect(sizeLater > sizeAfterMove, "\(sizeAfterMove) -> \(sizeLater)")
        try await engine.hangup(out2)

        func ended(_ id: CallID) -> CallInfo? {
            log.all.lazy.compactMap { if case let .callEnded(c, _) = $0, c.id == id { return c }; return nil }.first
        }
        #expect(await waitUntil { [out1, inc1, out2, inc2].allSatisfy { ended($0) != nil } })
        #expect(ended(out1)?.isRecording == false)
        #expect(ended(out2)?.isRecording == true)
        let atEnd = try #require(headersAtEnd.withLock { $0[out2] } ?? nil, "no WAV header when .callEnded arrived")
        #expect(atEnd.isFinal, "\(atEnd)")
        for id in [out1, inc1, out2, inc2] {
            let events = log.all
            let end = try #require(events.firstIndex { if case let .callEnded(c, _) = $0 { return c.id == id }; return false })
            let ghost = events[end...].contains { if case let .callChanged(c) = $0 { return c.id == id }; return false }
            #expect(!ghost, "callChanged after callEnded for \(id)")
        }
        await #expect(throws: EngineError.noSuchCall(out2)) { _ = try await engine.stopRecording(out2) }
        #expect(await engine.calls().isEmpty)
        await engine.stop()
        for wav in [wav1, wavSplit, wav2, wav3] {
            try? FileManager.default.removeItem(at: wav.deletingLastPathComponent().deletingLastPathComponent())
        }
    }

    /// stop() with a recording running: the WAV is finished and the call's .callEnded
    /// (isRecording == true) is still delivered.
    @Test func stopWhileRecording() async throws {
        let engine = await makeEngine()
        let log = EventLog()
        let consumer = log.consume(engine)
        defer { consumer.cancel() }
        try await engine.start(network: Self.network)
        let account = AccountConfig(displayName: "L", username: "loop", domain: "127.0.0.1", enabled: false)
        try await engine.addAccount(account, password: "")
        let port = await engine.localPort(of: .udp)
        let out = try await engine.makeCall(to: DialString(uri: "sip:r@127.0.0.1:\(port)", display: "r"),
                                            from: account.id)
        func incoming() -> CallID? {
            log.all.lazy.compactMap { if case let .incomingCall(c) = $0 { return c.id }; return nil }.first
        }
        #expect(await waitUntil { incoming() != nil })
        try await engine.answer(try #require(incoming()))
        #expect(await waitUntil { await engine.calls().first { $0.id == out }?.state == .connected })
        let wav = tempWAV("stop.wav")
        try await engine.startRecording(out, to: wav)
        try await Task.sleep(for: .milliseconds(400))
        await engine.stop()

        // The event stream is asynchronous: the .callEnded of a stopped engine may still be in flight.
        func ended() -> CallInfo? { log.all.lazy.compactMap { if case let .callEnded(c, _) = $0, c.id == out { return c }; return nil }.first }
        #expect(await waitUntil { ended() != nil })
        #expect(ended()?.isRecording == true)
        let header = try #require(WAVHeader.read(wav))
        #expect(header.isFinal, "\(header)")
        try? FileManager.default.removeItem(at: wav.deletingLastPathComponent().deletingLastPathComponent())
    }

    /// Stereo split recording of a loopback call: a 600 Hz tone is played into the answering
    /// leg, so it reaches the recorded leg as remote audio; our side is the null audio device
    /// (silence). 3 s with the middle second muted: both files final and as long as each
    /// other (one 20 ms frame = 640 bytes at most), the remote file carries the tone, the
    /// local one is silent, the local recorder is at level 0 while muted; then a stereo M4A.
    /// Second recording: the call ends while recording; `.callEnded` (isRecording) arrives
    /// with both files final, and `recordingFiles(of:)` still names them afterwards.
    @Test func loopbackStereoSplitRecording() async throws {
        let engine = await makeEngine()
        let log = EventLog()
        let base2 = tempWAV("ended.wav")
        let files2 = RecordingFiles.planned(for: base2, layout: .stereoSplit)
        let headersAtEnd = OSAllocatedUnfairLock(initialState: [WAVHeader?]())
        let consumer = Task {
            for await e in engine.events {
                if case let .callEnded(c, _) = e, c.isRecording {
                    let headers = files2.all.map { WAVHeader.read($0) }
                    headersAtEnd.withLock { $0 = headers }
                }
                log.append(e)
            }
        }
        defer { consumer.cancel() }
        try await engine.start(network: Self.network)
        let account = AccountConfig(displayName: "L", username: "loop", domain: "127.0.0.1", enabled: false)
        try await engine.addAccount(account, password: "")
        let port = await engine.localPort(of: .udp)
        let out = try await engine.makeCall(to: DialString(uri: "sip:s@127.0.0.1:\(port)", display: "s"),
                                            from: account.id)
        func incoming() -> CallID? {
            log.all.lazy.compactMap { if case let .incomingCall(c) = $0 { return c.id }; return nil }.first
        }
        #expect(await waitUntil { incoming() != nil })
        let inc = try #require(incoming())
        try await engine.answer(inc)
        #expect(await waitUntil {
            let c = await engine.calls().first { $0.id == out }
            return c?.state == .connected && c?.codec != nil
        })

        let dir = tempWAV("x").deletingLastPathComponent().deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tone = dir.appendingPathComponent("tone.wav")
        try RecordingConverterTests.sineWAV(seconds: 2, frequency: 600).write(to: tone)
        let player = try await engine.startTestPlayer(tone, into: inc)

        let base = dir.appendingPathComponent("rec/call.wav")
        let planned = RecordingFiles.planned(for: base, layout: .stereoSplit)
        try await engine.startRecording(out, to: base, layout: .stereoSplit)
        #expect(await engine.calls().first { $0.id == out }?.isRecording == true)
        #expect(await engine.recordingFiles(of: out) == planned)
        #expect(await engine.recordingFiles(of: inc) == nil)
        #expect(await waitUntil(timeout: 2) {
            let remote = await engine.recorderHears(out, from: out, role: .remote)
            let local = await engine.recorderHears(out, from: nil, role: .local)
            let micInRemote = await engine.recorderHears(out, from: nil, role: .remote)
            let callInLocal = await engine.recorderHears(out, from: out, role: .local)
            return remote && local && !micInRemote && !callInLocal
        })
        try await Task.sleep(for: .seconds(1))
        try await engine.setMute(out, true)
        #expect(await engine.localRecorderLevel(out) == 0)
        #expect(await engine.recorderHears(out, from: nil, role: .local))     // still fed: silence, same length
        try await Task.sleep(for: .seconds(1))
        try await engine.setMute(out, false)
        #expect(await engine.localRecorderLevel(out) == 1)
        try await Task.sleep(for: .seconds(1))
        let files = try await engine.stopRecording(out)
        #expect(files == planned)
        #expect(await engine.recordingFiles(of: out) == nil)
        #expect(!FileManager.default.fileExists(atPath: base.path))
        let localURL = try #require(files.local), remoteURL = try #require(files.remote)
        let local = try #require(WAVHeader.read(localURL))
        let remote = try #require(WAVHeader.read(remoteURL))
        for h in [local, remote] {
            #expect(h.isFinal, "\(h)")
            #expect(h.channels == 1 && h.bitsPerSample == 16 && h.sampleRate == 16000)
            #expect(h.dataSize >= 80_000, "\(h)")                  // >= 2.5 s
        }
        #expect(abs(local.fileSize - remote.fileSize) <= 640, "local \(local.fileSize), remote \(remote.fileSize)")
        let remoteRMS = try wavRMS(remoteURL), localRMS = try wavRMS(localURL)
        #expect(remoteRMS > 300, "remote RMS \(remoteRMS)")
        #expect(localRMS < 50, "local RMS \(localRMS)")

        let m4a = try await RecordingConverter.convert(files: files, to: dir.appendingPathComponent("call.m4a"))
        #expect(((try FileManager.default.attributesOfItem(atPath: m4a.path)[.size] as? Int) ?? 0) > 1024)
        #expect(try AVAudioFile(forReading: m4a).fileFormat.channelCount == 2)

        // The call ends while a stereo recording runs.
        try await engine.startRecording(out, to: base2, layout: .stereoSplit)
        try await Task.sleep(for: .milliseconds(500))
        await engine.stopTestPlayer(player)
        try await engine.hangup(out)
        #expect(await waitUntil {
            log.all.contains { if case let .callEnded(c, _) = $0 { return c.id == out }; return false }
        })
        let ended = log.all.lazy.compactMap { if case let .callEnded(c, _) = $0, c.id == out { return c }; return nil }.first
        #expect(ended?.isRecording == true)
        let atEnd = headersAtEnd.withLock { $0 }
        #expect(atEnd.count == 2 && atEnd.allSatisfy { $0?.isFinal == true }, "\(atEnd)")
        if atEnd.count == 2, let l = atEnd[0], let r = atEnd[1] {
            #expect(abs(l.fileSize - r.fileSize) <= 640, "local \(l.fileSize), remote \(r.fileSize)")
        }
        #expect(await engine.recordingFiles(of: out) == files2)
        await engine.stop()
        try? FileManager.default.removeItem(at: base2.deletingLastPathComponent().deletingLastPathComponent())
    }

    /// Without any call: the milestone 5 members validate their arguments.
    @Test func conferenceAndRecordingWithoutCalls() async throws {
        let engine = await makeEngine()
        let nobody = CallID(raw: 3, serial: 99)
        await #expect(throws: EngineError.notStarted) { try await engine.merge([nobody, nobody]) }
        try await engine.start(network: Self.network)
        let other = CallID(raw: 4, serial: 100)
        await #expect(throws: EngineError.noSuchCall(nobody)) { try await engine.merge([nobody, other]) }
        await #expect(throws: EngineError.noSuchCall(nobody)) { try await engine.split(nobody) }
        await #expect(throws: EngineError.noSuchCall(nobody)) {
            try await engine.startRecording(nobody, to: tempWAV("none.wav"))
        }
        await #expect(throws: EngineError.noSuchCall(nobody)) { _ = try await engine.stopRecording(nobody) }
        await #expect(throws: EngineError.invalidArgument("merge needs at least two calls")) {
            try await engine.merge([nobody])
        }
        await engine.stop()
    }

    /// Subscriptions are kept per normalised URI; pjsua's buddy list follows.
    @Test func presenceSubscriptionBookkeeping() async throws {
        let engine = await makeEngine()
        await #expect(throws: EngineError.notStarted) { try await engine.subscribePresence(uri: "sip:a@b") }
        try await engine.start(network: Self.network)

        // No account: pjsua keeps the buddy but sends nothing.
        try await engine.subscribePresence(uri: "test@127.0.0.1:5999")
        try await engine.subscribePresence(uri: "sip:test@127.0.0.1:5999")       // same: no-op
        try await engine.subscribePresence(uri: " <SIP:test@127.0.0.1:5999> ")  // same: no-op
        #expect(await engine.presenceSubscriptions() == ["sip:test@127.0.0.1:5999"])
        #expect(await engine.presenceSubscriptionCount() == 1)
        try await engine.subscribePresence(uri: "sips:other@example.com")
        #expect(await engine.presenceSubscriptionCount() == 2)

        for bad in ["", "   ", "tel:+74951234567", "sip:"] {
            await #expect(throws: EngineError.invalidArgument("presence URI \"\(bad)\"")) {
                try await engine.subscribePresence(uri: bad)
            }
        }

        try await engine.unsubscribePresence(uri: "SIP:test@127.0.0.1:5999")
        #expect(await engine.presenceSubscriptionCount() == 1)
        try await engine.unsubscribePresence(uri: "sip:test@127.0.0.1:5999")    // unknown now: no-op
        try await engine.unsubscribePresence(uri: "never@watched")
        #expect(await engine.presenceSubscriptions() == ["sips:other@example.com"])

        // pjsua aborts beyond PJSUA_MAX_BUDDIES: the engine refuses instead.
        var added = await engine.presenceSubscriptionCount()
        while added < 256 {
            try await engine.subscribePresence(uri: "sip:b\(added)@192.0.2.1")
            added += 1
        }
        await #expect(throws: EngineError.invalidArgument("too many presence subscriptions (limit 256)")) {
            try await engine.subscribePresence(uri: "sip:one-too-many@192.0.2.1")
        }
        try await engine.unsubscribePresence(uri: "sip:b255@192.0.2.1")
        try await engine.subscribePresence(uri: "sip:one-too-many@192.0.2.1")

        // A restart drops every subscription; the caller subscribes again.
        await engine.stop()
        #expect(await engine.presenceSubscriptions().isEmpty)
        try await engine.start(network: Self.network)
        #expect(await engine.presenceSubscriptionCount() == 0)
        try await engine.subscribePresence(uri: "sips:other@example.com")
        #expect(await engine.presenceSubscriptionCount() == 1)
        await engine.stop()
    }

    @Test func publishPresenceNeedsAPublishingAccount() async throws {
        let engine = await makeEngine()
        try await engine.start(network: Self.network)
        let quiet = AccountConfig(displayName: "Q", username: "1001", domain: "127.0.0.1", enabled: false)
        var loud = AccountConfig(displayName: "P", username: "1002", domain: "127.0.0.1", enabled: false,
                                 publishPresence: true)
        try await engine.addAccount(quiet, password: "")
        try await engine.addAccount(loud, password: "")

        await #expect(throws: EngineError.invalidArgument("account sip:1001@127.0.0.1 does not publish presence")) {
            try await engine.publishPresence(.away, for: quiet.id)
        }
        let stranger = AccountID()
        await #expect(throws: EngineError.unknownAccount(stranger)) {
            try await engine.publishPresence(.available, for: stranger)
        }
        for status in [PresenceStatus.away, .dnd, .offline, .available, .dnd] {
            try await engine.publishPresence(status, for: loud.id)
        }
        #expect(await engine.publishedPresence(of: loud.id) == .dnd)

        // Switching publishing off and on keeps the last status.
        loud.publishPresence = false
        try await engine.updateAccount(loud, password: nil)
        await #expect(throws: EngineError.self) { try await engine.publishPresence(.away, for: loud.id) }
        loud.publishPresence = true
        try await engine.updateAccount(loud, password: nil)
        #expect(await engine.publishedPresence(of: loud.id) == .dnd)
        try await engine.publishPresence(.available, for: loud.id)
        await engine.stop()
    }

    /// An INVITE with `Call-Info: <...>;answer-after=5` from anyone but the account's server
    /// must not open the microphone: answerAfter stays nil and a warning is logged.
    @Test func answerAfterFromUntrustedSourceIsIgnored() async throws {
        let engine = await makeEngine()
        let log = EventLog()
        let consumer = log.consume(engine)
        defer { consumer.cancel() }
        try await engine.start(network: Self.network)
        let account = AccountConfig(displayName: "I", username: "intercom", domain: "127.0.0.1", enabled: false)
        try await engine.addAccount(account, password: "")
        let port = await engine.localPort(of: .udp)
        func incoming() -> [CallInfo] {
            log.all.compactMap { if case let .incomingCall(c) = $0 { return c }; return nil }
        }

        try sendUDP({ inviteText(callID: "ci-1", from: $0, to: port, callInfo: "<sip:127.0.0.1>;answer-after=0") }, to: port)
        #expect(await waitUntil { incoming().count == 1 })
        #expect(incoming().first?.answerAfter == nil)
        #expect(await engine.calls().first?.answerAfter == nil)
        #expect(log.all.contains {
            if case let .log(_, text) = $0 { return text.contains("ignored answer-after from untrusted source 127.0.0.1:") }
            return false
        })
        await engine.stop()
    }

    /// The same INVITE from the registrar that accepted our REGISTER is honoured; from any
    /// other port on the same host it is not.
    @Test func answerAfterFromTheRegistrarIsHonoured() async throws {
        let stub = try RegistrarStub(status: "200 OK")
        defer { stub.stop() }
        let engine = await makeEngine()
        let log = EventLog()
        let consumer = log.consume(engine)
        defer { consumer.cancel() }
        try await engine.start(network: Self.network)
        let account = AccountConfig(displayName: "I", username: "intercom", domain: "127.0.0.1",
                                    registrar: "127.0.0.1:\(stub.port)", enabled: true)
        try await engine.addAccount(account, password: "pw")
        #expect(await waitUntil {
            if case .registered = await engine.registrationState(of: account.id) { return true }
            return false
        })
        let port = await engine.localPort(of: .udp)
        func incoming() -> [CallInfo] {
            log.all.compactMap { if case let .incomingCall(c) = $0 { return c }; return nil }
        }

        stub.send(inviteText(callID: "reg-1", from: stub.port, to: port, callInfo: "<sip:pbx>;answer-after=5"), to: port)
        #expect(await waitUntil { incoming().count == 1 })
        #expect(incoming().first?.answerAfter == 5)
        try await engine.reject(try #require(incoming().first).id)

        try sendUDP({ inviteText(callID: "other-1", from: $0, to: port, callInfo: ";answer-after=5") }, to: port)
        #expect(await waitUntil { incoming().count == 2 })
        #expect(incoming().last?.answerAfter == nil)

        stub.send(inviteText(callID: "reg-2", from: stub.port, to: port, callInfo: nil), to: port)
        #expect(await waitUntil { incoming().count == 3 })
        #expect(incoming().last?.answerAfter == nil)
        await engine.stop()
    }

    /// Asterisk/FreePBX presence: `<rpid:on-the-phone/>` (which pjrpid reports as an unknown
    /// activity) and the note "On the phone" with basic open mean busy; the note "Ringing" (with
    /// or without on-the-phone) means ringing. The note travels in the event.
    @Test func asteriskStylePresenceMapsToDND() async throws {
        let stub = try PresenceStub()
        defer { stub.stop() }
        let engine = await makeEngine()
        let log = EventLog()
        let consumer = log.consume(engine)
        defer { consumer.cancel() }
        try await engine.start(network: Self.network)
        let account = AccountConfig(displayName: "W", username: "watcher", domain: "127.0.0.1", enabled: false)
        try await engine.addAccount(account, password: "")
        let uri = "buddy@127.0.0.1:\(stub.port)"
        try await engine.subscribePresence(uri: uri)
        #expect(await waitUntil { stub.subscribed })
        func lastEvent() -> (status: PresenceStatus, note: String?)? {
            log.all.lazy.reversed().compactMap { if case let .buddyPresence(u, st, n) = $0, u == uri { return (st, n) }; return nil }.first
        }
        func last() -> PresenceStatus? { lastEvent()?.status }
        let steps: [(String?, String?, Bool, PresenceStatus)] = [
            (nil, nil, true, .available),
            ("on-the-phone", nil, true, .dnd),          // activity only: found in the NOTIFY body
            (nil, nil, true, .available),               // flag cleared by the next NOTIFY
            (nil, "Ringing", true, .ringing),
            ("on-the-phone", "Ringing", true, .ringing),    // Asterisk: ringing extension
            ("on-the-phone", "On the phone", true, .dnd),   // InUse
            (nil, "Ready", true, .available),               // NotInUse
            ("away", nil, true, .away),
            (nil, "On the phone", true, .dnd),
            ("on-the-phone", "On the phone", false, .offline),
        ]
        for (activity, note, open, expected) in steps {
            try await Task.sleep(for: .milliseconds(100))
            stub.notify(activity: activity, note: note, open: open)
            #expect(await waitUntil(timeout: 3) { last() == expected },
                    "activity \(activity ?? "-"), note \(note ?? "-"), open \(open): got \(String(describing: last()))")
            if open { #expect(lastEvent()?.note == note, "note \(note ?? "-"): got \(String(describing: lastEvent()?.note))") }
        }
        await engine.stop()
    }

    /// A SUBSCRIBE the server refused is retried when the account is updated (pjsua alone
    /// would wait 300 s).
    @Test func failedSubscriptionIsRetriedAfterAccountUpdate() async throws {
        let stub = try RegistrarStub(status: "403 Forbidden", subscribeStatus: "403 Forbidden")
        defer { stub.stop() }
        let engine = await makeEngine()
        let log = EventLog()
        let consumer = log.consume(engine)
        defer { consumer.cancel() }
        try await engine.start(network: Self.network)
        var cfg = AccountConfig(displayName: "W", username: "watcher", domain: "127.0.0.1", enabled: false)
        try await engine.addAccount(cfg, password: "pw")
        let uri = "sip:buddy@127.0.0.1:\(stub.port)"
        try await engine.subscribePresence(uri: uri)
        #expect(await waitUntil { stub.subscribeCount == 1 })
        #expect(await waitUntil {
            log.all.contains { if case let .buddyPresence(u, .offline, _) = $0 { return u == uri }; return false }
        })
        try await Task.sleep(for: .milliseconds(300))
        #expect(stub.subscribeCount == 1)                      // pjsua waits 300 s on its own

        cfg.displayName = "W2"
        try await engine.updateAccount(cfg, password: nil)
        #expect(await waitUntil { stub.subscribeCount == 2 })
        await engine.stop()
    }
}

/// An INVITE with an SDP offer from 127.0.0.1:`from` to the engine on 127.0.0.1:`to`.
func inviteText(callID: String, from myPort: UInt16, to port: Int, callInfo: String?) -> String {
    let sdp = "v=0\r\no=- 1 1 IN IP4 127.0.0.1\r\ns=-\r\nc=IN IP4 127.0.0.1\r\nt=0 0\r\n"
        + "m=audio 40000 RTP/AVP 0\r\na=rtpmap:0 PCMU/8000\r\n"
    var msg = "INVITE sip:intercom@127.0.0.1:\(port) SIP/2.0\r\n"
        + "Via: SIP/2.0/UDP 127.0.0.1:\(myPort);rport;branch=z9hG4bK-\(callID)\r\n"
        + "Max-Forwards: 70\r\n"
        + "From: \"Pager\" <sip:pager@127.0.0.1:\(myPort)>;tag=t-\(callID)\r\n"
        + "To: <sip:intercom@127.0.0.1:\(port)>\r\n"
        + "Call-ID: \(callID)@127.0.0.1\r\n"
        + "CSeq: 1 INVITE\r\n"
        + "Contact: <sip:pager@127.0.0.1:\(myPort)>\r\n"
    if let callInfo { msg += "Call-Info: \(callInfo)\r\n" }
    return msg + "Content-Type: application/sdp\r\nContent-Length: \(sdp.utf8.count)\r\n\r\n" + sdp
}

// MARK: - pure parts (no pjsua)

@Suite("Engine milestone 5 helpers")
struct EngineMilestone5HelperTests {
    @Test func answerAfterParsing() {
        let cases: [(String, Int?)] = [
            ("<sip:192.168.1.1>;answer-after=0", 0),
            ("<sip:pbx.example.com>;purpose=info;answer-after=5", 5),
            (";answer-after=7", 7),
            (" ; Answer-After = 12 ", 12),
            ("answer-after=3", 3),
            ("<http://x/icon.png>;purpose=icon, <sip:pbx>;answer-after=2", 2),
            ("<sip:pbx>;answer-after=\"4\"", 4),
            ("<sip:pbx>;answer-after=", nil),
            ("<sip:pbx>;answer-after=x", nil),
            ("<sip:pbx>;xanswer-after=5", nil),
            ("<sip:pbx>;purpose=icon", nil),
            ("", nil),
            ("<sip:pbx>;answer-after=999999", 86400),
        ]
        for (value, expected) in cases {
            #expect(CallInfoHeader.answerAfter(value) == expected, "\(value)")
        }
    }

    @Test func presenceStatusMapping() {
        typealias M = PresenceMapping
        #expect(M.status(basic: .online, activity: .unknown, subscriptionTerminated: false) == .available)
        #expect(M.status(basic: .online, activity: .away, subscriptionTerminated: false) == .away)
        #expect(M.status(basic: .online, activity: .busy, subscriptionTerminated: false) == .dnd)
        #expect(M.status(basic: .offline, activity: .busy, subscriptionTerminated: false) == .offline)
        #expect(M.status(basic: .unknown, activity: .unknown, subscriptionTerminated: false) == .offline)
        #expect(M.status(basic: .online, activity: .unknown, subscriptionTerminated: true) == .offline)

        // Notes (Asterisk/FreePBX: basic open + "On the phone" / "Ringing") and on-the-phone.
        for note in ["On the phone", " ON THE PHONE ", "Busy", "Do Not Disturb"] {
            #expect(M.status(basic: .online, activity: .unknown, note: note, subscriptionTerminated: false) == .dnd, "\(note)")
        }
        for note in ["Ready", "Idle", "", "On hold soon"] {
            #expect(M.status(basic: .online, activity: .unknown, note: note, subscriptionTerminated: false) == .available, "\(note)")
        }
        #expect(M.status(basic: .online, activity: .onThePhone, subscriptionTerminated: false) == .dnd)
        #expect(M.status(basic: .online, activity: .away, note: "On the phone", subscriptionTerminated: false) == .away)
        #expect(M.status(basic: .offline, activity: .unknown, note: "On the phone", subscriptionTerminated: false) == .offline)
        #expect(M.status(basic: .online, activity: .onThePhone, subscriptionTerminated: true) == .offline)

        // Ringing (Asterisk/FreePBX: basic open + "Ringing", usually with on-the-phone/busy): wins
        // over the activity; never while offline.
        for note in ["Ringing", " RINGING ", "early", "Alerting"] {
            for activity in [M.Activity.unknown, .busy, .onThePhone, .away] {
                #expect(M.status(basic: .online, activity: activity, note: note, subscriptionTerminated: false) == .ringing, "\(note) \(activity)")
            }
        }
        #expect(M.status(basic: .offline, activity: .unknown, note: "Ringing", subscriptionTerminated: false) == .offline)
        #expect(M.status(basic: .online, activity: .onThePhone, note: "Ringing", subscriptionTerminated: true) == .offline)
        #expect(M.status(basic: .online, activity: .unknown, note: "Ringing soon", subscriptionTerminated: false) == .available)
        #expect(M.cleanNote("  On the phone \n") == "On the phone")
        #expect(M.cleanNote(" ") == nil)
        #expect(M.cleanNote(nil) == nil)

        #expect(M.publication(.available) == (true, .unknown, nil))
        #expect(M.publication(.away) == (true, .away, nil))
        #expect(M.publication(.dnd) == (true, .busy, "Do Not Disturb"))
        #expect(M.publication(.ringing) == (true, .busy, "Ringing"))
        #expect(M.publication(.offline).online == false)

        // Settings written by any version decode; an unknown status decodes as offline.
        let decoded = try? JSONDecoder().decode([PresenceStatus].self,
                                                from: Data(#"["available","away","dnd","offline","ringing","lunch"]"#.utf8))
        #expect(decoded == [.available, .away, .dnd, .offline, .ringing, .offline])
        #expect(String(decoding: try! JSONEncoder().encode([PresenceStatus.ringing]), as: UTF8.self) == #"["ringing"]"#)
    }

    @Test func presenceURINormalisation() {
        #expect(PresenceMapping.normalizedURI("100@pbx.example.com") == "sip:100@pbx.example.com")
        #expect(PresenceMapping.normalizedURI(" SIP:100@pbx.example.com ") == "sip:100@pbx.example.com")
        #expect(PresenceMapping.normalizedURI("Sips:100@pbx") == "sips:100@pbx")
        #expect(PresenceMapping.normalizedURI("\"Bob\" <sip:bob@host;transport=tcp>") == "sip:bob@host;transport=tcp")
        #expect(PresenceMapping.normalizedURI("test@127.0.0.1:5080") == "sip:test@127.0.0.1:5080")
        #expect(PresenceMapping.normalizedURI("pbx.example.com:5060") == "sip:pbx.example.com:5060")
        #expect(PresenceMapping.normalizedURI("tel:+74951234567") == nil)
        #expect(PresenceMapping.normalizedURI("http://example.com") == nil)
        #expect(PresenceMapping.normalizedURI("  ") == nil)
        #expect(PresenceMapping.normalizedURI("sip:") == nil)
    }

    @Test func signallingSourcePeerMatching() {
        let reg = SignallingSource(address: "192.0.2.10", port: 5060, transport: .udp)
        #expect(SignallingSource(address: "192.0.2.10", port: 5060, transport: .udp).isSamePeer(as: reg))
        #expect(!SignallingSource(address: "192.0.2.10", port: 5070, transport: .udp).isSamePeer(as: reg))
        #expect(!SignallingSource(address: "192.0.2.11", port: 5060, transport: .udp).isSamePeer(as: reg))
        #expect(!SignallingSource(address: "192.0.2.10", port: 5060, transport: .tcp).isSamePeer(as: reg))
        let tls = SignallingSource(address: "2001:db8::1", port: 5061, transport: .tls)
        #expect(SignallingSource(address: "2001:DB8:0::1", port: 49152, transport: .tls).isSamePeer(as: tls))
        #expect(!SignallingSource(address: "192.0.2.10", port: 5060, transport: nil).isSamePeer(as: reg))

        #expect(SignallingSource.proxy("sip:192.0.2.5:5070;lr", transport: .udp)
                == SignallingSource(address: "192.0.2.5", port: 5070, transport: .udp))
        #expect(SignallingSource.proxy("192.0.2.5", transport: .tls)
                == SignallingSource(address: "192.0.2.5", port: 5061, transport: .tls))
        #expect(SignallingSource.proxy("<sip:[2001:db8::2]:5080;transport=tcp>", transport: .tcp)
                == SignallingSource(address: "2001:db8::2", port: 5080, transport: .tcp))
        #expect(SignallingSource.proxy("sip:proxy.example.com:5060;lr", transport: .udp) == nil)
        #expect(SignallingSource.proxy(nil, transport: .udp) == nil)
        #expect(SignallingSource.proxy("", transport: .udp) == nil)
    }

    @Test func wavHeaderRepairAndEmptyRecordings() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("macrosip-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // A header as pjmedia writes it before finishing (sizes 0) plus 1000 samples.
        var data = Data("RIFF".utf8) + Data(count: 4) + Data("WAVEfmt ".utf8)
        data += Data([16, 0, 0, 0, 1, 0, 1, 0, 0x80, 0x3E, 0, 0, 0, 0x7D, 0, 0, 2, 0, 16, 0])
        data += Data("data".utf8) + Data(count: 4) + Data(repeating: 1, count: 2000)
        let wav = dir.appendingPathComponent("unfinished.wav")
        try data.write(to: wav)
        #expect(WAVHeader.read(wav)?.isFinal == false)
        #expect(WAVFile.repair(wav))
        let fixed = try #require(WAVHeader.read(wav))
        #expect(fixed.isFinal && fixed.dataSize == 2000 && fixed.sampleRate == 16000)
        #expect(!Engine.recordingIsEmpty(wav))

        let empty = dir.appendingPathComponent("held.wav")
        try data.prefix(44).write(to: empty)
        #expect(Engine.recordingIsEmpty(empty))
        #expect(Engine.recordingIsEmpty(dir.appendingPathComponent("missing.wav")))
        let junk = dir.appendingPathComponent("junk.wav")
        try Data(repeating: 7, count: 100).write(to: junk)
        #expect(!WAVFile.repair(junk))
    }

    @Test func callInfoCarriesConferenceRecordingAndAnswerAfter() {
        var rec = CallRecord(serial: 7, accountID: .unknown, direction: .incoming, announced: true)
        rec.conference = 2
        rec.isRecording = true
        rec.answerAfter = 0
        let snap = CallSnapshot(slot: 1, accIndex: 0, isOutgoing: false, state: .confirmed, lastStatus: 200,
                                lastStatusText: "OK", remoteInfo: "<sip:1@x>", sipCallID: "c", mediaStatus: .active,
                                confSlot: 2, connectDuration: 1, serial: 7, codec: "PCMU/8000", isSecure: false)
        let info = EngineBridge.makeInfo(snap, rec)
        #expect(info.inConference && info.isRecording && info.answerAfter == 0)
        rec.conference = nil
        rec.isRecording = false
        rec.answerAfter = nil
        let plain = EngineBridge.makeInfo(snap, rec)
        #expect(!plain.inConference && !plain.isRecording && plain.answerAfter == nil)
    }
}
