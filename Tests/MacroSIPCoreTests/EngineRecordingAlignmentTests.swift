import Foundation
import os
import Testing
@testable import MacroSIPCore

// Stereo split recording: the local and the remote file share one timeline. A tone burst is
// put into both sides on the same bridge frame (`Engine.playTestMarker`); where it lands in
// each file shows how far apart the files are. The bridge works in 20 ms frames, so sides that
// came apart are off by whole frames; sides that did not are off by nothing at all.

/// Busy threads that spin until `stop()`: CPU load for the length of a call.
final class CPULoad: Sendable {
    private let running = OSAllocatedUnfairLock(initialState: true)

    init(threads: Int) {
        for i in 0..<threads {
            let thread = Thread { [running] in
                var x: UInt64 = 1
                while running.withLock({ $0 }) {
                    for _ in 0..<20_000 { x = x &* 6364136223846793005 &+ 1442695040888963407 }
                }
                withExtendedLifetime(x) {}
            }
            thread.name = "cpu load \(i)"
            thread.start()
        }
    }

    func stop() { running.withLock { $0 = false } }
}

/// The 16-bit samples of a canonical 44-byte-header mono WAV.
func wavInt16Samples(_ url: URL) throws -> [Int16] {
    let data = try Data(contentsOf: url)
    guard data.count > 44 else { return [] }
    return stride(from: 44, to: data.count - 1, by: 2).map {
        Int16(bitPattern: UInt16(data[$0]) | UInt16(data[$0 + 1]) << 8)
    }
}

/// Sample indices where a tone burst starts: the first sample above `threshold` after at
/// least `gap` samples (250 ms at 16 kHz) below it.
func burstOnsets(_ samples: [Int16], threshold: Int16 = 4000, gap: Int = 4000) -> [Int] {
    var onsets: [Int] = []
    var lastLoud = -gap - 1
    for (i, s) in samples.enumerated() where abs(Int(s)) > Int(threshold) {
        if i - lastLoud > gap { onsets.append(i) }
        lastLoud = i
    }
    return onsets
}

extension EngineTests {
    /// One stereo split recording: per marker the local file's position minus the remote
    /// file's (ms; positive = later in the local file), and the length difference.
    struct StereoAlignment: CustomStringConvertible {
        var markerOffsetsMs: [Double]
        /// Where each marker starts in the local file (samples).
        var localOnsets: [Int]
        var localMarkers: Int
        var remoteMarkers: Int
        var lengthDifferenceMs: Double

        var description: String {
            let offsets = markerOffsetsMs.map { String(format: "%.1f", $0) }.joined(separator: ", ")
            return "markers local \(localMarkers) remote \(remoteMarkers), offsets ms [\(offsets)], "
                + String(format: "length difference %.1f ms", lengthDifferenceMs)
        }

        /// Every marker found in both files at the same sample, same length.
        func linesUp(markers: Int) -> Bool {
            localMarkers == markers && remoteMarkers == markers
                && markerOffsetsMs.allSatisfy { $0 == 0 } && lengthDifferenceMs == 0
        }
    }

    static func stereoAlignment(_ files: RecordingFiles) throws -> StereoAlignment {
        let local = try wavInt16Samples(try #require(files.local))
        let remote = try wavInt16Samples(try #require(files.remote))
        let l = burstOnsets(local), r = burstOnsets(remote)
        return StereoAlignment(markerOffsetsMs: zip(l, r).map { Double($0 - $1) / 16 }, localOnsets: l,
                               localMarkers: l.count, remoteMarkers: r.count,
                               lengthDifferenceMs: Double(local.count - remote.count) / 16)
    }

    func connectedLoopbackCall() async throws -> (Loopback, CallID, Task<Void, Never>) {
        let engine = await makeEngine()
        let log = EventLog()
        let consumer = log.consume(engine)
        try await engine.start(network: Self.network)
        let account = AccountConfig(displayName: "L", username: "loop", domain: "127.0.0.1", enabled: false)
        try await engine.addAccount(account, password: "")
        let lb = Loopback(engine: engine, log: log, account: account, port: await engine.localPort(of: .udp))
        let (out, _) = try await lb.connectedCall("s")
        return (lb, out, consumer)
    }

    /// Both sides of the stereo recording of `id` receive their sources.
    static func stereoWired(_ engine: Engine, _ id: CallID) async -> Bool {
        let remote = await engine.recorderHears(id, from: id, role: .remote)
        let local = await engine.recorderHears(id, from: nil, role: .local)
        return remote && local
    }

    /// Three stereo split recordings of a loopback call, with and without a busy thread per
    /// core, each with a marker after the start, after a hold and resume (both sides are
    /// disconnected and connected again) and after a mute and unmute; then one that the end
    /// of the call stops. Every marker starts on the same sample in both files and the files
    /// have the same length. (With two pjsua recorders a hold and resume moved the files one frame
    /// apart in 2 of 36 such recordings without load; the CI runner once ended a pair 5 frames
    /// apart.)
    @Test(arguments: [false, true])
    func stereoSplitMarkersLineUp(underLoad: Bool) async throws {
        let (lb, out, consumer) = try await connectedLoopbackCall()
        defer { consumer.cancel() }
        let engine = lb.engine
        let dir = tempWAV("x").deletingLastPathComponent().deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: dir) }
        let load = underLoad ? CPULoad(threads: ProcessInfo.processInfo.activeProcessorCount) : nil
        defer { load?.stop() }

        for cycle in 0..<3 {
            try await engine.startRecording(out, to: dir.appendingPathComponent("rec/\(cycle).wav"), layout: .stereoSplit)
            #expect(await waitUntil(timeout: 3) { await Self.stereoWired(engine, out) })
            try await Task.sleep(for: .milliseconds(200))
            try await engine.playTestMarker(out)

            try await engine.setHold(out, true)
            #expect(await waitUntil { await lb.call(out)?.state == .held })
            try await Task.sleep(for: .milliseconds(200))
            try await engine.setHold(out, false)
            #expect(await waitUntil { await lb.call(out)?.state == .connected })
            #expect(await waitUntil(timeout: 3) { await Self.stereoWired(engine, out) })
            try await Task.sleep(for: .milliseconds(200))
            try await engine.playTestMarker(out)

            try await engine.setMute(out, true)
            try await Task.sleep(for: .milliseconds(200))
            try await engine.setMute(out, false)
            #expect(await waitUntil { await engine.localRecorderLevel(out) == 1 })
            try await Task.sleep(for: .milliseconds(100))
            try await engine.playTestMarker(out)

            let alignment = try Self.stereoAlignment(try await engine.stopRecording(out))
            #expect(alignment.linesUp(markers: 3), "recording \(cycle), load \(underLoad): \(alignment)")
        }

        // The call ends while the recording runs (its port leaves the bridge before the
        // engine stops the recording).
        try await engine.startRecording(out, to: dir.appendingPathComponent("rec/ended.wav"), layout: .stereoSplit)
        #expect(await waitUntil(timeout: 3) { await Self.stereoWired(engine, out) })
        try await Task.sleep(for: .milliseconds(200))
        try await engine.playTestMarker(out)
        try await engine.hangup(out)
        #expect(await waitUntil { lb.ended { $0.id == out } != nil })
        let ended = try Self.stereoAlignment(try #require(await engine.recordingFiles(of: out)))
        #expect(ended.linesUp(markers: 1), "call ended, load \(underLoad): \(ended)")
        await engine.stop()
    }

    /// One side of a stereo split loses its sources for 200 ms while the other keeps them (what
    /// happens when the bridge applies the two sides' connections on different frames, or when
    /// the call's port is replaced and reconnected): the files still share one timeline, and the
    /// cut is filled with silence rather than left out of both. Two pjsua recorders came
    /// 220 ms apart here (the cut plus the frame of the reconnect).
    @Test(arguments: [RecorderPort.Role.remote, .local])
    func stereoSplitSideCutOffKeepsTimeline(cut: RecorderPort.Role) async throws {
        let (lb, out, consumer) = try await connectedLoopbackCall()
        defer { consumer.cancel() }
        let engine = lb.engine
        let dir = tempWAV("x").deletingLastPathComponent().deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: dir) }

        try await engine.startRecording(out, to: dir.appendingPathComponent("rec/cut.wav"), layout: .stereoSplit)
        #expect(await waitUntil(timeout: 3) { await Self.stereoWired(engine, out) })
        try await Task.sleep(for: .milliseconds(200))
        try await engine.playTestMarker(out)
        try await engine.cutTestRecorderSide(out, role: cut, for: .milliseconds(200))
        #expect(await waitUntil(timeout: 3) { await Self.stereoWired(engine, out) })
        try await Task.sleep(for: .milliseconds(200))
        try await engine.playTestMarker(out)
        let alignment = try Self.stereoAlignment(try await engine.stopRecording(out))
        try await engine.hangup(out)
        await engine.stop()

        #expect(alignment.linesUp(markers: 2), "\(cut) side cut off for 200 ms: \(alignment)")
        // Between the two markers 580 ms pass at least (the first marker's 180 ms, the cut, the
        // 200 ms sleep); a writer that dropped the frames of the cut would leave about 360 ms.
        if alignment.localOnsets.count == 2 {
            let gapMs = Double(alignment.localOnsets[1] - alignment.localOnsets[0]) / 16
            #expect(gapMs >= 560, "\(cut) side cut off: markers \(gapMs) ms apart in the files")
        }
    }

    /// With the recording notice on, a held call writes nothing, mono or stereo: no file grows
    /// during the hold. The notice generator leaves the recorder ports while the media is down;
    /// connected, it would hand them a frame of silence every 20 ms.
    @Test(arguments: [RecordingLayout.mono, .stereoSplit])
    func heldCallWithNoticeRecordsNothing(layout: RecordingLayout) async throws {
        let (lb, out, consumer) = try await connectedLoopbackCall()
        defer { consumer.cancel() }
        let engine = lb.engine
        let dir = tempWAV("x").deletingLastPathComponent().deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: dir) }
        let role: RecorderPort.Role = layout == .mono ? .mixed : .remote

        await engine.setRecordingNotice(enabled: true, intervalSeconds: 5)
        try await engine.startRecording(out, to: dir.appendingPathComponent("rec/held.wav"), layout: layout)
        #expect(await waitUntil { await engine.recordingNoticeState(of: out) != nil })
        #expect(await waitUntil(timeout: 3) { await engine.recorderHears(out, from: out, role: role) })
        try await Task.sleep(for: .milliseconds(300))
        try await engine.setHold(out, true)
        #expect(await waitUntil { await lb.call(out)?.state == .held })
        #expect(await waitUntil(timeout: 3) { !(await engine.recorderHears(out, from: out, role: role)) })
        try await Task.sleep(for: .milliseconds(300))
        let files = try #require(await engine.recordingFiles(of: out))
        func sizes() -> [Int] {
            files.all.map { ((try? FileManager.default.attributesOfItem(atPath: $0.path))?[.size] as? Int) ?? -1 }
        }
        let before = sizes()
        try await Task.sleep(for: .seconds(1))
        let during = sizes()
        #expect(during == before, "\(layout): files grew during the hold from \(before) to \(during) bytes")
        #expect(await engine.recordingNoticeState(of: out) != nil)      // the notice itself stays

        try await engine.setHold(out, false)
        #expect(await waitUntil { await lb.call(out)?.state == .connected })
        _ = try await engine.stopRecording(out)
        try await engine.hangup(out)
        await engine.stop()
    }
}
