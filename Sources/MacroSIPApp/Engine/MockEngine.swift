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
    private var recordings: [CallID: (files: RecordingFiles, since: Date)] = [:]
    private var presenceTasks: [String: Task<Void, Never>] = [:]
    private(set) var publishedPresence: [AccountID: PresenceStatus] = [:]

    private var devices = [
        AudioDevice(id: 0, name: "MacBook Pro Microphone", inputChannels: 1, outputChannels: 0),
        AudioDevice(id: 1, name: "MacBook Pro Speakers", inputChannels: 0, outputChannels: 2),
        AudioDevice(id: 2, name: "USB Headset", inputChannels: 1, outputChannels: 2),
    ]
    /// A headset the Debug menu and the demo states plug in and out.
    static let airPods = AudioDevice(id: 9, name: "AirPods Pro", inputChannels: 1, outputChannels: 2)
    /// What the app last asked for (nil = system default); the self-test reads these.
    private(set) var selectedInput: String?
    private(set) var selectedOutput: String?
    private(set) var ringtoneVolume: Float = 1
    private(set) var defaultVolume: (speaker: Float, microphone: Float) = (1, 1)
    private(set) var callVolumes: [CallID: (speaker: Float, microphone: Float)] = [:]
    private(set) var codecOptions = CodecOptions()
    private(set) var callOptions = CallOptions()
    private(set) var network = NetworkSettings.default      // what the engine runs with; `applyNetworkSettings` compares against it
    private(set) var dtmfSent: [String] = []
    /// Forces the quality of every call (demo states); nil = the time-based cycle.
    private var qualityOverride: QualityLevel?
    private var networkStatus: NetworkState = .online
    private var codecOrder = AppSettings.defaultCodecOrder
    private var codecEnabled = Set(AppSettings.defaultCodecOrder)
    /// What the app last asked for; the self-test reads these.
    private(set) var holdMusic: HoldMusic = .builtIn
    private(set) var recordingNotice: (enabled: Bool, intervalSeconds: Int) = (false, RecordingSettings.defaultNoticeInterval)
    private var voicemail: [AccountID: VoicemailState] = [:]
    /// Every `playEventSound` call, in order (`clearPlayedSounds` empties it).
    private(set) var playedSounds: [SoundEvent] = []
    /// Every `playTestTone` call: the device asked for and the length.
    private(set) var testTones: [(device: String?, seconds: Double)] = []
    private(set) var testTonePlaying = false
    private var testToneTask: Task<Void, Never>?

    init() {
        (events, continuation) = AsyncStream.makeStream(of: EngineEvent.self, bufferingPolicy: .unbounded)
    }

    deinit { continuation.finish() }

    private func emit(_ e: EngineEvent) { continuation.yield(e) }

    // MARK: lifecycle

    func start(network: NetworkSettings, codecPriorities: [String], codecOptions: CodecOptions, callOptions: CallOptions) throws {
        guard !started else { throw EngineError.alreadyStarted }
        started = true
        self.network = network
        self.codecOptions = codecOptions
        self.callOptions = callOptions
        try setCodecPriorities(codecPriorities)
    }

    func stop() {
        guard started else { return }
        hangupAll()
        for task in presenceTasks.values { task.cancel() }
        presenceTasks = [:]
        for id in accounts.keys { set(id, .unregistered) }
        accounts = [:]
        voicemail = [:]
        stopTestTone()
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
        voicemail[id] = nil
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
        callVolumes[id] = defaultVolume
        return id
    }

    private static func sampleName(for number: String) -> String? {
        ["100": "Reception", "101": DemoPeople.andrei, "102": DemoPeople.alesia][number]
    }

    /// Debug menu: an incoming call on `account` (first account when nil).
    func simulateIncoming(name: String?, number: String, account: AccountID? = nil) {
        guard let acct = account ?? accounts.keys.first else { return }
        let id = nextID()
        var info = CallInfo(
            id: id, accountID: acct, direction: .incoming, state: .incoming,
            remote: RemoteParty(displayName: name, uri: "sip:\(number)@mock.example.org", number: number),
            isSecure: false)
        // Like the real engine: single-call mode answers a new call with 486 at once while another one exists.
        // A call that only rings does not count; a connected, held or still dialling one does.
        let busy = callOptions.incomingWhileOnCall == .busy
            && callTable.values.contains { $0.state != .incoming && $0.isLive }
        // "Reject calls from" (call options): 603 Decline before anything rings, like the real engine.
        if denies(number: number) {
            info.state = .disconnected(code: 603, reason: "Decline")
            emit(.callEnded(info, duration: 0))
            return
        }
        // Do Not Disturb (call options): turned away before anything rings, like the real engine.
        guard callTable.count < 4, !busy, !callOptions.doNotDisturb else {
            // Like the real engine: a fifth call is answered with 486 and the UI never sees it ring.
            info.state = .disconnected(code: 486, reason: "Busy Here")
            emit(.callEnded(info, duration: 0))
            return
        }
        publish(info)
        emit(.incomingCall(info))
    }

    /// `CallOptions.denyIncoming` for a caller; an empty number is an anonymous caller.
    private func denies(number: String) -> Bool {
        switch callOptions.denyIncoming {
        case .nobody: return false
        case .everyone: return true
        case .anonymous: return number.isEmpty
        case .notInContacts: return number.isEmpty || !callOptions.knownNumbers.contains(Contact.normalize(number))
        }
    }

    func answer(_ id: CallID) throws {
        callVolumes[id] = defaultVolume
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
        callVolumes[id] = nil
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
        dtmfSent.append(digits)
        emit(.log(level: 4, "mock DTMF \(digits) (\(callOptions.dtmfMethod.rawValue))"))
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

    // MARK: network

    func networkState() -> NetworkState { networkStatus }
    func handleWake() {}
    func handleSleep() {}

    /// Offline: registered accounts start "reconnecting" and connected calls lose their media.
    /// Online again: accounts register after a second and the calls recover.
    func simulateNetwork(online: Bool) {
        networkStatus = online ? .online : .offline
        emit(.network(networkStatus))
        if online {
            for (id, cfg) in accounts where cfg.registers {
                if case .reconnecting = registration[id] ?? .unregistered { try? setRegistered(id, true) }
            }
            for id in order { try? change(id) { $0.isReconnecting = false } }
        } else {
            for (id, cfg) in accounts where cfg.registers { simulateAccountRetry(id, attempt: 1, nextRetryIn: 8) }
            for id in order where callTable[id]?.state == .connected { try? change(id) { $0.isReconnecting = true } }
        }
    }

    func simulateAccountRetry(_ id: AccountID, attempt: Int, nextRetryIn: TimeInterval, error: String = "408 Request Timeout") {
        set(id, .reconnecting(attempt: attempt, nextRetryIn: nextRetryIn, lastError: error))
    }

    /// The far end went silent for good: the call ends like the real engine's "connection lost".
    func simulateConnectionLost(_ id: CallID) throws { try end(id, code: 0, reason: Engine.connectionLostReason) }

    func simulateCallReconnecting(_ id: CallID, _ on: Bool) throws {
        try change(id) { $0.isReconnecting = on }
    }

    // MARK: quality and volume

    /// Demo states pin the level; otherwise a call is good for 8 s, fair for 8 s and poor for 14 s, over and over
    /// (so a screenshot series sees all three and the "poor for 6 s" banner).
    func setQualityOverride(_ level: QualityLevel?) { qualityOverride = level }

    func quality(of id: CallID) throws -> CallQuality {
        guard let call = callTable[id] else { throw EngineError.noSuchCall(id) }
        let level: QualityLevel
        if let qualityOverride { level = qualityOverride }
        else {
            let t = Date().timeIntervalSince(call.startedAt ?? Date()).truncatingRemainder(dividingBy: 30)
            level = t < 8 ? .good : (t < 16 ? .fair : .poor)
        }
        let wobble = Double.random(in: -0.1...0.1)
        switch level {
        case .good: return CallQuality(lossPercent: 0.5 + wobble, jitterMs: 12, rttMs: 48, mos: 4.3, level: .good)
        case .fair: return CallQuality(lossPercent: 2.5 + wobble, jitterMs: 38, rttMs: 140, mos: 3.7, level: .fair)
        case .poor: return CallQuality(lossPercent: 12, jitterMs: 85, rttMs: 310, mos: 2.4, level: .poor)
        }
    }

    func setCallVolume(_ id: CallID, speaker: Float, microphone: Float) throws {
        guard callTable[id] != nil else { throw EngineError.noSuchCall(id) }
        callVolumes[id] = (speaker, microphone)
    }

    func setDefaultCallVolume(speaker: Float, microphone: Float) { defaultVolume = (speaker, microphone) }

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

    /// Mono writes `wavURL`; stereo writes `<name>-local.wav` and `<name>-remote.wav` next to it
    /// (the real engine's one-channel files, converted into one stereo M4A later).
    func startRecording(_ id: CallID, to wavURL: URL, layout: RecordingLayout) throws {
        guard let c = callTable[id] else { throw EngineError.noSuchCall(id) }
        guard recordings[id] == nil else { throw EngineError.invalidArgument("call is already being recorded") }
        guard c.state == .connected || c.state == .held else { throw EngineError.invalidArgument("call is not connected") }
        try FileManager.default.createDirectory(at: wavURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let files = RecordingFiles.planned(for: wavURL, layout: layout)
        for url in files.all { try Self.sineWAV(seconds: 0.5).write(to: url) }
        recordings[id] = (files, Date())
        try change(id) { $0.isRecording = true }
    }

    /// Finishes the WAV files (a tone as long as the recording, 1...8 s) and returns them.
    func stopRecording(_ id: CallID) throws -> RecordingFiles {
        guard let rec = recordings.removeValue(forKey: id) else { throw EngineError.invalidArgument("call is not being recorded") }
        let seconds = min(8, max(1, Date().timeIntervalSince(rec.since)))
        for url in rec.files.all { try Self.sineWAV(seconds: seconds).write(to: url) }
        if callTable[id] != nil { try change(id) { $0.isRecording = false } }
        return rec.files
    }

    func recordingFiles(of id: CallID) -> RecordingFiles? { recordings[id]?.files }

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

    /// Watched users (the part before "@") whose status never changes; demo states use it for BLF dots.
    private(set) var pinnedPresence: [String: PresenceStatus] = [:]
    func pinPresence(user: String, _ status: PresenceStatus) {
        pinnedPresence[user] = status
        for uri in Array(presenceTasks.keys) where Self.userPart(ofURI: uri) == user { try? subscribePresence(uri: uri) }     // already watched: send the pinned status now
    }
    private static func userPart(ofURI uri: String) -> String {
        var s = uri.lowercased()
        for scheme in ["sips:", "sip:"] where s.hasPrefix(scheme) { s.removeFirst(scheme.count); break }
        return s.firstIndex(of: "@").map { String(s[..<$0]) } ?? s
    }

    /// First answer after 0.8 s; then the status flips between available and away every 6 s.
    func subscribePresence(uri: String) throws {
        guard started else { throw EngineError.notStarted }
        presenceTasks[uri]?.cancel()
        if let pinned = pinnedPresence[Self.userPart(ofURI: uri)] {
            presenceTasks[uri] = Task {
                try? await Task.sleep(for: .milliseconds(800))
                if !Task.isCancelled { self.emit(.buddyPresence(contactURI: uri, pinned)) }
            }
            return
        }
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
    func setAudioDevices(inputName: String?, outputName: String?) throws {
        selectedInput = inputName
        selectedOutput = outputName
    }
    func setRingtoneDevice(name: String?) {}
    func setRingtoneFile(_ url: URL?) {}
    func setRingtoneVolume(_ volume: Float) { ringtoneVolume = volume }

    /// The mock's devices: the headsets are USB / Bluetooth, "Loopback Audio" is a virtual device.
    func audioTransport(ofDeviceNamed name: String) -> AudioTransport {
        switch name {
        case "USB Headset": return .usb
        case "AirPods Pro": return .bluetooth
        case "Loopback Audio": return .virtual
        default: return .builtIn
        }
    }

    /// A virtual in/out device (audio routing software) appears or disappears.
    func simulateVirtualDevice(connected: Bool) {
        devices.removeAll { $0.id == 10 }
        if connected { devices.append(AudioDevice(id: 10, name: "Loopback Audio", inputChannels: 2, outputChannels: 2)) }
        emit(.audioDevicesChanged)
    }

    /// Plugs `AirPods Pro` in or out and announces it like the real device watcher does.
    func simulateHeadset(connected: Bool) {
        devices.removeAll { $0.id == Self.airPods.id }
        if connected { devices.append(Self.airPods) }
        emit(.audioDevicesChanged)
    }

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

    func setCodecOptions(_ options: CodecOptions) throws { codecOptions = options }
    func setCallOptions(_ options: CallOptions) { callOptions = options }

    /// Like the real engine: the port range, DNS, the SIP port and STUN need a restart; the rest applies at once.
    func applyNetworkSettings(_ settings: NetworkSettings) async throws -> NetworkApplyResult {
        let restart = settings.rtpPortStart != network.rtpPortStart || settings.rtpPortCount != network.rtpPortCount
            || settings.dnsSRV != network.dnsSRV || settings.nameserver != network.nameserver
            || settings.localPort != network.localPort || settings.stunServer != network.stunServer
        if !restart { network = settings }
        return restart ? .needsRestart : .applied
    }

    func silenceRingtone() {}

    // MARK: hold music, recording notice, voicemail, sounds

    /// Like the real engine: a file that cannot be read is refused and the previous source stays.
    func setHoldMusic(_ source: HoldMusic) async throws {
        if case let .file(url) = source, !FileManager.default.fileExists(atPath: url.path) {
            throw AudioFileToWAV.ConversionError.cannotRead(url.lastPathComponent)
        }
        holdMusic = source
        emit(.log(level: 4, "mock hold music \(source)"))
    }

    func setRecordingNotice(enabled: Bool, intervalSeconds: Int) {
        recordingNotice = (enabled, RecordingSettings.clampInterval(intervalSeconds))
    }

    func voicemailState(for id: AccountID) -> VoicemailState? { voicemail[id] }

    /// A message-summary NOTIFY for `account` (first account when nil): the event follows when the state changed.
    func simulateVoicemail(account: AccountID? = nil, new: Int, old: Int, waiting: Bool? = nil) {
        guard let acct = account ?? accounts.keys.first else { return }
        let state = VoicemailState(waiting: waiting ?? (new > 0), new: new, old: old)
        guard voicemail[acct] != state else { return }
        voicemail[acct] = state
        emit(.voicemail(acct, waiting: state.waiting, new: new, old: old))
    }

    func playTestTone(outputDevice: String?, seconds: Double) throws {
        guard started else { throw EngineError.notStarted }
        if let outputDevice, !devices.contains(where: { $0.name == outputDevice && $0.outputChannels > 0 }) {
            throw EngineError.invalidArgument("no output device named \(outputDevice)")
        }
        let length = min(max(seconds, 0.2), 30)
        testTones.append((outputDevice, length))
        testToneTask?.cancel()
        testTonePlaying = true
        testToneTask = Task {
            try? await Task.sleep(for: .seconds(length))
            if !Task.isCancelled { self.testTonePlaying = false }
        }
    }

    func stopTestTone() {
        testToneTask?.cancel()
        testToneTask = nil
        testTonePlaying = false
    }

    func playEventSound(_ event: SoundEvent) throws {
        guard started else { throw EngineError.notStarted }
        if case let .keyPress(digit) = event, !"0123456789*#ABCDabcd".contains(digit) {
            throw EngineError.invalidArgument("no DTMF tone for \(digit)")
        }
        playedSounds.append(event)
    }

    func clearPlayedSounds() { playedSounds = [] }

    func inputLevel() -> Float {
        level = max(0, min(1, level + Float.random(in: -0.3...0.3)))
        return level
    }
}
