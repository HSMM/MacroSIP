import Foundation
import AVFoundation

/// Converts the engine's temporary WAV recording into the M4A (AAC) file the user keeps
/// (SCREENS.md 8.6): mono, 64 kbit/s.
public enum RecordingConverter {
    public enum ConversionError: Error, Equatable, CustomStringConvertible {
        case noAudioTrack
        /// The WAV holds no samples at all (call held the whole time, Record pressed twice).
        case empty
        case readerFailed(String)
        case writerFailed(String)

        public var description: String {
            switch self {
            case .noAudioTrack: return "The recording contains no audio"
            case .empty: return "The recording is empty"
            case let .readerFailed(m): return "Cannot read the recording: \(m)"
            case let .writerFailed(m): return "Cannot write the M4A file: \(m)"
            }
        }
    }

    public static let bitRate = 64_000

    /// Converts `wav` to M4A next to `m4a` and returns the URL it ended up at. An existing file is
    /// never replaced: when `m4a` is taken (also by a file that appears meanwhile) the name gets
    /// " 2", " 3", ... The output appears under its final name only when it is complete; a failed
    /// conversion leaves nothing behind.
    ///
    /// The engine may leave the RIFF and data sizes at zero; they are patched from the file length
    /// first. A WAV without samples throws `ConversionError.empty`.
    @discardableResult
    public static func convert(wav: URL, to m4a: URL) async throws -> URL {
        let dataBytes = WAVHeader.repairSizes(of: wav)
        if let n = dataBytes, n < 2 { throw ConversionError.empty }
        let asset = AVURLAsset(url: wav)
        let tracks: [AVAssetTrack]
        do { tracks = try await asset.loadTracks(withMediaType: .audio) }
        catch { throw ConversionError.readerFailed(error.localizedDescription) }
        guard let track = tracks.first else { throw ConversionError.noAudioTrack }

        // AAC-LC at 64 kbit/s mono is only accepted from 32 kHz up (16 kHz sources are upsampled
        // by the reader); 48 kHz sources keep their rate.
        var sourceRate = 16_000.0
        if let format = (try? await track.load(.formatDescriptions))?.first,
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee {
            sourceRate = asbd.mSampleRate
        }
        let rate = sourceRate >= 47_000 ? 48_000.0 : 44_100.0

        let fm = FileManager.default
        let partial = m4a.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).partial.m4a")
        defer { try? fm.removeItem(at: partial) }

        let job = try Job(asset: asset, track: track, output: partial, sampleRate: rate)
        try await job.run()

        return try moveWithoutOverwriting(partial, to: m4a)
    }

    /// `moveItem` fails when the target exists, so a file that appears between two attempts is not overwritten.
    private static func moveWithoutOverwriting(_ source: URL, to target: URL) throws -> URL {
        let fm = FileManager.default
        let base = target.deletingPathExtension()
        let ext = target.pathExtension
        var candidate = target
        var n = 2
        while true {
            if !fm.fileExists(atPath: candidate.path) {
                do { try fm.moveItem(at: source, to: candidate); return candidate }
                catch let error as NSError where error.code == NSFileWriteFileExistsError { /* taken meanwhile */ }
            }
            candidate = base.deletingLastPathComponent()
                .appendingPathComponent("\(base.lastPathComponent) \(n)").appendingPathExtension(ext)
            n += 1
            if n > 10_000 { throw ConversionError.writerFailed("no free file name") }
        }
    }

    /// Owns the reader and writer; everything after `run()` happens on `queue`.
    private final class Job: @unchecked Sendable {
        private let reader: AVAssetReader
        private let readerOutput: AVAssetReaderTrackOutput
        private let writer: AVAssetWriter
        private let writerInput: AVAssetWriterInput
        private let queue = DispatchQueue(label: "com.hsmm.macrosip.recording-converter")
        private var continuation: CheckedContinuation<Void, Error>?

        init(asset: AVAsset, track: AVAssetTrack, output: URL, sampleRate: Double) throws {
            do { reader = try AVAssetReader(asset: asset) }
            catch { throw ConversionError.readerFailed(error.localizedDescription) }
            readerOutput = AVAssetReaderTrackOutput(track: track, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
                AVNumberOfChannelsKey: 1,
                AVSampleRateKey: sampleRate,
            ])
            guard reader.canAdd(readerOutput) else { throw ConversionError.readerFailed("unsupported format") }
            reader.add(readerOutput)

            do { writer = try AVAssetWriter(outputURL: output, fileType: .m4a) }
            catch { throw ConversionError.writerFailed(error.localizedDescription) }
            writerInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVNumberOfChannelsKey: 1,
                AVSampleRateKey: sampleRate,
                AVEncoderBitRateKey: RecordingConverter.bitRate,
            ])
            guard writer.canAdd(writerInput) else { throw ConversionError.writerFailed("unsupported encoder settings") }
            writer.add(writerInput)
        }

        func run() async throws {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                queue.async {
                    self.continuation = cont
                    guard self.reader.startReading() else {
                        self.fail(ConversionError.readerFailed(self.reader.error?.localizedDescription ?? "unknown error")); return
                    }
                    guard self.writer.startWriting() else {
                        self.reader.cancelReading()
                        self.fail(ConversionError.writerFailed(self.writer.error?.localizedDescription ?? "unknown error")); return
                    }
                    self.writer.startSession(atSourceTime: .zero)
                    self.writerInput.requestMediaDataWhenReady(on: self.queue) { self.pump() }
                }
            }
        }

        private func pump() {
            guard continuation != nil else { return }
            while writerInput.isReadyForMoreMediaData {
                if let sample = readerOutput.copyNextSampleBuffer() {
                    if !writerInput.append(sample) {
                        reader.cancelReading()
                        fail(ConversionError.writerFailed(writer.error?.localizedDescription ?? "append failed")); return
                    }
                } else {
                    writerInput.markAsFinished()
                    if reader.status == .failed {
                        writer.cancelWriting()
                        fail(ConversionError.readerFailed(reader.error?.localizedDescription ?? "unknown error")); return
                    }
                    writer.finishWriting {
                        self.queue.async {
                            if self.writer.status == .completed { self.succeed() }
                            else { self.fail(ConversionError.writerFailed(self.writer.error?.localizedDescription ?? "unknown error")) }
                        }
                    }
                    return
                }
            }
        }

        private func succeed() { continuation?.resume(); continuation = nil }
        private func fail(_ error: Error) { continuation?.resume(throwing: error); continuation = nil }
    }
}

/// Minimal RIFF/WAVE header handling for files whose writer has not finished (or never patched) the sizes.
enum WAVHeader {
    /// Patches zero or oversized RIFF and data sizes from the file length. Returns the number of data
    /// bytes, or nil when the file is not a WAV with a data chunk.
    @discardableResult
    static func repairSizes(of url: URL) -> Int? {
        guard let handle = try? FileHandle(forUpdating: url) else { return nil }
        defer { try? handle.close() }
        guard let length = try? handle.seekToEnd(), length >= 12 else { return nil }
        try? handle.seek(toOffset: 0)
        guard let head = try? handle.read(upToCount: 12), head.count == 12,
              head.prefix(4) == Data("RIFF".utf8), head.suffix(4) == Data("WAVE".utf8) else { return nil }
        func le32(_ d: Data) -> UInt32 { d.enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) } }
        var offset: UInt64 = 12
        while offset + 8 <= length {
            try? handle.seek(toOffset: offset)
            guard let chunk = try? handle.read(upToCount: 8), chunk.count == 8 else { return nil }
            let id = String(decoding: chunk.prefix(4), as: UTF8.self)
            let size = UInt64(le32(chunk.suffix(4)))
            let body = offset + 8
            if id == "data" {
                let available = length - body
                let actual = (size == 0 || size == 0xFFFF_FFFF || size > available) ? available : size
                let riff = UInt32(truncatingIfNeeded: length - 8)
                if size != actual || le32(head.subdata(in: 4..<8)) != riff {
                    func bytes(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
                    try? handle.seek(toOffset: 4); try? handle.write(contentsOf: bytes(riff))
                    try? handle.seek(toOffset: offset + 4); try? handle.write(contentsOf: bytes(UInt32(truncatingIfNeeded: actual)))
                }
                return Int(actual)
            }
            offset = body + size + (size & 1)
        }
        return nil
    }
}
