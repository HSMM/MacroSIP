internal import CPJSUA
import Foundation

/// One call recording: a pjsua recorder (WAV writer port in the conference bridge).
struct Recording: Sendable {
    var recorderID: pjsua_recorder_id
    var confSlot: pjsua_conf_port_id
    var url: URL
}

extension Engine {
    /// How long `stopRecording` (and the automatic stop at the end of a call) waits for the
    /// conference bridge to drop the recorder, which writes the final WAV header.
    static let recorderFinaliseTimeoutMs: UInt32 = 500

    /// Records the call into `wavURL` (WAV, 16-bit PCM mono at the conference clock rate,
    /// 16 kHz by default): the remote side plus our microphone (left out while muted). For a
    /// conference leg every leg of that conference goes into the same file. Nothing is
    /// written while the call is on hold. The parent directory is created when missing; an
    /// existing file is overwritten. One recording per call (`.invalidArgument` otherwise).
    /// The recording stops by itself when the call ends; that call's `.callEnded` then
    /// reports `isRecording == true` and is emitted only after the WAV is finalised.
    public func startRecording(_ id: CallID, to wavURL: URL) throws {
        _ = try liveSlot(id)
        guard recordings[id] == nil else {
            throw EngineError.invalidArgument("call \(id) is already being recorded")
        }
        guard wavURL.isFileURL, wavURL.pathExtension.lowercased() == "wav" else {
            throw EngineError.invalidArgument("recording file \(wavURL) must be a local .wav file")
        }
        let dir = wavURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            throw EngineError.invalidArgument("cannot create \(dir.path): \(error.localizedDescription)")
        }
        let path = wavURL.path
        var recorder = PJ.invalidID
        var slot = PJ.invalidID
        try PJ.check(path.withCString { cpjsua_recorder_create($0, &recorder, &slot) }, "create recorder \(path)")
        recordings[id] = Recording(recorderID: recorder, confSlot: slot, url: wavURL)
        do {
            try updateRecord(id) { $0.isRecording = true }   // also wires the recorder
        } catch {
            finishRecorder(id)                                 // the call ended meanwhile
            try? FileManager.default.removeItem(at: wavURL)
            throw error
        }
    }

    /// Stops the call's recording and returns its file. The WAV is complete (header
    /// finalised) when this returns, unless the bridge did not run within 0.5 s (logged).
    /// Works for a call that has just ended as long as its recording was not finished yet.
    public func stopRecording(_ id: CallID) throws -> URL {
        try requireStarted()
        guard let recording = recordings[id] else {
            _ = try liveSlot(id)
            throw EngineError.invalidArgument("call \(id) is not being recorded")
        }
        finishRecorder(id)
        if let snap = CallSnapshot.read(id.raw), snap.serial == id.serial {
            bridge.updateCall(snap, mode: .updateOnly, mutate: { $0.isRecording = false },
                              event: { info, rec in rec.announced ? .callChanged(info) : nil })
        }
        releaseFinishedEnds()
        reconcileMedia()
        return recording.url
    }

    /// Destroys the call's recorder and waits for the WAV header. Leaves `isRecording` of the
    /// call's record alone (an ended call keeps reporting it).
    func finishRecorder(_ id: CallID) {
        guard let recording = recordings.removeValue(forKey: id) else { return }
        // Its wires disappear with the port; forget our requests for them.
        requestedWiring = requestedWiring.filter { $0.key.src != recording.confSlot && $0.key.sink != recording.confSlot }
        slotOwners[recording.confSlot] = nil
        var finalised: Int32 = 0
        let status = cpjsua_recorder_destroy_wait(recording.recorderID, Engine.recorderFinaliseTimeoutMs, &finalised)
        if status != PJ.success {
            PJ.warn(status, "stop recording \(recording.url.lastPathComponent)")
        } else if finalised == 0 {
            // The bridge did not run (no sound device clock): PJSIP writes the header when it
            // processes the removal, at the latest in pjsua_destroy.
            let text = "recording \(recording.url.lastPathComponent): WAV header not final after "
                + "\(Engine.recorderFinaliseTimeoutMs) ms (conference bridge idle)"
            bridge.engineLogger.error("\(text, privacy: .public)")
            emit(.log(level: 2, "engine: \(text)"))
        }
    }

    /// Releases the held-back `.callEnded` of recorded calls whose recording is finished.
    func releaseFinishedEnds() {
        bridge.releaseDeferredEnds(keeping: Set(recordings.keys.map(\.serial)))
    }

    /// After a call ended: stop its recording (finalising the WAV), then emit its
    /// `.callEnded`; dissolve conferences left with one leg; rewire the bridge.
    func finishEndedCalls() {
        guard isStarted, PJ.registerThread() else { return }
        for id in Array(recordings.keys) where !isLive(id) {
            finishRecorder(id)
        }
        releaseFinishedEnds()
        dissolveSingleLegConferences()
        reconcileMedia()
    }

    /// The call still has its bridge record (it has not reached DISCONNECTED).
    func isLive(_ id: CallID) -> Bool {
        bridge.record(id.raw)?.serial == id.serial
    }
}
