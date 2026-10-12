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
    private var recordings: [CallID: (url: URL, since: Date)] = [:]
    private var presenceTasks: [String: Task<Void, Never>] = [:]
    private(set) var publishedPresence: [AccountID: PresenceStatus] = [:]

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
        for task in presenceTasks.values { task.cancel() }
        presenceTasks = [:]
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
        if cfg.registers { try setRegistered(cfg.id, true) }
    }

    func updateAccount(_ cfg: AccountConfig, password: String?) throws {
        guard started else { throw EngineError.notStarted }
        guard accounts[cfg.id] != nil else { throw EngineError.unknownAccount(cfg.id) }
        accounts[cfg.id] = cfg
        if let password { passwords[cfg.id] = password }
        if cfg.registers { try setRegistered(cfg.id, true) } else { try setRegistered(cfg.id, false) }
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
        guard let acct = account ?? accounts.keys.first else { return }
        let id = nextID()
        var info = CallInfo(
            id: id, accountID: acct, direction: .incoming, state: .incoming,
            remote: RemoteParty(displayName: name, uri: "sip:\(number)@mock.example.org", number: number),
            isSecure: false)
        guard callTable.count < 4 else {
            // Like the real engine: a fifth call is answered with 486 and the UI never sees it ring.
            info.state = .disconnected(code: 486, reason: "Busy Here")
            emit(.callEnded(info, duration: 0))
            return
        }
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
        if recordings[id] != nil { _ = try? stopRecording(id) }     // like the real engine: the file is complete when the call ends
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

    // MARK: conference

    func merge(_ ids: [CallID]) throws {
        guard ids.count >= 2 else { throw EngineError.invalidArgument("a conference needs at least two calls") }
        for id in ids {
            guard let c = callTable[id] else { throw EngineError.noSuchCall(id) }
            guard c.state == .connected || c.state == .held else { throw EngineError.invalidArgument("call is not connected") }
        }
        for id in ids {
            try change(id) { $0.inConference = true; $0.isOnHold = false; $0.state = .connected }
        }
    }

    /// The leg leaves the conference (the real engine does not hold it; the app does).
    /// A conference that is left with one leg dissolves.
    func split(_ id: CallID) throws {
        guard let c = callTable[id] else { throw EngineError.noSuchCall(id) }
        guard c.inConference else { throw EngineError.invalidArgument("call is not in a conference") }
        try change(id) { $0.inConference = false }
        let rest = order.filter { callTable[$0]?.inConference == true }
        if rest.count == 1, let last = rest.first { try change(last) { $0.inConference = false } }
    }

    // MARK: recording

    func startRecording(_ id: CallID, to wavURL: URL) throws {
        guard let c = callTable[id] else { throw EngineError.noSuchCall(id) }
        guard recordings[id] == nil else { throw EngineError.invalidArgument("call is already being recorded") }
        guard c.state == .connected || c.state == .held else { throw EngineError.invalidArgument("call is not connected") }
        try FileManager.default.createDirectory(at: wavURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.sineWAV(seconds: 0.5).write(to: wavURL)
        recordings[id] = (wavURL, Date())
        try change(id) { $0.isRecording = true }
    }

    /// Finishes the WAV (a tone as long as the recording, 1...8 s) and returns its URL.
    func stopRecording(_ id: CallID) throws -> URL {
        guard let rec = recordings.removeValue(forKey: id) else { throw EngineError.invalidArgument("call is not being recorded") }
        let seconds = min(8, max(1, Date().timeIntervalSince(rec.since)))
        try Self.sineWAV(seconds: seconds).write(to: rec.url)
        if callTable[id] != nil { try change(id) { $0.isRecording = false } }
        return rec.url
    }

    /// 16-bit mono 16 kHz PCM WAV with a quiet 440 Hz tone.
    static func sineWAV(seconds: Double, rate: Int = 16_000) -> Data {
        let count = Int(seconds * Double(rate))
        var pcm = Data(capacity: count * 2)
        for i in 0..<count {
            let v = Int16(3_000 * sin(2 * Double.pi * 440 * Double(i) / Double(rate)))
            withUnsafeBytes(of: v.littleEndian) { pcm.append(contentsOf: $0) }
        }
        func le32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        func le16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        var d = Data("RIFF".utf8)
        d += le32(UInt32(36 + pcm.count)) + Data("WAVEfmt ".utf8) + le32(16) + le16(1) + le16(1)
        d += le32(UInt32(rate)) + le32(UInt32(rate * 2)) + le16(2) + le16(16)
        d += Data("data".utf8) + le32(UInt32(pcm.count)) + pcm
        return d
    }

    // MARK: presence

    /// First answer after 0.8 s; then the status flips between available and away every 6 s.
    func subscribePresence(uri: String) throws {
        guard started else { throw EngineError.notStarted }
        presenceTasks[uri]?.cancel()
        var status: PresenceStatus = uri.utf8.reduce(0, { $0 &+ Int($1) }) % 2 == 0 ? .available : .away
        presenceTasks[uri] = Task {
            try? await Task.sleep(for: .milliseconds(800))
            while !Task.isCancelled {
                self.emit(.buddyPresence(contactURI: uri, status))
                status = status == .available ? .away : .available
                try? await Task.sleep(for: .seconds(6))
            }
        }
    }

    func unsubscribePresence(uri: String) throws {
        presenceTasks.removeValue(forKey: uri)?.cancel()
    }

    func publishPresence(_ status: PresenceStatus, for account: AccountID) throws {
        guard accounts[account] != nil else { throw EngineError.unknownAccount(account) }
        publishedPresence[account] = status
        emit(.log(level: 4, "mock publish presence \(status.rawValue)"))
    }

    // MARK: audio

    func audioDevices() -> [AudioDevice] { devices }
    func setAudioDevices(inputName: String?, outputName: String?) throws {}
    func setRingtoneDevice(name: String?) {}
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
