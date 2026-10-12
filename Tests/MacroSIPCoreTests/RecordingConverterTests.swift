import Testing
import Foundation
@testable import MacroSIPCore

@Suite("Recording converter")
struct RecordingConverterTests {
    /// 16-bit mono PCM WAV with a 440 Hz sine.
    static func sineWAV(seconds: Double, rate: Int = 16_000) -> Data {
        let count = Int(seconds * Double(rate))
        var pcm = Data(capacity: count * 2)
        for i in 0..<count {
            let v = Int16(12_000 * sin(2 * Double.pi * 440 * Double(i) / Double(rate)))
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

    @Test func replacesExistingOutput() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rec-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let wav = dir.appendingPathComponent("in.wav")
        let m4a = dir.appendingPathComponent("out.m4a")
        try Self.sineWAV(seconds: 0.5, rate: 8_000).write(to: wav)
        try Data("old".utf8).write(to: m4a)
        try await RecordingConverter.convert(wav: wav, to: m4a)
        #expect(((try FileManager.default.attributesOfItem(atPath: m4a.path)[.size] as? Int) ?? 0) > 1024)
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
