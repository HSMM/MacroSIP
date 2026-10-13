import AVFoundation
import Foundation

/// Converts an audio file AVFoundation can read (M4A, MP3, AIFF, CAF, or a WAV in another
/// sample format) into the WAV the engine's players need: 16-bit PCM, mono, 16 kHz (the
/// conference bridge's clock rate). The reverse direction of `RecordingConverter`; used for
/// hold music files (`Engine.setHoldMusic`).
public enum AudioFileToWAV {
    public enum ConversionError: Error, Equatable, CustomStringConvertible {
        case cannotRead(String)
        case cannotWrite(String)
        /// The file holds no samples.
        case empty

        public var description: String {
            switch self {
            case let .cannotRead(m): return "Cannot read the audio file: \(m)"
            case let .cannotWrite(m): return "Cannot write the WAV file: \(m)"
            case .empty: return "The audio file is empty"
            }
        }
    }

    /// Output sample rate (the conference bridge's clock rate).
    public static let sampleRate = 16_000.0
    static let chunkFrames: AVAudioFrameCount = 4096

    /// A RIFF/WAVE file whose `fmt ` chunk says 16-bit PCM with one or two channels: pjmedia
    /// plays such a file as it is (any sample rate; the bridge resamples), so it needs no
    /// conversion. Everything else (float or 24-bit WAVs, compressed formats) returns false.
    public static func isPlayableWAV(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 12), head.count == 12,
              head[0..<4] == Data("RIFF".utf8), head[8..<12] == Data("WAVE".utf8) else { return false }
        func le16(_ d: Data) -> Int { Int(d[d.startIndex]) | Int(d[d.startIndex + 1]) << 8 }
        func le32(_ d: Data) -> UInt64 {
            d.enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << (8 * UInt64($1.offset)) }
        }
        var offset: UInt64 = 12
        for _ in 0..<64 {
            guard (try? handle.seek(toOffset: offset)) != nil,
                  let chunk = try? handle.read(upToCount: 8), chunk.count == 8 else { return false }
            let id = String(decoding: chunk.prefix(4), as: UTF8.self)
            let size = le32(chunk.suffix(4))
            if id == "fmt " {
                guard size >= 16, let fmt = try? handle.read(upToCount: 16), fmt.count == 16 else { return false }
                let format = le16(fmt[0..<2])
                let channels = le16(fmt[2..<4])
                let bits = le16(fmt[14..<16])
                return format == 1 && bits == 16 && (1...2).contains(channels)   // WAVE_FORMAT_PCM
            }
            offset += 8 + size + (size & 1)
        }
        return false
    }

    /// Decodes `source`, mixes its channels down to one, resamples to `sampleRate` and writes
    /// `wav` (replaced when it exists). Throws `ConversionError`.
    public static func convert(_ source: URL, to wav: URL, sampleRate: Double = AudioFileToWAV.sampleRate) throws {
        let input: AVAudioFile
        do { input = try AVAudioFile(forReading: source) }
        catch { throw ConversionError.cannotRead(error.localizedDescription) }
        guard input.length > 0 else { throw ConversionError.empty }
        let inFormat = input.processingFormat            // Float32, one buffer per channel
        guard inFormat.channelCount > 0,
              let monoIn = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: inFormat.sampleRate,
                                         channels: 1, interleaved: false),
              let outFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate,
                                            channels: 1, interleaved: true) else {
            throw ConversionError.cannotRead("unsupported format")
        }
        try? FileManager.default.removeItem(at: wav)
        let output: AVAudioFile
        do {
            output = try AVAudioFile(forWriting: wav, settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ], commonFormat: .pcmFormatInt16, interleaved: true)
        } catch { throw ConversionError.cannotWrite(error.localizedDescription) }
        guard let converter = AVAudioConverter(from: monoIn, to: outFormat) else {
            throw ConversionError.cannotWrite("cannot resample \(inFormat.sampleRate) Hz to \(sampleRate) Hz")
        }

        var readError: Error?
        var finished = false
        let channels = Int(inFormat.channelCount)
        // Next chunk of the source, mixed down to one channel (average).
        func nextChunk() -> AVAudioPCMBuffer? {
            guard input.framePosition < input.length,
                  let buf = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: chunkFrames),
                  let mono = AVAudioPCMBuffer(pcmFormat: monoIn, frameCapacity: chunkFrames) else { return nil }
            do { try input.read(into: buf, frameCount: chunkFrames) } catch { readError = error; return nil }
            let n = Int(buf.frameLength)
            guard n > 0, let src = buf.floatChannelData, let dst = mono.floatChannelData?[0] else { return nil }
            dst.update(repeating: 0, count: n)
            for c in 0..<channels {
                let s = src[c]
                for i in 0..<n { dst[i] += s[i] }
            }
            if channels > 1 {
                let k = 1 / Float(channels)
                for i in 0..<n { dst[i] *= k }
            }
            mono.frameLength = buf.frameLength
            return mono
        }

        let capacity = AVAudioFrameCount(Double(chunkFrames) * sampleRate / inFormat.sampleRate) + 1024
        while true {
            guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else {
                throw ConversionError.cannotWrite("out of memory")
            }
            var error: NSError?
            let status = converter.convert(to: out, error: &error) { _, inputStatus in
                if !finished, let chunk = nextChunk() {
                    inputStatus.pointee = .haveData
                    return chunk
                }
                finished = true
                inputStatus.pointee = .endOfStream
                return nil
            }
            if let readError { throw ConversionError.cannotRead(readError.localizedDescription) }
            if status == .error { throw ConversionError.cannotWrite(error?.localizedDescription ?? "resampling failed") }
            if out.frameLength > 0 {
                do { try output.write(from: out) } catch { throw ConversionError.cannotWrite(error.localizedDescription) }
            }
            if status == .endOfStream || (status == .inputRanDry && finished) { break }
        }
        // AVAudioFile finishes the header when it is released, i.e. when this function returns.
    }
}
