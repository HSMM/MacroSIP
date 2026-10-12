import Foundation
import AVFoundation

/// Converts the engine's temporary WAV recording into the M4A (AAC) file the user keeps
/// (SCREENS.md 8.6): mono, 64 kbit/s.
public enum RecordingConverter {
    public enum ConversionError: Error, Equatable, CustomStringConvertible {
        case noAudioTrack
        case readerFailed(String)
        case writerFailed(String)

        public var description: String {
            switch self {
            case .noAudioTrack: return "The recording contains no audio"
            case let .readerFailed(m): return "Cannot read the recording: \(m)"
            case let .writerFailed(m): return "Cannot write the M4A file: \(m)"
            }
        }
    }

    public static let bitRate = 64_000

    /// Writes `m4a` (replacing a file that exists there). The output appears under its final
    /// name only when it is complete; a failed conversion leaves nothing behind.
    public static func convert(wav: URL, to m4a: URL) async throws {
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

        if fm.fileExists(atPath: m4a.path) { try fm.removeItem(at: m4a) }
        try fm.moveItem(at: partial, to: m4a)
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
