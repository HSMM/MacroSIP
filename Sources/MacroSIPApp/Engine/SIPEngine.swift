import Foundation
import MacroSIPCore

/// What the UI needs from the SIP engine (Lite subset of docs/ENGINE.md "Engine API").
///
/// `MacroSIPCore.Engine` conforms as is (see EngineFactory.swift); `MockEngine` simulates it.
/// Value types (`CallInfo`, `RegistrationState`, `EngineEvent`, ...) come from MacroSIPCore.
protocol SIPEngine: Actor {
    /// Single consumer: iterate from exactly one task.
    nonisolated var events: AsyncStream<EngineEvent> { get }

    func start(network: NetworkSettings, codecPriorities: [String]) throws
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

    // audio
    func audioDevices() -> [AudioDevice]
    func setAudioDevices(input: Int?, output: Int?) throws
    func setRingtoneDevice(_ id: Int?)
    func setRingtoneFile(_ url: URL?)
    func codecs() -> [CodecInfo]
    func setCodecPriorities(_ ordered: [String]) throws

    // UI-only additions with default implementations until the real engine grows them
    // (listed in the report as "needs the real engine"):
    /// Stops the ringtone but keeps the call ringing (Escape in the incoming panel).
    func silenceRingtone()
    /// Microphone level 0...1 for the Audio pane meter.
    func inputLevel() -> Float
}

extension SIPEngine {
    func silenceRingtone() {}
    func inputLevel() -> Float { 0 }
}
