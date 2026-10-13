import Foundation
import MacroSIPCore

/// `macrosip-cli --selftest`: real calls against two local phones (pjsua CLI with
/// --auto-answer 200 and a looped tone, see scripts/selftest-call.sh). Covers RTP, hold,
/// DTMF, recording, presence, a two-leg conference, incoming calls, blind and attended
/// transfer (SelfTestCalls.swift), single-call mode, Do Not Disturb and DTMF method selection
/// (SelfTestCallOptions.swift), DTMF over SIP INFO and calls of a registered account
/// (against SIPStub). Exit 0 only when every step passed.
@MainActor
enum SelfTest {
    final class Recorder {
        var events: [EngineEvent] = []
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static func run(_ options: Options) async -> Int32 {
        let bind = options.bind == "any" ? nil : (options.bind ?? "127.0.0.1")
        let engine = Engine(logLevel: options.logLevel ?? 3, nullAudio: true, bindAddress: bind)
        let recorder = Recorder()
        let printer = Task { @MainActor in
            for await e in engine.events {
                recorder.events.append(e)
                printEvent(e)
            }
        }
        defer { printer.cancel() }

        var summary: [String] = []
        func step(_ s: String) {
            print("\(stamp()) === \(s)")
            summary.append(s)
        }

        let scratch: URL
        if let dir = options.scratch {
            scratch = URL(fileURLWithPath: dir, isDirectory: true)
        } else {
            scratch = FileManager.default.temporaryDirectory
                .appendingPathComponent("macrosip-selftest-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        }

        do {
            try await engine.start(
                network: NetworkSettings(stunServer: nil, localPort: 0, keepAliveSeconds: 15,
                                         useICE: false, echoCancellation: false),
                codecPriorities: Engine.defaultCodecOrder)
            step("engine started (null audio), SIP UDP \(bind ?? "*"):\(await engine.localPort(of: .udp))")
            try await networkAtStart(recorder, step: step)

            let account = AccountConfig(displayName: "selftest", username: "selftest", domain: "127.0.0.1",
                                        enabled: false, isDefaultOutgoing: true)
            try await engine.addAccount(account, password: "unused")
            let reg = await engine.registrationState(of: account.id)
            guard reg == .unregistered else { throw Failure(description: "disabled account state is \(reg)") }
            step("disabled account sip:selftest@127.0.0.1 added (\(describe(reg)))")

            // Presence: pjsua answers SUBSCRIBE with 200 and a NOTIFY carrying its status
            // (the script set it online with the CLI command "T 1").
            try await engine.subscribePresence(uri: options.target)
            let presence = try await waitForPresence(recorder, timeout: 5) { $0 != .offline }
            step("presence of \(options.target): \(presence.1.rawValue) (event URI \(presence.0))")
            if let cli = options.targetCLI {
                // Change pjsua's status through its telnet CLI ("T n" = pre_text): the NOTIFY
                // carries the RPID activity, which maps to away / dnd.
                var seen: [String] = []
                for (command, expected) in [("T 5", PresenceStatus.away), ("T 2", .dnd), ("T 1", .available)] {
                    let mark = recorder.events.count
                    try await pjsuaCLI(command, port: cli)
                    _ = try await waitForPresence(recorder, since: mark, timeout: 5) { $0 == expected }
                    seen.append("\(command) -> \(expected.rawValue)")
                }
                step("presence changes via NOTIFY: \(seen.joined(separator: ", "))")
            }

            guard let dial = DialString.parse(options.target, account: account) else {
                throw Failure(description: "cannot parse target \(options.target)")
            }
            let id = try await engine.makeCall(to: dial, from: account.id)
            step("calling \(dial.uri) as \(id)")

            let connected = try await waitFor(engine, id, "connected with active media", timeout: 10) {
                $0.state == .connected && $0.codec != nil
            }
            step("connected: codec \(connected.codec ?? "-"), SRTP \(connected.isSecure ? "on" : "off")")

            guard recorder.events.contains(where: {
                if case let .callChanged(c) = $0 { return c.id == id && c.codec != nil }
                return false
            }) else { throw Failure(description: "no callChanged event carried the codec") }

            // Audio must flow both ways before hold, otherwise the hold check proves nothing.
            try await Task.sleep(for: .seconds(1))
            let before = try await engine.mediaStats(id)
            guard before.rxPackets > 0, before.txPackets > 0 else {
                throw Failure(description: "no two-way RTP before hold: rx \(before.rxPackets), tx \(before.txPackets)")
            }
            step("RTP after 1 s: rx \(before.rxPackets) packets, tx \(before.txPackets) packets")

            // Hold for 2 s. The remote answers recvonly, so it stops sending: rx must stall.
            try await engine.setHold(id, true)
            _ = try await waitFor(engine, id, "held", timeout: 5) { $0.state == .held && $0.isOnHold }
            try await Task.sleep(for: .milliseconds(500))
            let rxHoldStart = try await engine.mediaStats(id).rxPackets
            try await Task.sleep(for: .seconds(2))
            let rxHoldEnd = try await engine.mediaStats(id).rxPackets
            let rxDuringHold = max(0, rxHoldEnd - rxHoldStart)
            guard rxDuringHold < 10 else {
                throw Failure(description: "remote kept sending during hold (\(rxDuringHold) packets in 2 s)")
            }
            step("hold: state held, \(rxDuringHold) RTP packets received during 2 s of hold")

            try await engine.setHold(id, false)
            let resumed = try await waitFor(engine, id, "resumed", timeout: 5) {
                $0.state == .connected && !$0.isOnHold && $0.codec != nil
            }
            step("unhold: state \(describe(resumed.state)), codec \(resumed.codec ?? "-")")

            try await networkChangeDuringCall(engine, recorder, id, step: step)

            try await engine.sendDTMF(id, "1#")
            step("DTMF \"1#\" sent")

            // Recording: 3 s of the call into a WAV.
            let wav = scratch.appendingPathComponent("recordings/call1.wav")
            try await engine.startRecording(id, to: wav)
            _ = try await waitFor(engine, id, "isRecording", timeout: 2) { $0.isRecording }
            try await Task.sleep(for: .seconds(3))
            let stats = try await engine.mediaStats(id)
            guard stats.rxPackets > 0, stats.txPackets > 0 else {
                throw Failure(description: "no two-way RTP: rx \(stats.rxPackets), tx \(stats.txPackets)")
            }
            step("RTP after 3 s: rx \(stats.rxPackets) packets (lost \(stats.rxLost)), tx \(stats.txPackets) packets")
            let stopped = try await engine.stopRecording(id)
            guard stopped == RecordingFiles(layout: .mono, mixed: wav) else {
                throw Failure(description: "stopRecording returned \(stopped)")
            }
            _ = try await waitFor(engine, id, "isRecording cleared", timeout: 2) { !$0.isRecording }
            let header = try checkWAV(wav, minBytes: 50_000)
            step("recording: \(wav.lastPathComponent) \(header.fileSize) bytes, \(header.sampleRate) Hz, "
                 + "\(header.dataSize) data bytes, RMS \(header.rms) (remote tone captured)")

            // What the app does next: WAV -> M4A (AAC).
            let m4a = wav.deletingPathExtension().appendingPathExtension("m4a")
            try await RecordingConverter.convert(wav: wav, to: m4a)
            let m4aSize = (try? FileManager.default.attributesOfItem(atPath: m4a.path))?[.size] as? Int ?? 0
            guard m4aSize > 1_000 else { throw Failure(description: "M4A \(m4a.lastPathComponent): \(m4aSize) bytes") }
            step("M4A conversion: \(m4a.lastPathComponent) \(m4aSize) bytes")

            // Call quality: all-time values first, then the window across the stereo recording.
            let allTime = try await engine.quality(of: id)
            try await stereoRecording(engine, id, scratch: scratch, step: step)
            let quality = try await engine.quality(of: id)
            guard quality.level == .good, allTime.level == .good else {
                throw Failure(description: "loopback call quality not good: all-time \(allTime), window \(quality)")
            }
            step(String(format: "quality: MOS %.2f (%@), loss %.1f %%, jitter %.1f ms, RTT %.1f ms (all-time MOS %.2f)",
                        quality.mos, quality.level.rawValue, quality.lossPercent, quality.jitterMs,
                        quality.rttMs, allTime.mos))

            // Conference: hold the first call (as the UI does), dial the second, merge.
            try await engine.setHold(id, true)
            _ = try await waitFor(engine, id, "held before second call", timeout: 5) { $0.state == .held }
            guard let dial2 = DialString.parse(options.target2, account: account) else {
                throw Failure(description: "cannot parse target \(options.target2)")
            }
            let id2 = try await engine.makeCall(to: dial2, from: account.id)
            _ = try await waitFor(engine, id2, "second call connected", timeout: 10) {
                $0.state == .connected && $0.codec != nil
            }
            step("second call \(dial2.uri) as \(id2) connected; first call held")

            try await engine.merge([id, id2])
            for leg in [id, id2] {
                _ = try await waitFor(engine, leg, "conference leg connected", timeout: 5) {
                    $0.state == .connected && $0.inConference && $0.codec != nil
                }
            }
            let wavConf = scratch.appendingPathComponent("recordings/conference.wav")
            try await engine.startRecording(id, to: wavConf)
            try await Task.sleep(for: .milliseconds(500))
            let s1 = try await engine.mediaStats(id), s2 = try await engine.mediaStats(id2)
            try await Task.sleep(for: .seconds(3))
            let e1 = try await engine.mediaStats(id), e2 = try await engine.mediaStats(id2)
            for (name, a, b) in [("leg 1", s1, e1), ("leg 2", s2, e2)] {
                guard b.rxPackets - a.rxPackets > 50, b.txPackets - a.txPackets > 50 else {
                    throw Failure(description: "\(name) RTP stalled in the conference: rx +\(b.rxPackets - a.rxPackets), "
                                  + "tx +\(b.txPackets - a.txPackets) in 3 s")
                }
            }
            let legs = await engine.calls()
            guard legs.count == 2, legs.allSatisfy({ $0.inConference && $0.state == .connected }) else {
                throw Failure(description: "calls() after merge: \(legs.map { describe($0) })")
            }
            step("conference: 3 s, leg 1 rx +\(e1.rxPackets - s1.rxPackets) tx +\(e1.txPackets - s1.txPackets), "
                 + "leg 2 rx +\(e2.rxPackets - s2.rxPackets) tx +\(e2.txPackets - s2.txPackets); both inConference")

            // Split the recorded leg: the recording belongs to the conference and moves to the
            // remaining leg (same file, which keeps growing).
            try await engine.split(id)
            for leg in [id, id2] {
                _ = try await waitFor(engine, leg, "out of the conference after split", timeout: 3) { !$0.inConference }
            }
            _ = try await waitFor(engine, id2, "recording moved to the remaining leg", timeout: 3) { $0.isRecording }
            _ = try await waitFor(engine, id, "recording left the split leg", timeout: 3) { !$0.isRecording }
            let sizeBefore = fileSize(wavConf)
            try await Task.sleep(for: .milliseconds(1500))
            let sizeAfter = fileSize(wavConf)
            guard sizeAfter > sizeBefore + 16_000 else {
                throw Failure(description: "conference WAV stopped growing after the move: \(sizeBefore) -> \(sizeAfter) bytes")
            }
            step("split recorded leg \(id): both out of the conference, recording moved to \(id2), "
                 + "WAV grew \(sizeBefore) -> \(sizeAfter) bytes in 1.5 s")

            // Hang up everything; the recording's current owner reports isRecording in its
            // .callEnded and the WAV is complete when that event arrives.
            await engine.hangupAll()
            let ended = try await waitForEnd(recorder, id2, timeout: 5)
            let endedOld = try await waitForEnd(recorder, id, timeout: 5)
            guard ended.0.isRecording, !endedOld.0.isRecording else {
                throw Failure(description: "callEnded isRecording: owner \(ended.0.isRecording), old owner \(endedOld.0.isRecording)")
            }
            let confHeader = try checkWAV(wavConf, minBytes: 50_000)
            step("hung up all: callEnded \(describe(ended.0.state)), duration \(String(format: "%.1f", ended.1)) s, "
                 + "isRecording on \(id2) only; conference WAV \(confHeader.fileSize) bytes finalised")

            // Incoming calls and transfers: the pjsua phones are driven through their CLIs.
            let context = Context(engine: engine, recorder: recorder, account: account, options: options)
            try await gsmCall(context, step: step)
            if let cli1 = options.targetCLI {
                try await incomingCalls(context, cli: cli1, step: step)
                try await singleCallMode(context, cli: cli1, step: step)
                try await doNotDisturb(context, cli: cli1, step: step)
                try await denyIncoming(context, cli: cli1, step: step)
                if let cli2 = options.target2CLI {
                    try await blindTransfer(context, cli1: cli1, cli2: cli2, step: step)
                    try await attendedTransfer(context, cli1: cli1, cli2: cli2, step: step)
                }
            }

            // A SIP stub (registrar + PBX-like answering side) for what pjsua cannot show.
            let stub = try SIPStub()
            defer { stub.stop() }
            try await dtmfInfo(context, stub: stub, step: step)
            try await dtmfMethods(context, stub: stub, step: step)
            try await registeredCalls(context, stub: stub, step: step)

            try await engine.unsubscribePresence(uri: options.target)
            await engine.stop()
            step("engine stopped")
        } catch {
            print("\(stamp()) SELFTEST FAILED: \(error)")
            await engine.stop()
            return 1
        }

        print("\n==== macrosip-cli selftest PASSED ====")
        for (i, s) in summary.enumerated() { print("  \(i + 1). \(s)") }
        return 0
    }

    /// Polls `engine.calls()` until `condition` holds for the call.
    static func waitFor(_ engine: Engine, _ id: CallID, _ what: String, timeout: Double,
                        _ condition: (CallInfo) -> Bool) async throws -> CallInfo {
        let deadline = Date().addingTimeInterval(timeout)
        var last: CallInfo?
        while Date() < deadline {
            if let c = await engine.calls().first(where: { $0.id == id }) {
                last = c
                if condition(c) { return c }
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        let state = last.map { describe($0) } ?? "call gone"
        throw Failure(description: "timeout after \(Int(timeout)) s waiting for \(what); last: \(state)")
    }

    static func waitForEnd(_ recorder: Recorder, _ id: CallID, timeout: Double) async throws -> (CallInfo, TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            for e in recorder.events {
                if case let .callEnded(c, d) = e, c.id == id { return (c, d) }
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw Failure(description: "no callEnded event within \(Int(timeout)) s")
    }

    /// Waits for a `.buddyPresence` event (at index `since` or later) whose status matches.
    static func waitForPresence(_ recorder: Recorder, since: Int = 0, timeout: Double,
                                _ condition: (PresenceStatus) -> Bool) async throws -> (String, PresenceStatus) {
        let deadline = Date().addingTimeInterval(timeout)
        var seen: [PresenceStatus] = []
        while Date() < deadline {
            let events = recorder.events.dropFirst(since)
            seen = events.compactMap { if case let .buddyPresence(_, st, _) = $0 { return st }; return nil }
            for e in events {
                if case let .buddyPresence(uri, st, _) = e, condition(st) { return (uri, st) }
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw Failure(description: "no matching buddyPresence within \(Int(timeout)) s; seen \(seen.map(\.rawValue))")
    }

    /// Sends one command to a pjsua telnet CLI on 127.0.0.1 and returns what the CLI printed
    /// after it (printable text; telnet negotiation and log lines included, banner skipped).
    @discardableResult
    static func pjsuaCLI(_ command: String, port: UInt16) async throws -> String {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure(description: "socket: \(errno)") }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port.bigEndian)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard rc == 0 else { throw Failure(description: "pjsua CLI on port \(port): connect errno \(errno)") }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        func drain() -> [UInt8] {
            var out: [UInt8] = []
            var buf = [UInt8](repeating: 0, count: 4096)
            while true {
                let n = read(fd, &buf, buf.count)
                guard n > 0 else { break }
                out += buf[0..<n]
            }
            return out
        }
        try await Task.sleep(for: .milliseconds(300))      // banner and option negotiation
        _ = drain()
        let bytes = Array((command + "\r\n").utf8)
        guard write(fd, bytes, bytes.count) == bytes.count else {
            throw Failure(description: "pjsua CLI on port \(port): write errno \(errno)")
        }
        try await Task.sleep(for: .milliseconds(300))      // let pjsua run it before we hang up
        let output = drain().filter { $0 == 10 || (32..<127).contains($0) }
        return String(decoding: output, as: UTF8.self)
    }

    static func fileSize(_ url: URL) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int ?? 0
    }

    struct WAVHeader {
        var fileSize: Int
        var sampleRate: UInt32
        var dataSize: UInt32
        var rms: Int
    }

    /// RIFF/WAVE PCM header with sizes that match the file, at least `minBytes`, not silent
    /// (RMS > 300); with `silent` the RMS must be below 50 instead.
    static func checkWAV(_ url: URL, minBytes: Int, silent: Bool = false) throws -> WAVHeader {
        guard let data = try? Data(contentsOf: url) else { throw Failure(description: "no file \(url.path)") }
        guard data.count >= 44, data[0..<4] == Data("RIFF".utf8), data[8..<12] == Data("WAVE".utf8),
              data[12..<16] == Data("fmt ".utf8), data[36..<40] == Data("data".utf8) else {
            throw Failure(description: "\(url.lastPathComponent): not a RIFF/WAVE PCM file")
        }
        func u32(_ o: Int) -> UInt32 { (0..<4).reduce(0) { $0 | UInt32(data[o + $1]) << (8 * UInt32($1)) } }
        let riff = u32(4), rate = u32(24), dataSize = u32(40)
        guard dataSize > 0, Int(dataSize) == data.count - 44, Int(riff) == data.count - 8 else {
            throw Failure(description: "\(url.lastPathComponent): header not final (RIFF \(riff), data \(dataSize), file \(data.count))")
        }
        guard data.count > minBytes else {
            throw Failure(description: "\(url.lastPathComponent): only \(data.count) bytes")
        }
        var sum = 0.0
        var n = 0
        var i = 44
        while i + 1 < data.count {
            let v = Double(Int16(bitPattern: UInt16(data[i]) | UInt16(data[i + 1]) << 8))
            sum += v * v
            n += 1
            i += 2
        }
        let rms = n > 0 ? Int((sum / Double(n)).squareRoot()) : 0
        if silent {
            guard rms < 50 else { throw Failure(description: "\(url.lastPathComponent): not silent (RMS \(rms))") }
        } else {
            guard rms > 300 else { throw Failure(description: "\(url.lastPathComponent): silent (RMS \(rms))") }
        }
        return WAVHeader(fileSize: data.count, sampleRate: rate, dataSize: dataSize, rms: rms)
    }
}
