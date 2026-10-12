import Foundation
import os
import MacroSIPCore

private let recordingLog = Logger(subsystem: "com.hsmm.macrosip", category: "recording")

/// Recording of calls (SCREENS.md 4.1, 8.6): the engine writes a temporary WAV; when the recording
/// stops or the call ends it is converted to M4A in the recordings folder and the WAV is deleted.
extension AppModel {
    // MARK: - Folder

    /// The folder chosen in Settings (resolved from its security-scoped bookmark when there is one).
    /// Demo launches keep recordings inside their throw-away data directory.
    func recordingsFolder() -> (url: URL, stopAccess: @Sendable () -> Void) {
        var url = settings.recording.folder ?? RecordingFileName.defaultFolder
        if settings.recording.folder == nil, launch.isDemo, let dir = launch.dataDirectory {
            url = dir.appendingPathComponent("Recordings", isDirectory: true)
        }
        if let data = settings.recording.folderBookmark {
            var stale = false
            if let resolved = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil,
                                       bookmarkDataIsStale: &stale) {
                url = resolved
                if resolved.startAccessingSecurityScopedResource() {
                    return (url, { resolved.stopAccessingSecurityScopedResource() })
                }
            }
        }
        return (url, {})
    }

    /// The folder shown in Settings (no security-scoped access needed to name it).
    var recordingsFolderForDisplay: URL {
        let access = recordingsFolder()
        access.stopAccess()
        return access.url
    }

    // MARK: - Start and stop

    private var temporaryRecordingsDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("MacroSIP-Recording", isDirectory: true)
    }

    /// The calls a Record / Mute press on `call` applies to: the whole conference, or the call itself.
    func legs(of call: CallInfo) -> [CallInfo] {
        call.inConference ? conferenceCalls : [call]
    }

    /// True when the call, or any leg of its conference, is being recorded.
    func isRecording(_ call: CallInfo) -> Bool { legs(of: call).contains(where: \.isRecording) }

    /// The engine mixes every conference leg and the microphone into the one WAV started on any leg,
    /// so a conference has exactly one recording, on its primary leg (lowest call serial).
    /// If that leg is split out or hangs up, its file is finalised and not restarted.
    func toggleRecording(_ call: CallInfo) {
        let legs = legs(of: call).filter(\.isEstablished)
        if legs.contains(where: \.isRecording) {
            for leg in legs where leg.isRecording { stopRecording(leg) }
        } else if let primary = legs.min(by: { $0.id.serial < $1.id.serial }) {
            startRecording(primary)
        }
    }

    func startRecording(_ call: CallInfo) {
        guard recordingJobs[call.id] == nil, call.isEstablished else { return }
        let wav = temporaryRecordingsDirectory.appendingPathComponent("\(UUID().uuidString).wav")
        recordingJobs[call.id] = RecordingJob(wav: wav, startedAt: Date(), direction: call.direction)
        let id = call.id
        run {
            do { try await self.engine.startRecording(id, to: wav) }
            catch {
                self.recordingJobs[id] = nil
                throw error
            }
        }
    }

    func stopRecording(_ call: CallInfo) {
        let id = call.id
        guard let job = recordingJobs[id] else { return }
        run {
            do {
                let wav = try await self.engine.stopRecording(id)
                self.finishRecording(id, call: self.calls.first { $0.id == id } ?? call, wav: wav)
            } catch {
                // Whatever the engine had written so far is still worth keeping.
                if FileManager.default.fileExists(atPath: job.wav.path) {
                    self.finishRecording(id, call: call, wav: job.wav)
                } else {
                    self.recordingJobs[id] = nil
                }
                throw error
            }
        }
    }

    // MARK: - Engine events

    /// Called for every call update: tracks the REC chip and starts "record all calls".
    func noteRecordingState(_ info: CallInfo) {
        if info.isRecording {
            if recordingSince[info.id] == nil { recordingSince[info.id] = recordingJobs[info.id]?.startedAt ?? Date() }
        } else {
            recordingSince[info.id] = nil
        }
        if settings.recording.recordAllCalls, info.state == .connected, !info.isRecording,
           !autoRecordTried.contains(info.id) {
            autoRecordTried.insert(info.id)
            startRecording(info)
        }
    }

    /// The call is gone: the engine closed the recording with it.
    func recordingCallEnded(_ info: CallInfo) {
        recordingSince[info.id] = nil
        autoRecordTried.remove(info.id)
        if let job = recordingJobs[info.id] { finishRecording(info.id, call: info, wav: job.wav) }
    }

    // MARK: - Conversion

    @discardableResult
    private func finishRecording(_ id: CallID, call: CallInfo, wav: URL) -> Task<Void, Never>? {
        guard let job = recordingJobs.removeValue(forKey: id) else { return nil }
        let remote = name(for: call.remote)
        let fileName = RecordingFileName.make(date: job.startedAt, remote: remote, direction: job.direction)
        let folder = recordingsFolder()
        return Task.detached(priority: .utility) {
            defer { folder.stopAccess() }
            do {
                guard FileManager.default.fileExists(atPath: wav.path) else {
                    throw RecordingConverter.ConversionError.readerFailed("the temporary recording is missing")
                }
                try FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: true)
                let target = RecordingFileName.uniqueURL(in: folder.url, name: fileName)
                try await RecordingConverter.convert(wav: wav, to: target)
                try? FileManager.default.removeItem(at: wav)
                recordingLog.info("saved \(target.lastPathComponent, privacy: .public)")
                await AppModel.shared.recordingSaved(target)
            } catch {
                recordingLog.error("conversion of \(wav.lastPathComponent, privacy: .public) failed: \(describe(error), privacy: .public); the WAV was kept")
                await AppModel.shared.showBanner(L.bannerRecordingFailed(describe(error)))
            }
        }
    }

    /// Quitting: recordings still running are stopped and converted before the app exits.
    func finishRecordingsForQuit() async {
        var tasks: [Task<Void, Never>] = []
        for call in calls where recordingJobs[call.id] != nil {
            let wav = (try? await engine.stopRecording(call.id)) ?? recordingJobs[call.id]?.wav
            if let wav, let t = finishRecording(call.id, call: call, wav: wav) { tasks.append(t) }
        }
        for t in tasks { await t.value }
    }

    /// Hook for the self-test and the UI.
    func recordingSaved(_ url: URL) {
        savedRecordings.append(url)
    }
}
