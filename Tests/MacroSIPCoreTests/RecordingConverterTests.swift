import AVFoundation
import Testing
import Foundation
@testable import MacroSIPCore

@Suite("Recording converter")
struct RecordingConverterTests {
    /// 16-bit mono PCM WAV with a sine (440 Hz by default).
    static func sineWAV(seconds: Double, rate: Int = 16_000, frequency: Double = 440) -> Data {
        let count = Int(seconds * Double(rate))
        var pcm = Data(capacity: count * 2)
        for i in 0..<count {
            let v = Int16(12_000 * sin(2 * Double.pi * frequency * Double(i) / Double(rate)))
            withUnsafeBytes(of: v.littleEndian) { pcm.append(contentsOf: $0) }
        }
        func le32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        func le16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        var d = Data("RIFF".utf8)
        d += le32(UInt32(36 + pcm.count)) + Data("WAVEfmt ".utf8) + le32(16) + le16(1) + le16(1)
        d += le32(UInt32(rate)) + le32(UInt32(rate * 2)) + le16(2) + le16(16)
        d += Data("data".utf8) + le32(UInt32(pcm.count)) + pcm
        return d
    }

    @Test func convertsWAVToM4A() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rec-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let wav = dir.appendingPathComponent("in.wav")
        let m4a = dir.appendingPathComponent("out.m4a")
        try Self.sineWAV(seconds: 1).write(to: wav)

        try await RecordingConverter.convert(wav: wav, to: m4a)

        let size = (try FileManager.default.attributesOfItem(atPath: m4a.path)[.size] as? Int) ?? 0
        #expect(size > 1024)
        // only the final file is left in the folder
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        #expect(names == ["in.wav", "out.m4a"])
    }

    @Test func neverOverwritesAnExistingFile() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rec-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let wav = dir.appendingPathComponent("in.wav")
        let m4a = dir.appendingPathComponent("out.m4a")
        try Self.sineWAV(seconds: 0.5, rate: 8_000).write(to: wav)
        try Data("old".utf8).write(to: m4a)
        let result = try await RecordingConverter.convert(wav: wav, to: m4a)
        #expect(result.lastPathComponent == "out 2.m4a")
        #expect(try Data(contentsOf: m4a) == Data("old".utf8))
        #expect(((try FileManager.default.attributesOfItem(atPath: result.path)[.size] as? Int) ?? 0) > 1024)
        let third = try await RecordingConverter.convert(wav: wav, to: m4a)
        #expect(third.lastPathComponent == "out 3.m4a")
    }

    @Test func zeroSizedHeaderIsPatchedFromFileLength() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rec-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var data = Self.sineWAV(seconds: 1)
        data.replaceSubrange(4..<8, with: [0, 0, 0, 0])         // RIFF size
        data.replaceSubrange(40..<44, with: [0, 0, 0, 0])       // data size
        let wav = dir.appendingPathComponent("stream.wav")
        try data.write(to: wav)
        let m4a = dir.appendingPathComponent("out.m4a")
        try await RecordingConverter.convert(wav: wav, to: m4a)
        #expect(((try FileManager.default.attributesOfItem(atPath: m4a.path)[.size] as? Int) ?? 0) > 1024)
        let patched = try Data(contentsOf: wav)
        #expect(patched[40..<44] == Data([0x00, 0x7D, 0x00, 0x00]))   // 32000 bytes
    }

    @Test func wavWithoutSamplesIsEmpty() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rec-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let wav = dir.appendingPathComponent("silence.wav")
        try Self.sineWAV(seconds: 0).write(to: wav)
        let m4a = dir.appendingPathComponent("out.m4a")
        await #expect(throws: RecordingConverter.ConversionError.empty) { try await RecordingConverter.convert(wav: wav, to: m4a) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["silence.wav"])
    }

    @Test func garbageInputFailsAndLeavesNothing() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rec-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let wav = dir.appendingPathComponent("bad.wav")
        let m4a = dir.appendingPathComponent("out.m4a")
        try Data("not audio".utf8).write(to: wav)
        await #expect(throws: (any Error).self) { try await RecordingConverter.convert(wav: wav, to: m4a) }
        #expect(!FileManager.default.fileExists(atPath: m4a.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["bad.wav"])
    }

    /// Power of `frequency` in `samples` (Goertzel), normalised by the sample count.
    static func goertzel(_ samples: UnsafeBufferPointer<Float>, rate: Double, frequency: Double) -> Double {
        let w = 2 * Double.pi * frequency / rate
        let coeff = 2 * cos(w)
        var s1 = 0.0, s2 = 0.0
        for x in samples {
            let s0 = Double(x) + coeff * s1 - s2
            s2 = s1
            s1 = s0
        }
        let power = s1 * s1 + s2 * s2 - coeff * s1 * s2
        return power / Double(max(samples.count, 1) * max(samples.count, 1))
    }

    static func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rec-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Two 1 s sines (local 440 Hz, remote 880 Hz) -> stereo M4A: two channels, left
    /// dominated by 440 Hz, right by 880 Hz; the WAVs are left in place.
    @Test func convertsStereoSplitToStereoM4A() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let files = RecordingFiles.planned(for: dir.appendingPathComponent("call.wav"), layout: .stereoSplit)
        #expect(files.local?.lastPathComponent == "call-local.wav")
        #expect(files.remote?.lastPathComponent == "call-remote.wav")
        try Self.sineWAV(seconds: 1, frequency: 440).write(to: try #require(files.local))
        try Self.sineWAV(seconds: 1, frequency: 880).write(to: try #require(files.remote))
        let m4a = dir.appendingPathComponent("out.m4a")

        let result = try await RecordingConverter.convert(files: files, to: m4a)
        #expect(result == m4a)
        #expect(((try FileManager.default.attributesOfItem(atPath: m4a.path)[.size] as? Int) ?? 0) > 1024)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
                == ["call-local.wav", "call-remote.wav", "out.m4a"])

        let file = try AVAudioFile(forReading: m4a)
        #expect(file.fileFormat.channelCount == 2)
        let rate = file.processingFormat.sampleRate
        #expect(rate == 44_100)
        let seconds = Double(file.length) / rate
        #expect(seconds > 0.9 && seconds < 1.2, "\(seconds) s")
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let data = try #require(buffer.floatChannelData)
        let n = Int(buffer.frameLength)
        let left = UnsafeBufferPointer(start: data[0], count: n)
        let right = UnsafeBufferPointer(start: data[1], count: n)
        let l440 = Self.goertzel(left, rate: rate, frequency: 440), l880 = Self.goertzel(left, rate: rate, frequency: 880)
        let r440 = Self.goertzel(right, rate: rate, frequency: 440), r880 = Self.goertzel(right, rate: rate, frequency: 880)
        #expect(l440 > 20 * l880, "left: 440 Hz \(l440), 880 Hz \(l880)")
        #expect(r880 > 20 * r440, "right: 440 Hz \(r440), 880 Hz \(r880)")
    }

    /// The shorter file is padded with silence; zero RIFF sizes are repaired; the mono
    /// layout goes through `convert(wav:)`.
    @Test func stereoSplitPadsTheShorterFile() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let files = RecordingFiles.planned(for: dir.appendingPathComponent("c.wav"), layout: .stereoSplit)
        let localURL = try #require(files.local), remoteURL = try #require(files.remote)
        var local = Self.sineWAV(seconds: 0.5, frequency: 440)
        local.replaceSubrange(4..<8, with: [0, 0, 0, 0])
        local.replaceSubrange(40..<44, with: [0, 0, 0, 0])
        try local.write(to: localURL)
        try Self.sineWAV(seconds: 1.5, frequency: 880).write(to: remoteURL)
        let out = try await RecordingConverter.convert(files: files, to: dir.appendingPathComponent("o.m4a"))
        let file = try AVAudioFile(forReading: out)
        let seconds = Double(file.length) / file.processingFormat.sampleRate
        #expect(file.fileFormat.channelCount == 2)
        #expect(seconds > 1.4 && seconds < 1.7, "\(seconds) s")
        #expect(try Data(contentsOf: localURL)[40..<44] == Data([0x80, 0x3E, 0x00, 0x00]))  // 16000 bytes

        let mono = RecordingFiles.planned(for: remoteURL, layout: .mono)
        let monoOut = try await RecordingConverter.convert(files: mono, to: dir.appendingPathComponent("m.m4a"))
        #expect(try AVAudioFile(forReading: monoOut).fileFormat.channelCount == 1)
    }

    /// Both files without samples: `.empty`, nothing left behind. One empty side is silence.
    @Test func stereoSplitWithoutSamplesIsEmpty() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let files = RecordingFiles.planned(for: dir.appendingPathComponent("e.wav"), layout: .stereoSplit)
        try Self.sineWAV(seconds: 0).write(to: try #require(files.local))
        try Self.sineWAV(seconds: 0).write(to: try #require(files.remote))
        await #expect(throws: RecordingConverter.ConversionError.empty) {
            try await RecordingConverter.convert(files: files, to: dir.appendingPathComponent("e.m4a"))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted() == ["e-local.wav", "e-remote.wav"])

        try Self.sineWAV(seconds: 1, frequency: 880).write(to: try #require(files.remote))
        let out = try await RecordingConverter.convert(files: files, to: dir.appendingPathComponent("e.m4a"))
        #expect(try AVAudioFile(forReading: out).fileFormat.channelCount == 2)
    }

    @Test func fileNameFormat() {
        let tz = TimeZone(identifier: "UTC")!
        let date = Date(timeIntervalSince1970: 1_791_643_920)   // 2026-10-10 14:52 UTC
        #expect(RecordingFileName.make(date: date, remote: "Anna Petrova", direction: .incoming, timeZone: tz)
                == "2026-10-10 14.52 Anna Petrova (in).m4a")
        #expect(RecordingFileName.make(date: date, remote: "+7 912/555:01", direction: .outgoing, timeZone: tz)
                == "2026-10-10 14.52 +7 912-555-01 (out).m4a")
        #expect(RecordingFileName.make(date: date, remote: "  ", direction: .missed, timeZone: tz)
                == "2026-10-10 14.52 Unknown (in).m4a")
    }

    @Test func uniqueURLAddsCounter() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rec-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = RecordingFileName.uniqueURL(in: dir, name: "a (in).m4a")
        #expect(first.lastPathComponent == "a (in).m4a")
        try Data().write(to: first)
        #expect(RecordingFileName.uniqueURL(in: dir, name: "a (in).m4a").lastPathComponent == "a (in) 2.m4a")
    }
}
