import Foundation
import Testing
@testable import MacroSIPCore

// Release 26.1 audio: call quality, per-call and ringtone volume, Opus FEC/DTX.

@Suite("Engine audio helpers")
struct EngineAudioHelperTests {
    struct MOSCase: Sendable, CustomTestStringConvertible {
        var codec: String
        var loss: Double
        var jitter: Double
        var rtt: Double
        var level: QualityLevel
        var testDescription: String { "\(codec) \(loss) % / \(jitter) ms / rtt \(rtt) ms -> \(level)" }
    }

    static let mosCases: [MOSCase] = [
        MOSCase(codec: "opus/48000/2", loss: 0, jitter: 10, rtt: 0, level: .good),
        MOSCase(codec: "opus/48000/2", loss: 5, jitter: 40, rtt: 0, level: .fair),
        MOSCase(codec: "opus/48000/2", loss: 15, jitter: 100, rtt: 0, level: .poor),
        MOSCase(codec: "G722/16000/1", loss: 0, jitter: 10, rtt: 0, level: .good),
        MOSCase(codec: "G722/16000/1", loss: 5, jitter: 40, rtt: 0, level: .fair),
        MOSCase(codec: "G722/16000/1", loss: 15, jitter: 100, rtt: 0, level: .poor),
        MOSCase(codec: "PCMU/8000", loss: 0, jitter: 10, rtt: 0, level: .good),
        MOSCase(codec: "PCMA/8000", loss: 5, jitter: 40, rtt: 0, level: .fair),
        MOSCase(codec: "PCMU/8000", loss: 15, jitter: 100, rtt: 0, level: .poor),
        MOSCase(codec: "opus/48000/2", loss: 0, jitter: 5, rtt: 600, level: .fair),   // long delay alone
    ]

    @Test(arguments: mosCases)
    func mosTable(_ c: MOSCase) {
        let mos = CallQualityModel.mos(lossPercent: c.loss, jitterMs: c.jitter, rttMs: c.rtt, codec: c.codec)
        #expect((1.0...4.5).contains(mos))
        #expect(CallQualityModel.level(mos: mos) == c.level, "MOS \(mos)")
    }

    @Test func mosBoundsAndOrdering() {
        // Base values: Opus/G.722 ~4.4, G.711 ~4.1 (minus 20 ms packetisation delay).
        let opus = CallQualityModel.mos(lossPercent: 0, jitterMs: 0, rttMs: 0, codec: "opus/48000/2")
        let pcmu = CallQualityModel.mos(lossPercent: 0, jitterMs: 0, rttMs: 0, codec: "PCMU/8000")
        #expect(abs(opus - 4.4) < 0.03 && abs(pcmu - 4.1) < 0.05, "opus \(opus), pcmu \(pcmu)")
        #expect(CallQualityModel.mos(lossPercent: 100, jitterMs: 500, rttMs: 2000, codec: nil) == 1)
        #expect(CallQualityModel.level(mos: 3.8) == .good && CallQualityModel.level(mos: 3.79) == .fair)
        #expect(CallQualityModel.level(mos: 3.0) == .fair && CallQualityModel.level(mos: 2.99) == .poor)
        var last = 5.0
        for loss in stride(from: 0.0, through: 30, by: 2) {
            let m = CallQualityModel.mos(lossPercent: loss, jitterMs: 20, rttMs: 50, codec: "opus")
            #expect(m < last)
            last = m
        }
        for r in stride(from: 0.0, through: 100, by: 5) {
            #expect(abs(CallQualityModel.r(mos: CallQualityModel.mos(r: r)) - r) < 0.01 || r == 0 || r == 100)
        }
    }

    @Test func qualityWindow() {
        let s1 = QualitySample(rxPackets: 1000, rxLost: 10, jitterMeanMs: 4, jitterLastMs: 6, rttMs: 0)
        // First call: all-time loss (10 of 1010) and mean jitter.
        let first = CallQualityModel.window(previous: nil, current: s1)
        #expect(abs((first.lossPercent ?? -1) - 100 * 10.0 / 1010) < 1e-9 && first.jitterMs == 4)
        // Next window: 90 received, 10 lost -> 10 %, latest jitter.
        let s2 = QualitySample(rxPackets: 1090, rxLost: 20, jitterMeanMs: 5, jitterLastMs: 12, rttMs: 30)
        let next = CallQualityModel.window(previous: s1, current: s2)
        #expect(abs((next.lossPercent ?? -1) - 10) < 1e-9 && next.jitterMs == 12)
        // No packets in the window: no loss figure, reported as poor.
        #expect(CallQualityModel.window(previous: s2, current: s2).lossPercent == nil)
        let silent = CallQualityModel.quality(previous: s2, current: s2, codec: "opus/48000")
        #expect(silent.level == .poor && silent.mos == 1 && silent.lossPercent == 100)
        let nothingYet = QualitySample(rxPackets: 0, rxLost: 0, jitterMeanMs: 0, jitterLastMs: 0, rttMs: 0)
        #expect(CallQualityModel.quality(previous: nil, current: nothingYet, codec: nil).level == .poor)
        // rxLost went down (a late packet after reordering): the window's loss clamps at 0, the
        // delta of received packets still counts (no switch to the all-time values).
        let s2b = QualitySample(rxPackets: 1190, rxLost: 18, jitterMeanMs: 5, jitterLastMs: 7, rttMs: 30)
        let reordered = CallQualityModel.window(previous: s2, current: s2b)
        #expect(reordered.lossPercent == 0 && reordered.jitterMs == 7)
        // Packet counter went back (stream recreated): all-time values of the new stream.
        let s3 = QualitySample(rxPackets: 50, rxLost: 0, jitterMeanMs: 2, jitterLastMs: 3, rttMs: 0)
        let reset = CallQualityModel.window(previous: s2, current: s3)
        #expect(reset.lossPercent == 0 && reset.jitterMs == 2)
        let q = CallQualityModel.quality(previous: s1, current: s2, codec: "opus/48000")
        #expect(q.rttMs == 30 && q.lossPercent == 10 && q.level == CallQualityModel.level(mos: q.mos))
        // Volume clamping.
        #expect(CallVolume.clamp(-1) == 0 && CallVolume.clamp(3) == 2 && CallVolume.clamp(.nan) == 1
                && CallVolume.clamp(0.5) == 0.5)
        // Codec options decode from JSON written before a field existed.
        let decoded = try? JSONDecoder().decode(CodecOptions.self, from: Data("{}".utf8))
        #expect(decoded == CodecOptions(opusFEC: true, opusDTX: false))
    }
}

// MARK: - tests that run pjsua (part of the serialized "Engine (pjsua)" suite)

extension EngineTests {
    /// Loopback call: default call volume, per-call speaker/microphone gain measured on the
    /// bridge (a tone played into one leg), the gain surviving hold/resume, and the quality of
    /// a clean loopback call.
    @Test func loopbackCallVolumeAndQuality() async throws {
        let engine = await makeEngine()
        let log = EventLog()
        let consumer = log.consume(engine)
        defer { consumer.cancel() }
        try await engine.start(network: Self.network)
        await engine.setDefaultCallVolume(speaker: 0.5, microphone: 1.5)
        let account = AccountConfig(displayName: "L", username: "loop", domain: "127.0.0.1", enabled: false)
        try await engine.addAccount(account, password: "")
        let port = await engine.localPort(of: .udp)
        let out = try await engine.makeCall(to: DialString(uri: "sip:v@127.0.0.1:\(port)", display: "v"),
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
        // Every new call starts with the default.
        #expect(await waitUntil { await engine.callLevels(of: out) == CallVolume(speaker: 0.5, microphone: 1.5) })
        #expect(await engine.callLevels(of: inc) == CallVolume(speaker: 0.5, microphone: 1.5))

        try await engine.setCallVolume(out, speaker: 1, microphone: 1)
        try await engine.setCallVolume(inc, speaker: 1, microphone: 1)
        #expect(await engine.callLevels(of: out) == CallVolume(speaker: 1, microphone: 1))

        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let tone = dir.appendingPathComponent("tone.wav")
        try RecordingConverterTests.sineWAV(seconds: 2, frequency: 600).write(to: tone)
        let player = try await engine.startTestPlayer(tone, into: inc)

        func speaker() async -> Int { await engine.speakerSignal() ?? -1 }
        /// True when every sample of the speaker level over `ms` satisfies `ok` (after settling).
        func steady(settle: Int = 400, ms: Int = 600, _ ok: (Int) -> Bool) async throws -> Bool {
            try await Task.sleep(for: .milliseconds(settle))
            for _ in 0..<(ms / 100) {
                guard ok(await speaker()) else { return false }
                try await Task.sleep(for: .milliseconds(100))
            }
            return true
        }
        /// RMS of a 1 s mono recording of `out` (the remote tone plus our silent microphone).
        func recordedRMS(_ name: String) async throws -> Int {
            let wav = dir.appendingPathComponent(name)
            try await engine.startRecording(out, to: wav)
            try await Task.sleep(for: .seconds(1))
            let files = try await engine.stopRecording(out)
            return try wavRMS(try #require(files.mixed))
        }
        // Unity: the tone sent by `inc` arrives on `out` and plays on the speaker (slot 0).
        #expect(await waitUntil { await speaker() > 40 })
        let unity = await speaker()
        let rmsUnity = try await recordedRMS("unity.wav")
        #expect(rmsUnity > 300, "RMS \(rmsUnity)")

        // Speaker 0 on `out`: the speaker gets silence, the recording of `out` does not change.
        try await engine.setCallVolume(out, speaker: 0, microphone: 1)
        #expect(await engine.callLevels(of: out)?.speaker == 0)
        #expect(try await steady(settle: 100) { $0 == 0 })
        let rmsSilent = try await recordedRMS("speaker0.wav")
        #expect(Double(rmsSilent) > Double(rmsUnity) * 0.7 && Double(rmsSilent) < Double(rmsUnity) * 1.3,
                "RMS at speaker 1: \(rmsUnity), at speaker 0: \(rmsSilent)")
        try await engine.setCallVolume(out, speaker: 1, microphone: 1)
        #expect(await waitUntil { await speaker() > 40 })

        // Microphone 0 on `inc`: the level of the microphone -> call connection only.
        try await engine.setCallVolume(inc, speaker: 1, microphone: 0)
        #expect(await engine.callLevels(of: inc) == CallVolume(speaker: 1, microphone: 0))
        try await engine.setMute(inc, true)                // no microphone connection while muted
        #expect(await engine.callLevels(of: inc)?.microphone == 0)
        try await engine.setMute(inc, false)               // unmuted: connected again at level 0
        #expect(await engine.callLevels(of: inc) == CallVolume(speaker: 1, microphone: 0))
        #expect(await waitUntil { await engine.wiring(of: inc)?.fromMic == true })
        try await engine.setCallVolume(inc, speaker: 1, microphone: 1)
        // A louder speaker gain is measurably louder.
        try await engine.setCallVolume(out, speaker: 2, microphone: 1)
        #expect(await waitUntil { await speaker() > unity })

        // Hold and resume: the per-call gain is applied again to the (possibly new) port.
        try await engine.setCallVolume(out, speaker: 0.25, microphone: 0.75)
        try await engine.setHold(out, true)
        #expect(await waitUntil { await engine.calls().first { $0.id == out }?.state == .held })
        try await engine.setHold(out, false)
        #expect(await waitUntil {
            let c = await engine.calls().first { $0.id == out }
            return c?.state == .connected && c?.codec != nil
        })
        #expect(await waitUntil { await engine.callLevels(of: out) == CallVolume(speaker: 0.25, microphone: 0.75) })
        await #expect(throws: EngineError.self) {
            try await engine.setCallVolume(CallID(raw: 7, serial: 999_999), speaker: 1, microphone: 1)
        }

        // Quality of a clean loopback call: no loss, good. The resume may have recreated the
        // stream (counters start at 0, and a window without packets is poor), so let RTP flow.
        try await engine.setCallVolume(out, speaker: 1, microphone: 1)
        try await Task.sleep(for: .milliseconds(500))
        let first = try await engine.quality(of: out)
        #expect(first.level == .good && first.lossPercent == 0, "\(first)")
        try await Task.sleep(for: .seconds(1))
        let window = try await engine.quality(of: out)
        #expect(window.level == .good && window.lossPercent == 0 && window.mos >= 4.0, "\(window)")

        await engine.stopTestPlayer(player)
        try await engine.hangup(out)
        #expect(await waitUntil { await engine.calls().isEmpty })
        await #expect(throws: EngineError.self) { try await engine.quality(of: out) }
        await engine.pruneEndedCallState()
        #expect(await engine.callVolumes.isEmpty)
        #expect(await engine.qualitySamples.isEmpty)
        await engine.stop()
    }

    /// The ringtone volume is kept across start/stop of the ringtone and applied live; volume
    /// 0 makes the bridge receive silence from the ringtone port.
    @Test func ringtoneVolume() async throws {
        let engine = await makeEngine()
        let log = EventLog()
        let consumer = log.consume(engine)
        defer { consumer.cancel() }
        await engine.setRingtoneVolume(0.3)                 // before start: remembered
        try await engine.start(network: Self.network)
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let tone = dir.appendingPathComponent("ring.wav")
        try RecordingConverterTests.sineWAV(seconds: 1, frequency: 500).write(to: tone)
        await engine.setRingtoneFile(tone)                  // continuous, unlike the 2 s on / 4 s off tone
        let account = AccountConfig(displayName: "L", username: "loop", domain: "127.0.0.1", enabled: false)
        try await engine.addAccount(account, password: "")
        let port = await engine.localPort(of: .udp)

        func ring() async throws -> (CallID, CallID) {
            let before = log.all.count
            let out = try await engine.makeCall(to: DialString(uri: "sip:r@127.0.0.1:\(port)", display: "r"),
                                                from: account.id)
            func incoming() -> CallID? {
                log.all.dropFirst(before).lazy.compactMap { if case let .incomingCall(c) = $0 { return c.id }; return nil }.first
            }
            #expect(await waitUntil { incoming() != nil })
            return (out, try #require(incoming()))
        }
        let (out, inc) = try await ring()
        #expect(await waitUntil { await engine.ringtoneState() != nil })
        let v = try #require(await engine.ringtoneState()?.volume)
        #expect(abs(v - 0.3) < 0.001)
        #expect(await waitUntil { (await engine.ringtoneState()?.level ?? 0) > 20 })
        await engine.setRingtoneVolume(0)
        #expect(await engine.ringtoneState()?.volume == 0)
        try await Task.sleep(for: .milliseconds(200))
        #expect(await engine.ringtoneState()?.level == 0)
        await engine.setRingtoneVolume(1)
        #expect(await waitUntil { (await engine.ringtoneState()?.level ?? 0) > 20 })
        await engine.setRingtoneVolume(5)                   // clamped to 1
        #expect(await engine.ringtoneState()?.volume == 1)
        await engine.setRingtoneVolume(0.6)
        try await engine.reject(inc)
        #expect(await waitUntil { await engine.ringtoneState() == nil })
        _ = out

        // The next ringtone starts at the remembered volume; restarting it keeps it too.
        let (out2, inc2) = try await ring()
        #expect(await waitUntil { await engine.ringtoneState() != nil })
        #expect(abs((await engine.ringtoneState()?.volume ?? -1) - 0.6) < 0.001)
        await engine.setRingtoneFile(nil)                   // restarts the ringtone (generated tone)
        #expect(await waitUntil { await engine.ringtoneState() != nil })
        #expect(abs((await engine.ringtoneState()?.volume ?? -1) - 0.6) < 0.001)
        try await engine.hangup(out2)
        _ = inc2
        #expect(await waitUntil {
            let idle = await engine.calls().isEmpty
            let ringing = await engine.ringtoneState() != nil
            return idle && !ringing
        })
        await engine.stop()
    }

    /// Opus FEC/DTX at start and live, read back from PJSIP's Opus config and default
    /// codec parameters; a call still connects with Opus afterwards.
    @Test func codecOptionsApplied() async throws {
        let engine = await makeEngine()
        let log = EventLog()
        let consumer = log.consume(engine)
        defer { consumer.cancel() }
        await #expect(throws: EngineError.notStarted) { try await engine.setCodecOptions(CodecOptions()) }

        // Old signature: defaults (FEC on, DTX off).
        try await engine.start(network: Self.network, codecPriorities: Engine.defaultCodecOrder)
        var o = try #require(await engine.opusOptions())
        #expect(o.packetLoss == 10 && o.paramPacketLoss == 10 && !o.dtx && o.plc, "\(o)")
        #expect(o.fmtp.contains("useinbandfec=1") && !o.fmtp.contains("usedtx"), "\(o.fmtp)")

        try await engine.setCodecOptions(CodecOptions(opusFEC: false, opusDTX: true))
        o = try #require(await engine.opusOptions())
        #expect(o.packetLoss == 0 && o.paramPacketLoss == 0 && o.dtx && o.plc, "\(o)")
        #expect(o.fmtp.contains("usedtx=1") && o.fmtp.contains("useinbandfec=1"), "\(o.fmtp)")
        await engine.stop()

        try await engine.start(network: Self.network, codecPriorities: [],
                               codecOptions: CodecOptions(opusFEC: true, opusDTX: true))
        o = try #require(await engine.opusOptions())
        #expect(o.packetLoss == 10 && o.dtx, "\(o)")

        // A call with these options still negotiates Opus and carries audio.
        let account = AccountConfig(displayName: "L", username: "loop", domain: "127.0.0.1", enabled: false)
        try await engine.addAccount(account, password: "")
        let port = await engine.localPort(of: .udp)
        let out = try await engine.makeCall(to: DialString(uri: "sip:c@127.0.0.1:\(port)", display: "c"),
                                            from: account.id)
        func incoming() -> CallID? {
            log.all.lazy.compactMap { if case let .incomingCall(c) = $0 { return c.id }; return nil }.first
        }
        #expect(await waitUntil { incoming() != nil })
        try await engine.answer(try #require(incoming()))
        #expect(await waitUntil {
            let c = await engine.calls().first { $0.id == out }
            return c?.state == .connected && c?.codec?.lowercased().hasPrefix("opus") == true
        })
        try await engine.setCodecOptions(CodecOptions())   // live change during a call
        o = try #require(await engine.opusOptions())
        #expect(o.packetLoss == 10 && !o.dtx)
        try await engine.hangup(out)
        #expect(await waitUntil { await engine.calls().isEmpty })
        await engine.stop()
    }
}

// MARK: - echo canceller choice

extension EngineAudioHelperTests {
    @Test func audioProcessingPolicy() {
        let devices = [
            AudioDevice(id: 0, name: "Speakers", inputChannels: 0, outputChannels: 2),
            AudioDevice(id: 1, name: "Microphone", inputChannels: 1, outputChannels: 0),
            AudioDevice(id: 2, name: "Headset", inputChannels: 1, outputChannels: 2),
        ]
        func mode(_ i: String?, _ o: String?, ec: Bool = true, defIn: String? = "Microphone",
                  defOut: String? = "Speakers") -> AudioProcessingMode {
            AudioProcessingPolicy.mode(echoCancellation: ec, inputName: i, outputName: o, devices: devices,
                                       defaultInput: defIn, defaultOutput: defOut)
        }
        #expect(mode(nil, nil) == .systemVoiceProcessing)
        #expect(mode("Microphone", "Speakers") == .systemVoiceProcessing)          // selected = default
        #expect(mode("Gone USB Mic", "Gone Speakers") == .systemVoiceProcessing)    // absent = default
        #expect(mode(nil, "Headset") == .softwareEchoCanceller(input: "Microphone", output: "Headset"))
        #expect(mode("Headset", nil) == .softwareEchoCanceller(input: "Headset", output: "Speakers"))
        #expect(mode("Headset", "Headset") == .softwareEchoCanceller(input: "Headset", output: "Headset"))
        // The headset became the system default: back to VoiceProcessingIO.
        #expect(mode("Headset", "Headset", defIn: "Headset", defOut: "Headset") == .systemVoiceProcessing)
        // "Speakers" cannot capture: an input selection by that name is no input selection.
        #expect(mode("Speakers", nil) == .systemVoiceProcessing)
        #expect(mode(nil, "Headset", defIn: nil) == .softwareEchoCanceller(input: "System default", output: "Headset"))
        #expect(mode(nil, "Headset", ec: false) == .echoCancellationOff)
        #expect(AudioProcessingPolicy.describe(.softwareEchoCanceller(input: "A", output: "B"))
                == "software echo canceller on A / B")
    }
}

extension EngineTests {
    /// Real CoreAudio devices (nothing is opened without a call): the default selection uses
    /// VoiceProcessingIO; a non-default output by name switches to the software canceller and
    /// back. Skips the switch when this Mac has no second output or input device.
    @Test func audioProcessingModeFollowsDeviceSelection() async throws {
        await stopLeakedEngine()
        let engine = Engine(logLevel: 1, nullAudio: false, bindAddress: "127.0.0.1", caBundleURL: tempCABundle(),
                            monitorNetwork: false)
        let log = EventLog()
        let consumer = log.consume(engine)
        defer { consumer.cancel() }
        try await engine.start(network: Self.network)
        func announced(_ text: String) -> Bool {
            log.all.contains { if case let .log(_, t) = $0 { return t.contains("audio: \(text)") }; return false }
        }
        #expect(await engine.audioProcessingMode() == .systemVoiceProcessing)
        #expect(await engine.appliedSoftwareEC == false)
        #expect(await waitUntil { announced("VoiceProcessingIO") })

        let devices = await engine.audioDevices()
        let defaultIn = SystemAudioDefaults.deviceName(input: true)
        let defaultOut = SystemAudioDefaults.deviceName(input: false)
        // Selecting the default device by name is still the default.
        if let defaultOut, devices.contains(where: { $0.name == defaultOut && $0.outputChannels > 0 }) {
            try await engine.setAudioDevices(inputName: nil, outputName: defaultOut)
            #expect(await engine.audioProcessingMode() == .systemVoiceProcessing)
        }
        let otherOut = devices.first { $0.outputChannels > 0 && $0.name != defaultOut }
        let otherIn = devices.first { $0.inputChannels > 0 && $0.name != defaultIn }
        if let otherOut {
            try await engine.setAudioDevices(inputName: nil, outputName: otherOut.name)
            #expect(await engine.audioProcessingMode()
                    == .softwareEchoCanceller(input: defaultIn ?? "System default", output: otherOut.name))
            #expect(await engine.appliedSoftwareEC == true)
            #expect(await waitUntil { announced("software echo canceller on") })
        } else if let otherIn {
            try await engine.setAudioDevices(inputName: otherIn.name, outputName: nil)
            #expect(await engine.audioProcessingMode()
                    == .softwareEchoCanceller(input: otherIn.name, output: defaultOut ?? "System default"))
            #expect(await engine.appliedSoftwareEC == true)
        } else if let realOut = devices.first(where: { $0.outputChannels > 0 }) {
            // One input and one output: select the output by name and pretend another device
            // is the system default, so the software canceller is applied (idle, nothing opens).
            try await engine.setAudioDevices(inputName: nil, outputName: realOut.name)
            await engine.overrideDefaultDeviceNames(input: defaultIn, output: "Not this device")
            #expect(await engine.audioProcessingMode()
                    == .softwareEchoCanceller(input: defaultIn ?? "System default", output: realOut.name))
            #expect(await engine.appliedSoftwareEC == true)
            #expect(await waitUntil { announced("software echo canceller on") })
            await engine.overrideDefaultDeviceNames(input: defaultIn, output: realOut.name)
            #expect(await engine.audioProcessingMode() == .systemVoiceProcessing)
            #expect(await engine.appliedSoftwareEC == false)
            await engine.overrideDefaultDeviceNames(input: defaultIn, output: defaultOut)
        }
        try await engine.setAudioDevices(inputName: nil, outputName: nil)
        #expect(await engine.audioProcessingMode() == .systemVoiceProcessing)
        #expect(await engine.appliedSoftwareEC == false)
        await engine.stop()

        // Echo cancellation off: neither.
        let off = NetworkSettings(stunServer: nil, localPort: 0, keepAliveSeconds: 15, useICE: false,
                                  echoCancellation: false)
        try await engine.start(network: off)
        #expect(await engine.audioProcessingMode() == .echoCancellationOff)
        await engine.stop()
    }
}

extension EngineTests {
    /// A mid-call reopen for the other echo canceller that fails (device and system defaults
    /// unusable; the opens are stubbed, so no real device is touched) leaves the bridge on
    /// the null sound device: RTP keeps flowing, the error is announced, and the applied state
    /// is cleared so the next device event retries.
    @Test func failedReopenKeepsTheClockRunning() async throws {
        let engine = await makeEngine()
        let log = EventLog()
        let consumer = log.consume(engine)
        defer { consumer.cancel() }
        try await engine.start(network: Self.network)
        let account = AccountConfig(displayName: "L", username: "loop", domain: "127.0.0.1", enabled: false)
        try await engine.addAccount(account, password: "")
        let port = await engine.localPort(of: .udp)
        let out = try await engine.makeCall(to: DialString(uri: "sip:f@127.0.0.1:\(port)", display: "f"),
                                            from: account.id)
        func incoming() -> CallID? {
            log.all.lazy.compactMap { if case let .incomingCall(c) = $0 { return c.id }; return nil }.first
        }
        #expect(await waitUntil { incoming() != nil })
        try await engine.answer(try #require(incoming()))
        #expect(await waitUntil {
            let c = await engine.calls().first { $0.id == out }
            return c?.state == .connected && c?.codec != nil
        })
        await #expect(throws: EngineError.self) {
            // Both opens fail without touching a device (a test must not open the microphone).
            try await engine.switchEchoCanceller(software: true, capture: 0, playback: 0, throwing: true,
                                                 forceOpen: true) { _, _ in 70_013 }   // PJ_EINVALIDOP
        }
        #expect(log.all.contains { if case let .log(1, t) = $0 { return t.contains("engine: audio error:") }; return false })
        #expect(await engine.appliedSoftwareEC == nil)
        #expect(await engine.appliedSoundDevices == nil)
        #expect(await engine.soundOnNullFallback)
        // The null sound device clocks the bridge: RTP still flows both ways.
        let before = try await engine.mediaStats(out)
        try await Task.sleep(for: .seconds(1))
        let after = try await engine.mediaStats(out)
        #expect(after.rxPackets - before.rxPackets > 20 && after.txPackets - before.txPackets > 20,
                "rx \(before.rxPackets) -> \(after.rxPackets), tx \(before.txPackets) -> \(after.txPackets)")
        try await engine.hangup(out)
        #expect(await waitUntil { await engine.calls().isEmpty })
        await engine.stop()
    }
}

extension EngineTests {
    /// A burst of CoreAudio device events (list + default input + default output) is handled once.
    @Test func deviceEventsAreDebounced() async throws {
        let engine = await makeEngine()
        let log = EventLog()
        let consumer = log.consume(engine)
        defer { consumer.cancel() }
        try await engine.start(network: Self.network)
        func changes() -> Int { log.all.filter { if case .audioDevicesChanged = $0 { return true }; return false }.count }
        for _ in 0..<3 {
            await engine.audioDevicesEventArrived()
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(changes() == 0)                             // still inside the debounce interval
        #expect(await waitUntil(timeout: 2) { changes() == 1 })
        try await Task.sleep(for: .milliseconds(600))
        #expect(changes() == 1)
        await engine.stop()
    }
}

