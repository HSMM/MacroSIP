internal import CPJSUA
import Foundation

/// `Engine.setRecordingNotice`: whether recorded calls get the periodic beep and how often.
struct RecordingNoticeOptions: Equatable, Sendable {
    var enabled = false
    var intervalSeconds = RecordingSettings.defaultNoticeInterval
}

/// The recording notice: one 1400 Hz beep of 300 ms (the telephony convention) at about
/// -12 dBFS, first one second into the recording, then every interval.
enum RecordingNoticeTone {
    static let frequency: Int16 = 1400
    static let beepMs: Int16 = 300
    static let amplitude: Int16 = 8000
    static let firstDelay: Duration = .seconds(1)

    static func beep() -> pjmedia_tone_desc {
        pjmedia_tone_desc(freq1: frequency, freq2: 0, on_msec: beepMs, off_msec: 0, volume: amplitude, flags: 0)
    }
}

extension Engine {
    /// While a call is recorded and the notice is on, a short beep is mixed into what the far
    /// end hears, into the speaker and into the recording, every `intervalSeconds`
    /// (`RecordingSettings.noticeIntervalRange`, clamped), the first one a second after the
    /// recording starts. Applies at once to recordings in progress (a changed interval
    /// restarts their timers). Works before `start`.
    public func setRecordingNotice(enabled: Bool, intervalSeconds: Int) {
        let new = RecordingNoticeOptions(enabled: enabled, intervalSeconds: RecordingSettings.clampInterval(intervalSeconds))
        guard new != recordingNotice else { return }
        recordingNotice = new
        stopAllRecordingNotices()
        reconcileRecordingNotices()
    }

    var noticeInterval: Duration { noticeIntervalOverride ?? .seconds(recordingNotice.intervalSeconds) }

    /// One tone generator per recording owner, transmitting to the recorded call's port (the
    /// far end), its conference partners (recorded too), the speaker (slot 0) and the
    /// recording's files that carry the far end (the mixed file, the remote file of a stereo
    /// split); the local (microphone) file stays clean. The recorder takes what the call port
    /// *receives*, so a beep sent into the port would not reach the file by itself. Players
    /// of finished recordings are destroyed; a recording that moved to another leg
    /// (`rehomeRecordings`) gets a new player and timer. Runs at the end of every `reconcileMedia`.
    func reconcileRecordingNotices() {
        guard isStarted, PJ.registerThread() else { return }
        for (id, player) in noticePlayers where recordings[id] == nil || player.source == nil {
            stopRecordingNotice(for: id)
        }
        guard recordingNotice.enabled else { return }
        for (id, recording) in recordings {
            guard let snap = CallSnapshot.read(id.raw), snap.serial == id.serial, snap.state != .disconnected,
                  snap.confSlot != PJ.invalidID else { continue }
            if let old = noticePlayers[id], old.sink != snap.confSlot {
                old.stop()
                noticePlayers[id] = nil
            }
            if noticePlayers[id] == nil {
                do {
                    noticePlayers[id] = try TonePlayer(name: "recording notice", deviceID: nil, sink: snap.confSlot) { pool in
                        var src: UnsafeMutablePointer<pjmedia_port>?
                        try PJ.check(cpjsua_dtmf_generator_create(pool, &src), "recording notice generator")
                        guard let src else { throw EngineError.pjsip(status: -1, message: "recording notice: no port") }
                        return src
                    }
                } catch {
                    PJ.warn(error, "recording notice for \(id)")
                    continue
                }
            }
            var sinks: Set<pjsua_conf_port_id> = [snap.confSlot, 0]
            if let conference = bridge.record(id.raw)?.conference {
                for slot in CallSnapshot.allSlots() where slot != id.raw {
                    guard let other = CallSnapshot.read(slot), other.confSlot != PJ.invalidID,
                          other.mediaStatus == .active || other.mediaStatus == .remoteHold,
                          let rec = bridge.record(slot), rec.serial == other.serial, rec.conference == conference
                    else { continue }
                    sinks.insert(other.confSlot)
                }
            }
            for port in recording.ports where port.role != .local && port.confSlot != PJ.invalidID {
                sinks.insert(port.confSlot)
            }
            noticePlayers[id]?.setSinks(sinks)
            startNoticeTimer(id)
        }
    }

    private func startNoticeTimer(_ id: CallID) {
        guard noticeTimers[id] == nil else { return }
        let interval = noticeInterval
        noticeTimers[id] = Task { [weak self] in
            try? await Task.sleep(for: RecordingNoticeTone.firstDelay)
            while !Task.isCancelled {
                guard let self, await self.noticeBeep(id) else { return }
                try? await Task.sleep(for: interval)
            }
        }
    }

    /// One beep; false once the recording is over (the timer then ends). Nothing while the
    /// recorded call is held (nothing is recorded then).
    func noticeBeep(_ id: CallID) -> Bool {
        guard isStarted, PJ.registerThread(), recordings[id] != nil,
              let player = noticePlayers[id], let source = player.source else { return false }
        guard let snap = CallSnapshot.read(id.raw), snap.serial == id.serial,
              snap.mediaStatus == .active || snap.mediaStatus == .remoteHold else { return true }
        var tone = RecordingNoticeTone.beep()
        PJ.warn(cpjsua_tone_sequence_play_once(source, &tone, 1), "recording notice beep")
        return true
    }

    func stopRecordingNotice(for id: CallID) {
        noticeTimers.removeValue(forKey: id)?.cancel()
        noticePlayers.removeValue(forKey: id)?.stop()
    }

    func stopAllRecordingNotices() {
        for id in Array(noticePlayers.keys) { stopRecordingNotice(for: id) }
        for task in noticeTimers.values { task.cancel() }
        noticeTimers = [:]
    }

    // MARK: test hooks

    /// Tests: beep interval in milliseconds instead of the setting (applies to timers started later).
    func setRecordingNoticeInterval(ms: Int) {
        noticeIntervalOverride = .milliseconds(ms)
    }

    /// Notice players and timers alive (tests).
    func recordingNoticeCount() -> (players: Int, timers: Int) { (noticePlayers.count, noticeTimers.count) }

    /// The recording's notice player: the slots it transmits to; nil while none exists (tests).
    func recordingNoticeState(of id: CallID) -> (sinks: Set<pjsua_conf_port_id>, hasTimer: Bool)? {
        guard isStarted, PJ.registerThread(), let player = noticePlayers[id], player.slot != PJ.invalidID else { return nil }
        return (player.appliedSinks(), noticeTimers[id] != nil)
    }
}
