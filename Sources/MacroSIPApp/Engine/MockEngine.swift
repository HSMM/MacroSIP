import Foundation
import MacroSIPCore

/// Simulated engine for UI development and `--mock-engine`.
/// Registration: registering, then registered after 1 s. Outgoing call: calling, early, connected after 2 s.
/// A password of "wrong" (or a domain containing "fail") makes registration fail with 403.
actor MockEngine: SIPEngine {
    nonisolated let events: AsyncStream<EngineEvent>
    private nonisolated let continuation: AsyncStream<EngineEvent>.Continuation

    private var started = false
    private var accounts: [AccountID: AccountConfig] = [:]
    private var passwords: [AccountID: String] = [:]
    private var registration: [AccountID: RegistrationState] = [:]
    private var callTable: [CallID: CallInfo] = [:]
    private var order: [CallID] = []
    private var serial: UInt64 = 0
    private var level: Float = 0

    private let devices = [
        AudioDevice(id: 0, name: "MacBook Pro Microphone", inputChannels: 1, outputChannels: 0),
        AudioDevice(id: 1, name: "MacBook Pro Speakers", inputChannels: 0, outputChannels: 2),
        AudioDevice(id: 2, name: "USB Headset", inputChannels: 1, outputChannels: 2),
    ]
    private var codecOrder = AppSettings.defaultCodecOrder
    private var codecEnabled = Set(AppSettings.defaultCodecOrder)

    init() {
        (events, continuation) = AsyncStream.makeStream(of: EngineEvent.self, bufferingPolicy: .unbounded)
    }

    deinit { continuation.finish() }

    private func emit(_ e: EngineEvent) { continuation.yield(e) }

    // MARK: lifecycle

    func start(network: NetworkSettings, codecPriorities: [String]) throws {
        guard !started else { throw EngineError.alreadyStarted }
        started = true
        try setCodecPriorities(codecPriorities)
    }

    func stop() {
        guard started else { return }
        hangupAll()
        for id in accounts.keys { set(id, .unregistered) }
        accounts = [:]
        started = false
    }

    // MARK: accounts

    private func set(_ id: AccountID, _ state: RegistrationState) {
        registration[id] = state
        emit(.registration(id, state))
    }

    func addAccount(_ cfg: AccountConfig, password: String) throws {
        guard started else { throw EngineError.notStarted }
        guard accounts[cfg.id] == nil else { throw EngineError.invalidArgument("account is already added") }
        accounts[cfg.id] = cfg
        passwords[cfg.id] = password
        registration[cfg.id] = .unregistered
        emit(.registration(cfg.id, .unregistered))
        if cfg.enabled { try setRegistered(cfg.id, true) }
    }

    func updateAccount(_ cfg: AccountConfig, password: String?) throws {
        guard started else { throw EngineError.notStarted }
        guard accounts[cfg.id] != nil else { throw EngineError.unknownAccount(cfg.id) }
        accounts[cfg.id] = cfg
        if let password { passwords[cfg.id] = password }
        if cfg.enabled { try setRegistered(cfg.id, true) } else { try setRegistered(cfg.id, false) }
    }

    func removeAccount(_ id: AccountID) throws {
        guard started else { throw EngineError.notStarted }
        guard accounts[id] != nil else { throw EngineError.unknownAccount(id) }
        for call in callTable.values where call.accountID == id { try? hangup(call.id) }
        accounts[id] = nil
        passwords[id] = nil
        registration[id] = nil
    }

    func setRegistered(_ id: AccountID, _ on: Bool) throws {
        guard started else { throw EngineError.notStarted }
        guard let cfg = accounts[id] else { throw EngineError.unknownAccount(id) }
        guard on else { set(id, .unregistered); return }
        set(id, .registering)
        let password = passwords[id] ?? ""
        let fails = password == "wrong" || cfg.domain.contains("fail")
        let expires = cfg.registrationInterval
        Task {
            try? await Task.sleep(for: .seconds(1))
            guard self.accounts[id] != nil, self.registration[id] == .registering else { return }
            self.set(id, fails ? .failed(code: 403, reason: "Forbidden") : .registered(expires: expires))
        }
    }

    func registrationState(of id: AccountID) -> RegistrationState { registration[id] ?? .unregistered }

    // MARK: calls

    private func nextID() -> CallID {
        serial += 1
        return CallID(raw: Int32(order.count % 8), serial: serial)
    }

    private func publish(_ info: CallInfo) {
        if callTable[info.id] == nil { order.append(info.id) }
        callTable[info.id] = info
    }

    private func change(_ id: CallID, _ body: (inout CallInfo) -> Void) throws {
        guard var info = callTable[id] else { throw EngineError.noSuchCall(id) }
        body(&info)
        callTable[id] = info
        emit(.callChanged(info))
    }

    func makeCall(to dial: DialString, from account: AccountID) throws -> CallID {
        guard started else { throw EngineError.notStarted }
        guard let cfg = accounts[account] else { throw EngineError.unknownAccount(account) }
        guard callTable.count < 4 else { throw EngineError.tooManyCalls(limit: 4) }
        let id = nextID()
        let info = CallInfo(
            id: id, accountID: account, direction: .outgoing, state: .calling,
            remote: RemoteParty(displayName: Self.sampleName(for: dial.display), uri: dial.uri, number: dial.display),
            isSecure: cfg.srtp != .disabled)
        publish(info)
        emit(.callChanged(info))
        Task {
            try? await Task.sleep(for: .milliseconds(700))
            try? self.change(id) { if $0.state == .calling { $0.state = .early } }
            try? await Task.sleep(for: .milliseconds(1300))
            try? self.change(id) {
                guard $0.state == .early || $0.state == .calling else { return }
                $0.state = .connected; $0.startedAt = Date(); $0.codec = "opus/48000"
            }
        }
        return id
    }

    private static func sampleName(for number: String) -> String? {
        ["100": "Reception", "101": "Boris Ivanov", "102": "Anna Petrova"][number]
    }

    /// Debug menu: an incoming call on `account` (first account when nil).
    func simulateIncoming(name: String?, number: String, account: AccountID? = nil) {
        guard let acct = account ?? accounts.keys.first, callTable.count < 4 else { return }
        let id = nextID()
        let info = CallInfo(
            id: id, accountID: acct, direction: .incoming, state: .incoming,
            remote: RemoteParty(displayName: name, uri: "sip:\(number)@mock.example.org", number: number),
            isSecure: false)
        publish(info)
        emit(.incomingCall(info))
    }

    func answer(_ id: CallID) throws {
        try change(id) { $0.state = .connected; $0.startedAt = Date(); $0.codec = "opus/48000" }
    }

    func reject(_ id: CallID, code: Int) throws { try end(id, code: code, reason: "Busy Here") }
    func hangup(_ id: CallID) throws { try end(id, code: 200, reason: "OK") }

    private func end(_ id: CallID, code: Int, reason: String) throws {
        guard var info = callTable[id] else { throw EngineError.noSuchCall(id) }
        let duration = info.startedAt.map { Date().timeIntervalSince($0) } ?? 0
        info.state = .disconnected(code: code, reason: reason)
        callTable[id] = nil
        order.removeAll { $0 == id }
        emit(.callEnded(info, duration: duration))
    }

    func hangupAll() { for id in order { try? hangup(id) } }

    func setHold(_ id: CallID, _ on: Bool) throws {
        try change(id) { $0.isOnHold = on; if $0.state == .connected || $0.state == .held { $0.state = on ? .held : .connected } }
    }

    func setMute(_ id: CallID, _ on: Bool) throws { try change(id) { $0.isMuted = on } }

    func sendDTMF(_ id: CallID, _ digits: String) throws {
        guard callTable[id] != nil else { throw EngineError.noSuchCall(id) }
        emit(.log(level: 4, "mock DTMF \(digits)"))
    }

    func blindTransfer(_ id: CallID, to dial: DialString) throws {
        guard callTable[id] != nil else { throw EngineError.noSuchCall(id) }
        emit(.transferStatus(id, code: 202, final: false))
        Task {
            try? await Task.sleep(for: .milliseconds(600))
            self.emit(.transferStatus(id, code: 200, final: true))
            try? self.hangup(id)
        }
    }

    func attendedTransfer(_ id: CallID, replacing other: CallID) throws {
        guard callTable[id] != nil, callTable[other] != nil else { throw EngineError.noSuchCall(id) }
        emit(.transferStatus(id, code: 200, final: true))
        try hangup(id)
        try hangup(other)
    }

    func calls() -> [CallInfo] { order.compactMap { callTable[$0] } }

    // MARK: audio

    func audioDevices() -> [AudioDevice] { devices }
    func setAudioDevices(input: Int?, output: Int?) throws {}
    func setRingtoneDevice(_ id: Int?) {}
    func setRingtoneFile(_ url: URL?) {}

    func codecs() -> [CodecInfo] {
        codecOrder.enumerated().map { i, id in
            CodecInfo(id: id, priority: codecEnabled.contains(id) ? UInt8(max(1, 255 - i)) : 0)
        }
    }

    func setCodecPriorities(_ ordered: [String]) throws {
        guard !ordered.isEmpty else { throw EngineError.invalidArgument("no codec enabled") }
        codecEnabled = Set(ordered)
        codecOrder = ordered + AppSettings.defaultCodecOrder.filter { !ordered.contains($0) }
    }

    func silenceRingtone() {}

    func inputLevel() -> Float {
        level = max(0, min(1, level + Float.random(in: -0.3...0.3)))
        return level
    }
}
