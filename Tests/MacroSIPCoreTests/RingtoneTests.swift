import AVFoundation
import Foundation
import Testing
@testable import MacroSIPCore

// The ringtone chosen in Settings › Audio (docs/ENGINE.md "Ringtone and ringback"): the three
// built-in melodies, custom files converted once into the data folder, and the ringing call.

@Suite("Ringtone values and files")
struct RingtoneTests {
    /// Classic stays the tone of earlier builds; Digital and Soft are other patterns with
    /// cadences of their own, and every one fits the tone generator.
    @Test func builtInMelodiesAreDistinct() {
        let tones = BuiltInRingtone.allCases.map(\.tone)
        #expect(BuiltInRingtone.allCases == [.classic, .digital, .soft])
        #expect(Set(tones).count == 3)
        #expect(BuiltInRingtone.classic.tone == Tone.ringtone)
        #expect(Tone.ringtone.steps == [Tone.Step(freq1: 440, freq2: 480, onMs: 2000, offMs: 4000)])
        #expect(Tone.ringtone.loopMs == 6000 && Tone.ringtone.soundingMs == 2000)

        // One loop each, at least half a second apart.
        let loops = tones.map(\.loopMs)
        for i in loops.indices { for j in loops.indices where i < j { #expect(abs(loops[i] - loops[j]) >= 500, "\(loops)") } }

        // Digital: short beeps on two high notes, then a pause.
        let digital = Tone.ringtoneDigital
        #expect(Set(digital.steps.map(\.freq1)).count == 2, "\(digital)")
        #expect(digital.steps.allSatisfy { $0.onMs <= 150 && $0.freq1 >= 1000 && $0.freq2 == 0 }, "\(digital)")
        #expect(digital.steps.count >= 4 && digital.steps.last!.offMs >= 1000)

        // Soft: lower than Classic, long notes, quieter than the generator's default, a long pause.
        let soft = Tone.ringtoneSoft
        #expect(soft.steps.count >= 3 && Set(soft.steps.map(\.freq1)).count == soft.steps.count, "\(soft)")
        #expect(soft.steps.allSatisfy { $0.freq1 < 440 && $0.freq2 == 0 && $0.onMs >= 400 }, "\(soft)")
        #expect(soft.steps.allSatisfy { $0.volume > 0 && $0.volume < Tone.defaultVolume && $0.volume < digital.steps[0].volume })
        #expect(soft.steps.last!.offMs >= 3000)

        for t in tones + [Tone.ringback] {
            #expect(!t.steps.isEmpty && t.steps.count <= Tone.maxSteps)
            let d = t.descriptors
            #expect(d.count == t.steps.count)
            #expect(zip(d, t.steps).allSatisfy { Int($0.freq1) == $1.freq1 && Int($0.on_msec) == $1.onMs && Int($0.volume) == $1.volume })
        }
    }

    /// What the ringtone player is made from, what it falls back to and how long a preview lasts.
    @Test func ringtoneSourceMapsToThePlayer() {
        #expect(RingtoneSource.builtIn(.classic).playerSource == .tone(.ringtone))
        #expect(RingtoneSource.builtIn(.digital).playerSource == .tone(.ringtoneDigital))
        #expect(RingtoneSource.builtIn(.soft).playerSource == .tone(.ringtoneSoft))
        let url = URL(fileURLWithPath: "/tmp/ring.wav")
        #expect(RingtoneSource.file(url).playerSource == .wavFile(url))
        #expect(RingtoneSource.builtIn(.soft).fallbackTone == .ringtoneSoft && RingtoneSource.file(url).fallbackTone == .ringtone)
        #expect(RingtoneSource.builtIn(.digital).previewSeconds == Double(Tone.ringtoneDigital.soundingMs + 500) / 1000)
        #expect(RingtoneSource.file(url).previewSeconds == Engine.ringtonePreviewFileSeconds)
        #expect(RingtoneSource(.builtIn(.soft)) == .builtIn(.soft) && RingtoneSource(.file(url)) == nil)
    }

    /// A 16-bit WAV is used as it is; an AIFF or M4A is converted into `<data>/ringtone.wav` once
    /// (again only when another or a changed file comes); a file that cannot be read throws and
    /// leaves the last good copy alone.
    @Test func customFilesAreConvertedOnceIntoTheDataFolder() async throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let data = dir.appendingPathComponent("data", isDirectory: true)
        let converted = RingtoneFile.convertedURL(in: data)
        #expect(converted.lastPathComponent == "ringtone.wav" && converted.deletingLastPathComponent() == data)
        func fileNumber() throws -> Int {
            try #require(FileManager.default.attributesOfItem(atPath: converted.path)[.systemFileNumber] as? Int)
        }

        let wav = dir.appendingPathComponent("bell.wav")
        try RecordingConverterTests.sineWAV(seconds: 1, frequency: 600).write(to: wav)
        #expect(try RingtoneFile.prepare(wav, in: data) == wav)
        #expect(!FileManager.default.fileExists(atPath: converted.path))

        // AIFF: 44.1 kHz stereo, big-endian 16-bit.
        let aiff = dir.appendingPathComponent("bell.aiff")
        try Self.writeAIFF(aiff, seconds: 1, frequency: 600)
        #expect(!AudioFileToWAV.isPlayableWAV(aiff))
        #expect(try RingtoneFile.prepare(aiff, in: data) == converted)
        #expect(AudioFileToWAV.isPlayableWAV(converted))
        let fromAIFF = try AVAudioFile(forReading: converted)
        #expect(fromAIFF.fileFormat.sampleRate == 16_000 && abs(Int(fromAIFF.length) - 16_000) < 800, "\(fromAIFF.length)")
        let first = try fileNumber()
        #expect(try RingtoneFile.prepare(aiff, in: data) == converted)
        #expect(try fileNumber() == first, "the same file was converted again")

        // M4A: another file, converted again; then the same M4A changed on disk.
        let m4a = dir.appendingPathComponent("bell.m4a")
        _ = try await RecordingConverter.convert(wav: wav, to: m4a)
        #expect(try RingtoneFile.prepare(m4a, in: data) == converted)
        let second = try fileNumber()
        #expect(second != first && AudioFileToWAV.isPlayableWAV(converted))
        #expect(try RingtoneFile.prepare(m4a, in: data) == converted && fileNumber() == second)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: m4a.path)
        #expect(try RingtoneFile.prepare(m4a, in: data) == converted)
        let third = try fileNumber()
        #expect(third != second)

        // Missing and unreadable files: an error, the last good copy stays, nothing left behind.
        #expect(throws: AudioFileToWAV.ConversionError.self) {
            try RingtoneFile.prepare(dir.appendingPathComponent("missing.mp3"), in: data)
        }
        let junk = dir.appendingPathComponent("junk.mp3")
        try Data("not audio at all".utf8).write(to: junk)
        #expect(throws: AudioFileToWAV.ConversionError.self) { try RingtoneFile.prepare(junk, in: data) }
        #expect(try fileNumber() == third && AudioFileToWAV.isPlayableWAV(converted))
        #expect(try FileManager.default.contentsOfDirectory(atPath: data.path) == ["ringtone.wav"])

        RingtoneFile.removeConverted(in: data)
        #expect(!FileManager.default.fileExists(atPath: converted.path))
        RingtoneFile.removeConverted(in: data)          // nothing there: no error
    }

    /// A 16-bit big-endian stereo AIFF with a sine.
    static func writeAIFF(_ url: URL, seconds: Double, frequency: Double) throws {
        let rate = 44_100.0
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 2, interleaved: false))
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: true,
            AVLinearPCMIsNonInterleaved: false,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
        let frames = AVAudioFrameCount(seconds * rate)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        for ch in 0..<2 {
            let p = try #require(buffer.floatChannelData?[ch])
            for i in 0..<Int(frames) { p[i] = 0.3 * Float(sin(2 * Double.pi * frequency * Double(i) / rate)) }
        }
        try file.write(from: buffer)
    }
}

extension EngineTests {
    /// The chosen ringtone is what the ringing call plays: recorded from the ringtone's port,
    /// Classic is 440 + 480 Hz, Digital its two high notes, Soft its low notes, a converted M4A
    /// its 600 Hz. A file the engine cannot play as it is is refused and the previous melody
    /// keeps ringing. The preview plays one ring and stops by itself; the source is kept across
    /// stop and can be set before start.
    @Test func chosenRingtoneRingsTheIncomingCall() async throws {
        let (lb, consumer) = try await startLoopback(CallOptions())
        defer { consumer.cancel() }
        let engine = lb.engine
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        func dominant(_ wav: URL, _ tones: [Double], over others: [Double]) throws -> Int {
            try wavToneWindows(wav, tones: tones, others: others).dominant
        }
        // Recording starts a little after the loop does; a busy runner may be late by a few hundred ms.
        func heard(_ name: String, seconds: Double = 1.2) async throws -> URL {
            let wav = dir.appendingPathComponent(name)
            try await engine.recordRingtone(to: wav, seconds: seconds)
            return wav
        }

        #expect(await engine.ringtoneSource == .builtIn(.classic))
        let before = lb.log.all.count
        let out = try await lb.dial("ring")
        #expect(await waitUntil { lb.incoming(after: before) != nil })
        #expect(await waitUntil { await engine.ringtoneState() != nil })

        let classic = try await heard("classic.wav")
        #expect(try dominant(classic, [440, 480], over: [392, 330, 1320, 1760]) > 5)
        #expect(try dominant(classic, [1320], over: [440, 480]) == 0 && dominant(classic, [392], over: [440, 480]) == 0)

        try await engine.setRingtone(.builtIn(.digital))
        #expect(await engine.ringtoneState() != nil)
        let digital = try await heard("digital.wav", seconds: Double(Tone.ringtoneDigital.loopMs) / 1000 + 0.1)
        #expect(try dominant(digital, [1320], over: [440, 480, 392]) >= 2)
        #expect(try dominant(digital, [1760], over: [440, 480, 392]) >= 2)
        #expect(try dominant(digital, [440, 480], over: [1320, 1760]) == 0)

        try await engine.setRingtone(.builtIn(.soft))
        let soft = try await heard("soft.wav")
        let softNotes = try [392.0, 330, 262].map { try dominant(soft, [$0], over: [440, 480, 1320]) }
        #expect(softNotes.reduce(0, +) >= 4, "\(softNotes)")
        #expect(try dominant(soft, [440, 480], over: [392, 330, 262]) == 0 && dominant(soft, [1320], over: [392]) == 0)

        // Not a WAV the engine plays as it is: refused, Soft keeps ringing.
        let sine = dir.appendingPathComponent("bell.wav")
        try RecordingConverterTests.sineWAV(seconds: 2, frequency: 600).write(to: sine)
        let m4a = dir.appendingPathComponent("bell.m4a")
        _ = try await RecordingConverter.convert(wav: sine, to: m4a)
        await #expect(throws: EngineError.self) { try await engine.setRingtone(.file(m4a)) }
        await #expect(throws: EngineError.self) { try await engine.setRingtone(.file(dir.appendingPathComponent("missing.wav"))) }
        #expect(await engine.ringtoneSource == .builtIn(.soft))

        // Converted once by the app's helper: the WAV rings.
        let prepared = try RingtoneFile.prepare(m4a, in: dir.appendingPathComponent("data", isDirectory: true))
        try await engine.setRingtone(.file(prepared))
        let file = try await heard("file.wav")
        #expect(try dominant(file, [600], over: [440, 480, 392, 1320]) > 5)

        // Preview: one ring of Digital at half volume on the call output, then it stops by itself.
        try await engine.previewRingtone(.builtIn(.digital), volume: 0.5)
        let preview = try #require(await engine.testToneState())
        #expect(preview.slot != nil && abs(preview.volume - 0.5) < 0.001)
        #expect(await waitUntil { (await engine.testToneState()?.level ?? 0) > 10 })
        #expect(await waitUntil(timeout: 3) { await engine.testToneState() == nil })
        await #expect(throws: EngineError.self) { try await engine.previewRingtone(.file(m4a), volume: 1) }
        try await engine.previewRingtone(.file(prepared), volume: 2)             // clamped to 1
        #expect(await engine.testToneState()?.volume == 1)
        await engine.stopTestTone()
        #expect(await engine.testToneState() == nil)

        try await engine.hangup(out)
        #expect(await waitUntil {
            let idle = await engine.calls().isEmpty
            let ringing = await engine.ringtoneState() != nil
            return idle && !ringing
        })
        await engine.stop()
        #expect(await engine.ringtoneSource == .file(prepared))
        try await engine.setRingtone(.builtIn(.digital))            // before start: remembered
        #expect(await engine.ringtoneSource == .builtIn(.digital))
    }
}
