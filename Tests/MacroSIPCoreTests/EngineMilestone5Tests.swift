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

// MARK: - tests that run pjsua (part of the serialized "Engine (pjsua)" suite)

extension EngineTests {
    /// Two loopback calls on one engine (four legs): merge (resuming a held leg), per-leg
    /// hold and mute inside the conference, recording with conference partners, split,
    /// a leg ending, and the automatic stop of a recording when its call ends.
    @Test func loopbackConferenceAndRecording() async throws {
        let engine = makeEngine()
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
        #expect(stopped == wav1)
        let header = try #require(WAVHeader.read(wav1))
        #expect(header.isFinal, "\(header)")
        #expect(header.channels == 1 && header.bitsPerSample == 16 && header.sampleRate == 16000)
        #expect(header.dataSize >= 16000)          // >= 0.5 s at 16 kHz, 16 bit
        #expect(await call(out1)?.isRecording == false)
        await #expect(throws: EngineError.invalidArgument("call \(out1) is not being recorded")) {
            _ = try await engine.stopRecording(out1)
        }

        // Split: with two legs both leave the conference; the split leg keeps mic and speaker.
        try await engine.split(out2)
        #expect(await waitUntil {
            let a = await call(out1), b = await call(out2)
            return a?.inConference == false && b?.inConference == false
        })
        #expect(await linked(out1, out2, false))
        #expect(await wired(out2, true, true))

        // A leg ends: the conference of two dissolves; a recorded call's .callEnded comes
        // with isRecording and a finished WAV.
        try await engine.merge([out2, out1])
        #expect(await waitUntil {
            let a = await call(out1), b = await call(out2)
            return a?.inConference == true && b?.inConference == true
        })
        let wav2 = tempWAV("ending.wav")
        recordingURLs.withLock { $0[out2] = wav2 }
        try await engine.startRecording(out2, to: wav2)
        try await Task.sleep(for: .milliseconds(300))
        try await engine.hangup(out1)
        #expect(await waitUntil { await call(out2)?.inConference == false })
        try await engine.hangup(out2)

        func ended(_ id: CallID) -> CallInfo? {
            log.all.lazy.compactMap { if case let .callEnded(c, _) = $0, c.id == id { return c }; return nil }.first
        }
        #expect(await waitUntil { [out1, inc1, out2, inc2].allSatisfy { ended($0) != nil } })
        #expect(ended(out2)?.isRecording == true)
        #expect(ended(out1)?.isRecording == false)
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
        try? FileManager.default.removeItem(at: wav1.deletingLastPathComponent().deletingLastPathComponent())
        try? FileManager.default.removeItem(at: wav2.deletingLastPathComponent().deletingLastPathComponent())
    }

    /// stop() with a recording running: the WAV is finished and the call's .callEnded
    /// (isRecording == true) is still delivered.
    @Test func stopWhileRecording() async throws {
        let engine = makeEngine()
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

        let end = log.all.lazy.compactMap { if case let .callEnded(c, _) = $0, c.id == out { return c }; return nil }.first
        #expect(end?.isRecording == true)
        let header = try #require(WAVHeader.read(wav))
        #expect(header.isFinal, "\(header)")
        try? FileManager.default.removeItem(at: wav.deletingLastPathComponent().deletingLastPathComponent())
    }

    /// Without any call: the milestone 5 members validate their arguments.
    @Test func conferenceAndRecordingWithoutCalls() async throws {
        let engine = makeEngine()
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
        let engine = makeEngine()
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
        let engine = makeEngine()
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

    /// An INVITE with `Call-Info: <...>;answer-after=5` (as a PBX pages an intercom).
    @Test func incomingCallCarriesAnswerAfter() async throws {
        let engine = makeEngine()
        let log = EventLog()
        let consumer = log.consume(engine)
        defer { consumer.cancel() }
        try await engine.start(network: Self.network)
        let account = AccountConfig(displayName: "I", username: "intercom", domain: "127.0.0.1", enabled: false)
        try await engine.addAccount(account, password: "")
        let port = await engine.localPort(of: .udp)

        func invite(_ callID: String, _ callInfo: String?) throws {
            try sendUDP({ myPort in
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
                msg += "Content-Type: application/sdp\r\nContent-Length: \(sdp.utf8.count)\r\n\r\n" + sdp
                return msg
            }, to: port)
        }
        func incoming() -> [CallInfo] {
            log.all.compactMap { if case let .incomingCall(c) = $0 { return c }; return nil }
        }

        try invite("ci-1", "<sip:127.0.0.1>;answer-after=5")
        #expect(await waitUntil { incoming().count == 1 })
        #expect(incoming().first?.answerAfter == 5)
        #expect(await engine.calls().first?.answerAfter == 5)
        try await engine.reject(try #require(incoming().first).id)

        try invite("ci-2", nil)
        #expect(await waitUntil { incoming().count == 2 })
        #expect(incoming().last?.answerAfter == nil)
        await engine.stop()
    }
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

        #expect(M.publication(.available) == (true, .unknown, nil))
        #expect(M.publication(.away) == (true, .away, nil))
        #expect(M.publication(.dnd) == (true, .busy, "Do Not Disturb"))
        #expect(M.publication(.offline).online == false)
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
