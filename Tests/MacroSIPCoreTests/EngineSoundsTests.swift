import AVFoundation
import Foundation
import Testing
@testable import MacroSIPCore

// Hold music, the recording notice tone, the voicemail indicator (MWI), the audio test tone
// and the UI sounds (docs/ENGINE.md, the sections of the same names).

extension EngineTests {
    /// Records `id` (mono) for `seconds` and returns the WAV.
    func recordMixed(_ engine: Engine, _ id: CallID, _ dir: URL, _ name: String, seconds: Double) async throws -> URL {
        let wav = dir.appendingPathComponent(name)
        try await engine.startRecording(id, to: wav)
        try await Task.sleep(for: .seconds(seconds))
        let files = try await engine.stopRecording(id)
        return try #require(files.mixed)
    }

    /// Hold music plays into the held call's port only: the far end records it (remote hold
    /// from its point of view), the player has one listener and none is the speaker. Off is
    /// silence; a WAV plays as is; an M4A is converted once to a temporary WAV; a file that
    /// cannot be read keeps the previous source; resume destroys the player, a new hold makes one.
    @Test func holdMusicReachesTheFarEndOnly() async throws {
        let (lb, consumer) = try await startLoopback(CallOptions())
        defer { consumer.cancel() }
        let engine = lb.engine
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (out, inc) = try await lb.connectedCall("hold")
        #expect(await engine.holdMusicState(of: out) == nil)

        try await engine.setHold(out, true)
        #expect(await waitUntil { await lb.call(out)?.state == .held })
        // The player is created, then connected to the call's port: wait for the wiring, not just the player.
        #expect(await waitUntil { if let s = await engine.holdMusicState(of: out) { return s.listeners == 1 && !s.toSpeaker } else { return false } })
        let state = try #require(await engine.holdMusicState(of: out))
        #expect(state.listeners == 1 && !state.toSpeaker, "\(state)")
        #expect(await waitUntil { (await engine.holdMusicState(of: out)?.level ?? 0) > 10 })
        let wiring = await engine.wiring(of: out)
        #expect(wiring?.toSpeaker == false && wiring?.fromMic == false)
        let melody = try await recordMixed(engine, inc, dir, "melody.wav", seconds: 2)
        let rms = try wavRMS(melody)
        #expect(rms > 200, "melody RMS \(rms)")
        #expect(await engine.holdMusicState(of: out)?.listeners == 1)     // not into the recorder either

        // Off: the far end hears silence.
        try await engine.setHoldMusic(.off)
        #expect(await engine.holdMusicState(of: out) == nil)
        try await Task.sleep(for: .milliseconds(500))        // what was already encoded arrives and plays out
        let silence = try await recordMixed(engine, inc, dir, "silence.wav", seconds: 1)
        let quiet = try wavRMS(silence)
        #expect(quiet < 50, "RMS with hold music off \(quiet)")

        // A 16-bit WAV: played as it is.
        let sine = dir.appendingPathComponent("sine.wav")
        try RecordingConverterTests.sineWAV(seconds: 2, frequency: 600).write(to: sine)
        try await engine.setHoldMusic(.file(sine))
        #expect(await waitUntil { await engine.holdMusicState(of: out) != nil })
        #expect(await engine.holdMusicTemporaryFile() == nil)
        let fromWAV = try await recordMixed(engine, inc, dir, "wav.wav", seconds: 1.2)
        #expect(try wavToneAmplitude(fromWAV, frequency: 600) > 300)

        // An M4A: converted once to a temporary 16 kHz WAV.
        let m4a = dir.appendingPathComponent("music.m4a")
        try await RecordingConverter.convert(wav: sine, to: m4a)
        try await engine.setHoldMusic(.file(m4a))
        let temp = try #require(await engine.holdMusicTemporaryFile())
        #expect(FileManager.default.fileExists(atPath: temp.path) && AudioFileToWAV.isPlayableWAV(temp))
        #expect(await waitUntil { await engine.holdMusicState(of: out) != nil })
        let fromM4A = try await recordMixed(engine, inc, dir, "m4a.wav", seconds: 1.2)
        #expect(try wavToneAmplitude(fromM4A, frequency: 600) > 300)

        // A file that cannot be read: error, previous source kept.
        await #expect(throws: AudioFileToWAV.ConversionError.self) {
            try await engine.setHoldMusic(.file(dir.appendingPathComponent("missing.mp3")))
        }
        #expect(await engine.holdMusicTemporaryFile() == temp)
        #expect(await engine.holdMusicState(of: out) != nil)

        // Back to the melody: the temporary file goes; resume removes the player; hold again.
        try await engine.setHoldMusic(.builtIn)
        #expect(!FileManager.default.fileExists(atPath: temp.path))
        try await engine.setHold(out, false)
        #expect(await waitUntil {
            let connected = await lb.call(out)?.state == .connected
            let noMusic = await engine.holdMusicState(of: out) == nil
            return connected && noMusic
        })
        try await engine.setHold(out, true)
        #expect(await waitUntil { await engine.holdMusicState(of: out) != nil })
        try await engine.hangup(out)
        #expect(await waitUntil { await engine.calls().isEmpty })
        await engine.reconcileMedia()
        #expect(await engine.holdMusicPlayerCount() == 0)
        await engine.stop()
    }

    /// The recording notice: a 1400 Hz beep in the recording, in the speaker and at the far
    /// end (every 0.4 s here, the first one a second in); a stereo split puts it in the remote
    /// file only; switching it off and on applies to the recording in progress.
    @Test func recordingNoticeBeepsForBothSidesAndTheFile() async throws {
        let (lb, consumer) = try await startLoopback(CallOptions())
        defer { consumer.cancel() }
        let engine = lb.engine
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        await engine.setRecordingNoticeInterval(ms: 400)
        await engine.setRecordingNotice(enabled: true, intervalSeconds: 15)
        let (out, inc) = try await lb.connectedCall("rec")

        // Mono recording of `out`: the beep reaches the file, the speaker and the far end.
        let wav = dir.appendingPathComponent("notice.wav")
        try await engine.startRecording(out, to: wav)
        #expect(await waitUntil { await engine.recordingNoticeState(of: out)?.hasTimer == true })
        var farEnd = 0, speaker = 0
        for _ in 0..<46 {                                     // 2.3 s
            farEnd = max(farEnd, await engine.callSignal(of: inc)?.rx ?? 0)
            speaker = max(speaker, await engine.speakerSignal() ?? 0)
            try await Task.sleep(for: .milliseconds(50))
        }
        let state = try #require(await engine.recordingNoticeState(of: out))
        #expect(state.sinks.count == 3 && state.sinks.contains(0), "\(state.sinks)")
        let files = try await engine.stopRecording(out)
        #expect(await engine.recordingNoticeState(of: out) == nil)
        let beeps = try wavToneAmplitude(try #require(files.mixed), frequency: 1400)
        #expect(beeps > 300, "1400 Hz in the recording: \(beeps)")
        #expect(farEnd > 10, "far end level \(farEnd)")
        #expect(speaker > 10, "speaker level \(speaker)")

        // Stereo split: the remote file carries the beep, the local (microphone) file does not.
        try await engine.startRecording(out, to: dir.appendingPathComponent("split.wav"), layout: .stereoSplit)
        try await Task.sleep(for: .seconds(2))
        let split = try await engine.stopRecording(out)
        #expect(try wavToneAmplitude(try #require(split.remote), frequency: 1400) > 300)
        #expect(try wavToneAmplitude(try #require(split.local), frequency: 1400) < 30)

        // Off: a new recording has no beep and no player.
        await engine.setRecordingNotice(enabled: false, intervalSeconds: 15)
        let quietWAV = dir.appendingPathComponent("quiet.wav")
        try await engine.startRecording(out, to: quietWAV)
        try await Task.sleep(for: .milliseconds(1500))
        #expect(await engine.recordingNoticeState(of: out) == nil)
        _ = try await engine.stopRecording(out)
        #expect(try wavToneAmplitude(quietWAV, frequency: 1400) < 30)

        // Switched on during a recording: the beep starts without restarting the recording.
        let live = dir.appendingPathComponent("live.wav")
        try await engine.startRecording(out, to: live)
        await engine.setRecordingNotice(enabled: true, intervalSeconds: 60)
        #expect(await waitUntil { await engine.recordingNoticeState(of: out) != nil })
        try await Task.sleep(for: .milliseconds(1800))
        let liveFiles = try await engine.stopRecording(out)
        #expect(try wavToneAmplitude(try #require(liveFiles.mixed), frequency: 1400) > 300)

        try await engine.hangup(out)
        #expect(await waitUntil { await engine.calls().isEmpty })
        #expect(await engine.recordingNoticeCount() == (0, 0))
        await engine.stop()
    }

    /// An account with `mwi` SUBSCRIBEs to message-summary once registered, one without does
    /// not; a message-summary NOTIFY (here unsolicited, from the registrar) becomes `.voicemail`
    /// and `voicemailState(for:)`; an unchanged indicator emits nothing; removal forgets it.
    @Test func voicemailIndicatorSubscribesAndParsesNotify() async throws {
        let stub = try RegistrarStub(status: "200 OK", responseHeaders: "Expires: 300\r\n")
        defer { stub.stop() }
        let engine = await makeEngine()
        let log = EventLog()
        let consumer = log.consume(engine)
        defer { consumer.cancel() }
        try await engine.start(network: Self.network)
        let port = await engine.localPort(of: .udp)
        let server = "127.0.0.1:\(stub.port)"
        let cfg = AccountConfig(displayName: "VM", username: "1001", domain: "127.0.0.1",
                                registrar: server, outboundProxy: server, mwi: true)
        try await engine.addAccount(cfg, password: "pw")
        func registered(_ id: AccountID) async -> Bool {
            if case .registered = await engine.registrationState(of: id) { return true }
            return false
        }
        #expect(await waitUntil { await registered(cfg.id) })
        #expect(await waitUntil { stub.subscribeRequests.contains { $0.event.lowercased().hasPrefix("message-summary") } })

        let plain = AccountConfig(displayName: "P", username: "1002", domain: "127.0.0.1",
                                  registrar: server, outboundProxy: server, mwi: false)
        try await engine.addAccount(plain, password: "pw")
        #expect(await waitUntil { await registered(plain.id) })
        try await Task.sleep(for: .milliseconds(400))
        #expect(stub.subscribeRequests.allSatisfy { $0.event.lowercased().hasPrefix("message-summary") && !$0.from.contains("1002") },
                "\(stub.subscribeRequests)")
        #expect(await engine.voicemailState(for: cfg.id) == nil)

        func voicemails() -> [(AccountID, Bool, Int, Int)] {
            log.all.compactMap { if case let .voicemail(id, w, n, o) = $0 { return (id, w, n, o) }; return nil }
        }
        func notify(_ body: String, cseq: Int) -> String {
            "NOTIFY sip:1001@127.0.0.1:\(port) SIP/2.0\r\n"
                + "Via: SIP/2.0/UDP 127.0.0.1:\(stub.port);branch=z9hG4bK-mwi-\(cseq)\r\n"
                + "Max-Forwards: 70\r\n"
                + "From: <sip:1001@127.0.0.1>;tag=stub-mwi\r\n"
                + "To: <sip:1001@127.0.0.1>\r\n"
                + "Call-ID: mwi-test-\(cseq)@127.0.0.1\r\n"
                + "CSeq: \(cseq) NOTIFY\r\n"
                + "Event: message-summary\r\n"
                + "Subscription-State: active\r\n"
                + "Content-Type: application/simple-message-summary\r\n"
                + "Content-Length: \(body.utf8.count)\r\n\r\n" + body
        }
        let waiting = "Messages-Waiting: yes\r\nMessage-Account: sip:vm@127.0.0.1\r\nVoice-Message: 2/5 (1/0)\r\n"
        stub.send(notify(waiting, cseq: 1), to: port)
        #expect(await waitUntil { voicemails().count == 1 })
        let first = try #require(voicemails().first)
        #expect(first.0 == cfg.id && first.1 && first.2 == 2 && first.3 == 5)
        #expect(await engine.voicemailState(for: cfg.id) == VoicemailState(waiting: true, new: 2, old: 5, urgentNew: 1, urgentOld: 0))
        #expect(await engine.voicemailState(for: plain.id) == nil)

        stub.send(notify(waiting, cseq: 2), to: port)        // unchanged: no event
        try await Task.sleep(for: .milliseconds(400))
        #expect(voicemails().count == 1)

        stub.send(notify("Messages-Waiting: no\r\nVoice-Message: 0/7 (0/0)\r\n", cseq: 3), to: port)
        #expect(await waitUntil { voicemails().count == 2 })
        let cleared = try #require(voicemails().last)
        #expect(cleared.0 == cfg.id && !cleared.1 && cleared.2 == 0 && cleared.3 == 7)
        #expect(await engine.voicemailState(for: cfg.id) == VoicemailState(waiting: false, new: 0, old: 7))

        try await engine.removeAccount(cfg.id)
        #expect(await engine.voicemailState(for: cfg.id) == nil)
        await engine.stop()
    }

    /// The audio test tone plays on the call output and stops by itself (or on request);
    /// UI sounds play on the call output, overlap, never reach a call, and stop themselves.
    @Test func testToneAndEventSounds() async throws {
        let (lb, consumer) = try await startLoopback(CallOptions())
        defer { consumer.cancel() }
        let engine = lb.engine
        for e in [SoundEvent.callConnected, .callEnded, .voicemail, .error, .keyPress("5")] {
            #expect(EventSounds.duration(of: e) <= 400, "\(e)")
        }

        try await engine.playTestTone(outputDevice: nil, seconds: 0.7)
        #expect(await engine.testToneState()?.slot != nil)
        #expect(await waitUntil { (await engine.testToneState()?.level ?? 0) > 20 })
        #expect(await waitUntil(timeout: 3) { await engine.testToneState() == nil })
        try await engine.playTestTone(outputDevice: nil, seconds: 0.5)
        try await engine.playTestTone(outputDevice: nil, seconds: 5)        // replaces the first
        #expect(await engine.testToneState() != nil)
        try await Task.sleep(for: .milliseconds(700))                        // the first tone's timer has fired by now
        #expect(await engine.testToneState() != nil, "the replaced tone's timer stopped the new tone")
        #expect(await waitUntil { (await engine.testToneState()?.level ?? 0) > 20 })
        await engine.stopTestTone()
        #expect(await engine.testToneState() == nil)

        let (out, inc) = try await lb.connectedCall("snd")
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let far = dir.appendingPathComponent("far.wav")
        try await engine.startRecording(inc, to: far)
        try await engine.playEventSound(.error)
        try await engine.playEventSound(.keyPress("5"))
        // The sounds last 120–300 ms: sample the speaker at once and often, a loaded runner may be late.
        var speaker = 0
        for _ in 0..<150 where speaker <= 10 {
            speaker = max(speaker, await engine.speakerSignal() ?? 0)
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(speaker > 10, "speaker level \(speaker)")
        #expect(await waitUntil(timeout: 2) { await engine.eventSoundCount() == 0 })
        for e in [SoundEvent.callConnected, .callEnded, .voicemail] { try await engine.playEventSound(e) }
        try await Task.sleep(for: .milliseconds(700))
        let files = try await engine.stopRecording(inc)
        let heard = try #require(files.mixed)
        #expect(try wavToneAmplitude(heard, frequency: 330) < 30)      // .error
        #expect(try wavToneAmplitude(heard, frequency: 1336) < 30)     // key 5 column tone
        #expect(try wavToneAmplitude(heard, frequency: 880) < 30)      // connected / voicemail
        await #expect(throws: EngineError.invalidArgument("sound for key \"x\"")) {
            try await engine.playEventSound(.keyPress("x"))
        }
        #expect(await waitUntil(timeout: 2) { await engine.eventSoundCount() == 0 })
        try await engine.hangup(out)
        #expect(await waitUntil { await engine.calls().isEmpty })
        await engine.stop()
    }
}

@Suite("Hold music, notice tone, voicemail and sound values")
struct EngineSoundValueTests {
    @Test func messageSummaryParsing() {
        let full = MessageSummary.parse("Messages-Waiting: yes\r\nMessage-Account: sip:vm@x\r\nVoice-Message: 2/8 (1/0)\r\nFax-Message: 3/0\r\n")
        #expect(full == VoicemailState(waiting: true, new: 2, old: 8, urgentNew: 1, urgentOld: 0))
        // RFC 3842 bodies may fold a header: a line starting with SP or HT continues the previous one.
        let folded = MessageSummary.parse("Messages-Waiting:\r\n yes\r\nVoice-Message: 3/4\r\n\t(2/1)\r\n")
        #expect(folded == VoicemailState(waiting: true, new: 3, old: 4, urgentNew: 2, urgentOld: 1))
        #expect(MessageSummary.parse("Voice-Message: 1/0 (0/0)\r\n  \r\nMessages-Waiting: no\r\n") == VoicemailState(waiting: false, new: 1, old: 0))
        let plain = MessageSummary.parse("messages-waiting:NO\nvoice-message:0/3")
        #expect(plain == VoicemailState(waiting: false, new: 0, old: 3))
        let noCounts = MessageSummary.parse("Messages-Waiting: yes\r\n")
        #expect(noCounts == VoicemailState(waiting: true, new: 0, old: 0))
        let noFlag = MessageSummary.parse("Voice-Message: 4/1\r\n")
        #expect(noFlag == VoicemailState(waiting: true, new: 4, old: 1))
        #expect(MessageSummary.parse("") == VoicemailState(waiting: false, new: 0, old: 0))
        #expect(MessageSummary.counts(" 12 / 34 ( 5/6 )") == (12, 34, 5, 6))
    }

    @Test func settingsDecodeDefaultsAndRoundTrip() throws {
        let old = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"callLogLimit":50}"#.utf8))
        #expect(old.audio.holdMusic == .builtIn && old.audio.soundEvents == SoundEventSettings())
        #expect(!old.recording.noticeTone && old.recording.noticeToneIntervalSeconds == 15)
        let odd = try JSONDecoder().decode(RecordingSettings.self,
                                           from: Data(#"{"noticeTone":true,"noticeToneIntervalSeconds":3}"#.utf8))
        #expect(odd.noticeTone && odd.noticeToneIntervalSeconds == 5)
        #expect(try JSONDecoder().decode(RecordingSettings.self, from: Data(#"{"noticeToneIntervalSeconds":100}"#.utf8))
                    .noticeToneIntervalSeconds == 60)
        #expect(RecordingSettings(noticeToneIntervalSeconds: 0).noticeToneIntervalSeconds == 5)
        let unknown = try JSONDecoder().decode(AudioSettings.self,
                                               from: Data(#"{"holdMusic":{"stream":{"_0":"x"}},"soundEvents":"yes"}"#.utf8))
        #expect(unknown.holdMusic == .builtIn && unknown.soundEvents == SoundEventSettings())

        var s = AppSettings()
        s.audio.holdMusic = .file(URL(fileURLWithPath: "/tmp/music.mp3"))
        s.audio.soundEvents = SoundEventSettings(callEvents: true, keyPress: false, voicemail: true, error: true)
        s.recording.noticeTone = true
        s.recording.noticeToneIntervalSeconds = 30
        var back = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(s))
        #expect(back.audio == s.audio && back.recording == s.recording)
        s.audio.holdMusic = .off
        back = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(s))
        #expect(back.audio.holdMusic == .off)
    }

    @Test func accountConfigDecodesVoicemailDefaults() throws {
        let json = #"{"id":{"raw":"4F2A6B2E-3C1D-4E55-9A7B-1B2C3D4E5F60"},"displayName":"A","username":"1","domain":"d","transport":"udp","srtp":"disabled","enabled":true,"isDefaultOutgoing":false,"registrationInterval":300,"publishPresence":false}"#
        let old = try JSONDecoder().decode(AccountConfig.self, from: Data(json.utf8))
        #expect(old.mwi && old.voicemailNumber == nil)
        var cfg = AccountConfig(displayName: "B", username: "2", domain: "d", mwi: false, voicemailNumber: "*97")
        var back = try JSONDecoder().decode(AccountConfig.self, from: JSONEncoder().encode(cfg))
        #expect(back == cfg && !back.mwi && back.voicemailNumber == "*97")
        cfg.voicemailNumber = nil
        back = try JSONDecoder().decode(AccountConfig.self, from: JSONEncoder().encode(cfg))
        #expect(back.voicemailNumber == nil)
    }

    @Test func holdMelodyAndSoundsFitTheGenerator() {
        let melody = HoldMelody.sequence()
        #expect(melody.count == 16 && melody.count <= 32)
        #expect(melody.allSatisfy { (200...1300).contains(Int($0.freq1)) && (200...600).contains(Int($0.freq2)) && $0.volume == HoldMelody.volume })
        #expect(melody.last?.off_msec == HoldMelody.restMs && melody.first?.off_msec == HoldMelody.gapMs)
        #expect(HoldMelody.loopMs == 16 * 320 + 15 * 40 + 1600)
        #expect(RecordingNoticeTone.beep().freq1 == 1400 && RecordingNoticeTone.beep().on_msec == 300)
        #expect(EventSounds.sequence(for: .keyPress("1")) == nil && EventSounds.duration(of: .keyPress("1")) == 120)
        #expect(EventSounds.testTone().count == 2)
    }

    @Test func audioFileToWAVConvertsAStereoFloatFile() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // A WAV pjmedia cannot play: 44.1 kHz, two channels, Float32.
        let source = dir.appendingPathComponent("stereo.wav")
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: 2, interleaved: false))
        let file = try AVAudioFile(forWriting: source, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
        let frames: AVAudioFrameCount = 44_100
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        for ch in 0..<2 {
            let p = try #require(buffer.floatChannelData?[ch])
            for i in 0..<Int(frames) { p[i] = 0.3 * Float(sin(2 * Double.pi * 600 * Double(i) / 44_100)) }
        }
        try file.write(from: buffer)
        _ = consume file
        #expect(!AudioFileToWAV.isPlayableWAV(source))

        let pcm = dir.appendingPathComponent("pcm.wav")
        try RecordingConverterTests.sineWAV(seconds: 0.5).write(to: pcm)
        #expect(AudioFileToWAV.isPlayableWAV(pcm))

        let out = dir.appendingPathComponent("mono16k.wav")
        try AudioFileToWAV.convert(source, to: out)
        #expect(AudioFileToWAV.isPlayableWAV(out))
        let converted = try AVAudioFile(forReading: out)
        #expect(converted.fileFormat.sampleRate == 16_000 && converted.fileFormat.channelCount == 1)
        #expect(abs(Int(converted.length) - 16_000) < 800, "\(converted.length) frames")
        // CoreAudio pads the header (the fmt chunk is not at byte 12), so read the samples back
        // with AVAudioFile instead of the 44-byte-header helpers: 0.3 full scale -> RMS about 7000.
        let count = AVAudioFrameCount(converted.length)
        let samples = try #require(AVAudioPCMBuffer(pcmFormat: converted.processingFormat, frameCapacity: count))
        try converted.read(into: samples)
        let data = try #require(samples.floatChannelData?[0])
        var sum = 0.0
        for i in 0..<Int(samples.frameLength) { sum += Double(data[i]) * Double(data[i]) }
        let rms = (sum / Double(samples.frameLength)).squareRoot() * 32767
        #expect(rms > 5000, "RMS \(rms)")
        #expect(throws: AudioFileToWAV.ConversionError.self) {
            try AudioFileToWAV.convert(dir.appendingPathComponent("missing.mp3"), to: out)
        }
    }
}
