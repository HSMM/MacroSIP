import Foundation
import MacroSIPCore

/// What the UI needs from the SIP engine (docs/ENGINE.md "Engine API").
///
/// `MacroSIPCore.Engine` conforms as is (see EngineFactory.swift); `MockEngine` simulates it.
/// Value types (`CallInfo`, `RegistrationState`, `EngineEvent`, ...) come from MacroSIPCore.
protocol SIPEngine: Actor {
    /// Single consumer: iterate from exactly one task.
    nonisolated var events: AsyncStream<EngineEvent> { get }

    func start(network: NetworkSettings, codecPriorities: [String], codecOptions: CodecOptions, callOptions: CallOptions) throws
    func stop()

    // accounts
    func addAccount(_ cfg: AccountConfig, password: String) throws
    func updateAccount(_ cfg: AccountConfig, password: String?) throws
    func removeAccount(_ id: AccountID) throws
    func setRegistered(_ id: AccountID, _ on: Bool) throws
    func registrationState(of id: AccountID) -> RegistrationState

    // calls
    func makeCall(to dial: DialString, from account: AccountID) throws -> CallID
    func answer(_ id: CallID) throws
    func reject(_ id: CallID, code: Int) throws
    func hangup(_ id: CallID) throws
    func hangupAll()
    func setHold(_ id: CallID, _ on: Bool) throws
    func setMute(_ id: CallID, _ on: Bool) throws
    func sendDTMF(_ id: CallID, _ digits: String) throws
    func blindTransfer(_ id: CallID, to dial: DialString) throws
    func attendedTransfer(_ id: CallID, replacing other: CallID) throws
    func calls() -> [CallInfo]
    /// RTCP-derived numbers of a connected call (polled every 2 s by the app).
    func quality(of id: CallID) throws -> CallQuality
    /// Speaker and microphone gain of one call, 0...2 (1 = unity).
    func setCallVolume(_ id: CallID, speaker: Float, microphone: Float) throws
    /// The gain new calls start with.
    func setDefaultCallVolume(speaker: Float, microphone: Float)

    // conference, recording, presence (milestone 5)
    func merge(_ ids: [CallID]) throws
    func split(_ id: CallID) throws
    func startRecording(_ id: CallID, to wavURL: URL, layout: RecordingLayout) throws
    func stopRecording(_ id: CallID) throws -> RecordingFiles
    func recordingFiles(of id: CallID) -> RecordingFiles?
    func subscribePresence(uri: String) throws
    func unsubscribePresence(uri: String) throws
    func publishPresence(_ status: PresenceStatus, for account: AccountID) throws

    // audio
    func audioDevices() -> [AudioDevice]
    /// By device name as stored in `AudioSettings`; nil = system default.
    func setAudioDevices(inputName: String?, outputName: String?) throws
    func setRingtoneDevice(name: String?)
    func setRingtoneFile(_ url: URL?)
    /// 0...1.
    func setRingtoneVolume(_ volume: Float)
    func codecs() -> [CodecInfo]
    func setCodecPriorities(_ ordered: [String]) throws
    func setCodecOptions(_ options: CodecOptions) throws

    /// Second incoming call during a call (waiting tone, window only, busy) and the DTMF method; applies at once.
    func setCallOptions(_ options: CallOptions)

    // hold music, recording notice, voicemail, test tone and UI sounds (docs/ENGINE.md)
    /// What the far end hears while a call is on local hold; works before `start`. A file that cannot be read throws
    /// and the previous source stays.
    func setHoldMusic(_ source: HoldMusic) async throws
    /// A short beep for both sides (and the file) every `intervalSeconds` while a call is recorded; off removes it.
    func setRecordingNotice(enabled: Bool, intervalSeconds: Int)
    /// The latest message-summary of an account; nil before the first NOTIFY, after `removeAccount` and after `stop`.
    func voicemailState(for id: AccountID) -> VoicemailState?
    /// Two notes in a loop for `seconds` on `outputDevice` (a name from `audioDevices()`; nil = the call output).
    func playTestTone(outputDevice: String?, seconds: Double) throws
    func stopTestTone()
    /// A short UI sound on the call output device; never sent to a call or a recording.
    func playEventSound(_ event: SoundEvent) throws

    // network and power
    func networkState() -> NetworkState
    /// Applies what can change while running (rport, keep-alive...); `.needsRestart` when the engine must be stopped and started again (port range, DNS...).
    func applyNetworkSettings(_ settings: NetworkSettings) async throws -> NetworkApplyResult
    /// NSWorkspace.didWakeNotification.
    func handleWake()
    /// NSWorkspace.willSleepNotification.
    func handleSleep()

    // UI-only additions with default implementations until the real engine grows them
    // (listed in the report as "needs the real engine"):
    /// Stops the ringtone but keeps the call ringing (Escape in the incoming panel).
    func silenceRingtone()
    /// Microphone level 0...1 for the Audio pane meter.
    func inputLevel() -> Float
    func audioTransport(ofDeviceNamed name: String) -> AudioTransport
}

extension SIPEngine {
    func silenceRingtone() {}
    /// How the device with this name is connected; the engine does not report it, so CoreAudio is asked.
    func audioTransport(ofDeviceNamed name: String) -> AudioTransport { AudioTransport.lookup(deviceNamed: name) }
    func inputLevel() -> Float { 0 }
}
