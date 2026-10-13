import AVFoundation
import Foundation
import MacroSIPCore

/// Self-test step: a stereo split recording of the first call (pjsua plays its tone; our
/// side is the null audio device, i.e. silence).
extension SelfTest {
    /// Records the call for 3 s as `.stereoSplit`, muted for the middle second (the local
    /// file must keep pace with the remote one). Both WAVs final, lengths within one 20 ms
    /// frame (640 bytes at 16 kHz), the remote one has the tone, the local one is silent;
    /// then `RecordingConverter.convert(files:)` must give a 2-channel M4A whose right
    /// (remote) channel carries the energy.
    static func stereoRecording(_ engine: Engine, _ id: CallID, scratch: URL, step: (String) -> Void) async throws {
        let base = scratch.appendingPathComponent("recordings/stereo.wav")
        let planned = RecordingFiles.planned(for: base, layout: .stereoSplit)
        try await engine.startRecording(id, to: base, layout: .stereoSplit)
        _ = try await waitFor(engine, id, "isRecording (stereo)", timeout: 2) { $0.isRecording }
        guard await engine.recordingFiles(of: id) == planned else {
            throw Failure(description: "recordingFiles(of:) = \(String(describing: await engine.recordingFiles(of: id)))")
        }
        try await Task.sleep(for: .seconds(1))
        try await engine.setMute(id, true)
        try await Task.sleep(for: .seconds(1))
        try await engine.setMute(id, false)
        try await Task.sleep(for: .seconds(1))
        let files = try await engine.stopRecording(id)
        guard files == planned, let local = files.local, let remote = files.remote, files.mixed == nil else {
            throw Failure(description: "stopRecording(stereo) returned \(files), expected \(planned)")
        }
        _ = try await waitFor(engine, id, "isRecording cleared (stereo)", timeout: 2) { !$0.isRecording }
        guard await engine.recordingFiles(of: id) == nil else {
            throw Failure(description: "recordingFiles(of:) still set after stopRecording")
        }
        guard !FileManager.default.fileExists(atPath: base.path) else {
            throw Failure(description: "stereo recording created \(base.lastPathComponent) itself")
        }
        let remoteHeader = try checkWAV(remote, minBytes: 50_000)
        let localHeader = try checkWAV(local, minBytes: 50_000, silent: true)
        let difference = abs(remoteHeader.fileSize - localHeader.fileSize)
        guard difference <= 640 else {
            throw Failure(description: "stereo WAVs differ by \(difference) bytes (local \(localHeader.fileSize), "
                          + "remote \(remoteHeader.fileSize)); more than one 20 ms frame")
        }
        step("stereo recording (muted 1 s of 3): local \(localHeader.fileSize) bytes RMS \(localHeader.rms), "
             + "remote \(remoteHeader.fileSize) bytes RMS \(remoteHeader.rms), difference \(difference) bytes")

        let m4a = scratch.appendingPathComponent("recordings/stereo.m4a")
        let out = try await RecordingConverter.convert(files: files, to: m4a)
        let size = fileSize(out)
        let audio: AVAudioFile
        do { audio = try AVAudioFile(forReading: out) } catch {
            throw Failure(description: "\(out.lastPathComponent): \(error.localizedDescription)")
        }
        let channels = Int(audio.processingFormat.channelCount)
        guard size > 1_000, channels == 2 else {
            throw Failure(description: "\(out.lastPathComponent): \(size) bytes, \(channels) channels")
        }
        let (left, right) = try channelRMS(audio)
        guard right > 0.02, left < right / 10 else {
            throw Failure(description: "\(out.lastPathComponent): RMS left (local) \(left), right (remote) \(right)")
        }
        step("stereo M4A: \(out.lastPathComponent) \(size) bytes, 2 channels, "
             + String(format: "RMS left %.4f, right %.4f", left, right))
    }

    /// Root mean square of the first two channels of a whole audio file (float samples).
    static func channelRMS(_ file: AVAudioFile) throws -> (Double, Double) {
        let frames = AVAudioFrameCount(file.length)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames) else {
            throw Failure(description: "cannot read \(file.url.lastPathComponent)")
        }
        try file.read(into: buffer)
        guard let data = buffer.floatChannelData, buffer.format.channelCount >= 2 else {
            throw Failure(description: "\(file.url.lastPathComponent): not two float channels")
        }
        func rms(_ ch: Int) -> Double {
            let n = Int(buffer.frameLength)
            guard n > 0 else { return 0 }
            var sum = 0.0
            for i in 0..<n { let v = Double(data[ch][i]); sum += v * v }
            return (sum / Double(n)).squareRoot()
        }
        return (rms(0), rms(1))
    }
}
