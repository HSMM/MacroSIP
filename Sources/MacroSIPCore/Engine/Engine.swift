internal import CPJSUA
import Foundation

/// The only code that talks to PJSIP. Owns the single pjsua instance of the process.
///
/// Threading (docs/ENGINE.md):
/// - The actor's executor is a dedicated serial `DispatchSerialQueue` ("macrosip.engine").
///   GCD may run that queue on different worker threads, so every entry point registers
///   the current thread with pjlib first (`cpjsua_thread_register`, a no-op after the first
///   time on each thread). All `pjsua_*` mutations happen inside the actor.
/// - PJSIP callbacks run on PJSIP threads. They read call/registration data, yield an
///   `EngineEvent` into `events` and schedule follow-up work on the actor asynchronously
///   (see EngineBridge.swift). They never call into the actor synchronously.
///
/// Lifecycle: `init` -> `start` -> (accounts, calls...) -> `stop`. One started Engine per
/// process; `start` throws `.alreadyStarted` otherwise. A stopped Engine can be started again.
public actor Engine {
    /// "first = highest"; names not compiled into PJSIP are ignored.
    public static let defaultCodecOrder = ["opus/48000/2", "G722/16000/1", "PCMU/8000/1", "PCMA/8000/1"]
    /// A fifth incoming call is rejected with 486; `makeCall` throws `.tooManyCalls`.
    public static let maxConcurrentCalls = 4

    /// Every engine event. Single consumer: iterate it from exactly one task.
    public nonisolated let events: AsyncStream<EngineEvent>
    private nonisolated let continuation: AsyncStream<EngineEvent>.Continuation
    private nonisolated let queue: DispatchSerialQueue

    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        queue.asUnownedSerialExecutor()
    }

    let logLevel: Int
    let nullAudio: Bool
    let bindAddress: String?

    struct AccountEntry {
        var index: pjsua_acc_id
        var config: AccountConfig
        var password: String
    }

    var isStarted = false
    var network = NetworkSettings.default
    var transports: [TransportKind: pjsua_transport_id] = [:]
    var accounts: [AccountID: AccountEntry] = [:]
    var ringtoneSource: RingtoneSource = .tone(.ringtone)
    var ringtoneDeviceID: Int?
    var ringtone: TonePlayer?
    var ringback: TonePlayer?
    /// Ringing calls the user silenced; a new incoming call rings again.
    var silencedCalls: Set<CallID> = []
    var deviceWatcher: AudioDeviceWatcher?
    let bridge = EngineBridge.shared

    /// - Parameters:
    ///   - logLevel: PJSIP log level 0...6 (3 = info). Logs go to os_log and `.log` events.
    ///   - nullAudio: use PJSIP's null sound device (tests, self-test: no microphone prompt).
    ///   - bindAddress: bind SIP and RTP to this local address and advertise it in Contact/SDP
    ///     (e.g. "127.0.0.1" for calls on this machine). nil = all interfaces, PJSIP picks
    ///     the default-route address (which may be a VPN tunnel).
    public init(logLevel: Int = 3, nullAudio: Bool = false, bindAddress: String? = nil) {
        self.logLevel = max(0, min(6, logLevel))
        self.nullAudio = nullAudio
        let addr = bindAddress?.trimmingCharacters(in: .whitespaces)
        self.bindAddress = (addr?.isEmpty ?? true) ? nil : addr
        self.queue = DispatchSerialQueue(label: "macrosip.engine", qos: .userInitiated)
        (events, continuation) = AsyncStream.makeStream(of: EngineEvent.self, bufferingPolicy: .unbounded)
    }

    deinit {
        continuation.finish()
    }

    // MARK: - Lifecycle

    public func start(network: NetworkSettings = .default,
                      codecPriorities: [String] = Engine.defaultCodecOrder) throws {
        guard !isStarted else { throw EngineError.alreadyStarted }
        try bridge.attach(self, sink: continuation)
        var created = false
        do {
            // Route PJSIP logging before pjsua_create so nothing is printed to stdout.
            pj_log_set_log_func(pjLogWriter)
            pj_log_set_level(Int32(logLevel))

            try PJ.check(pjsua_create(), "pjsua_create")
            created = true
            PJ.registerThread()
            self.network = network
            try initPJSUA(network)
            if nullAudio {
                try PJ.check(pjsua_set_null_snd_dev(), "pjsua_set_null_snd_dev")
            }
            try createTransports(network)
            try PJ.check(pjsua_start(), "pjsua_start")
            try applyCodecPriorities(codecPriorities)
        } catch {
            if created { PJ.warn(pjsua_destroy(), "pjsua_destroy after failed start") }
            transports = [:]
            bridge.detach(self)
            throw error
        }
        isStarted = true
        deviceWatcher = AudioDeviceWatcher { [weak self] in
            Task { await self?.handleAudioDevicesChanged() }
        }
    }

    /// Hangs up every call, unregisters, destroys pjsua. Emits `.unregistered` for each account.
    public func stop() {
        guard isStarted else { return }
        PJ.registerThread()
        deviceWatcher?.invalidate()
        deviceWatcher = nil
        stopRingtone()
        stopRingback()
        silencedCalls = []
        pjsua_call_hangup_all()
        PJ.warn(pjsua_destroy(), "pjsua_destroy")
        isStarted = false
        transports = [:]
        let ids = Array(accounts.keys)
        accounts = [:]
        bridge.detach(self)
        for id in ids { emit(.registration(id, .unregistered)) }
    }

    private func initPJSUA(_ network: NetworkSettings) throws {
        let arena = CStringArena()
        let ua = UnsafeMutablePointer<pjsua_config>.allocate(capacity: 1)
        let log = UnsafeMutablePointer<pjsua_logging_config>.allocate(capacity: 1)
        let media = UnsafeMutablePointer<pjsua_media_config>.allocate(capacity: 1)
        ua.initialize(to: pjsua_config())
        log.initialize(to: pjsua_logging_config())
        media.initialize(to: pjsua_media_config())
        defer {
            ua.deinitialize(count: 1); ua.deallocate()
            log.deinitialize(count: 1); log.deallocate()
            media.deinitialize(count: 1); media.deallocate()
        }

        pjsua_config_default(ua)
        ua.pointee.thread_cnt = 1
        // Room above the 4-call policy for calls pjsua creates itself (REFER, Replaces).
        ua.pointee.max_calls = UInt32(PJSUA_MAX_CALLS)
        ua.pointee.user_agent = arena.pj("\(Edition.current.productName.replacingOccurrences(of: " ", with: "-"))/0.1")
        if let stun = network.stunServer?.trimmingCharacters(in: .whitespaces), !stun.isEmpty {
            ua.pointee.stun_srv_cnt = 1
            ua.pointee.stun_srv.0 = arena.pj(stun)
        }
        installPJCallbacks(&ua.pointee.cb)

        pjsua_logging_config_default(log)
        log.pointee.level = UInt32(logLevel)
        log.pointee.console_level = UInt32(logLevel)
        log.pointee.msg_logging = 1
        log.pointee.cb = pjLogWriter

        pjsua_media_config_default(media)
        media.pointee.ec_tail_len = network.echoCancellation ? 200 : 0   // ms
        media.pointee.ec_options = UInt32(PJMEDIA_ECHO_WEBRTC.rawValue)
        media.pointee.enable_ice = network.useICE ? 1 : 0
        media.pointee.no_vad = 1   // VAD clips speech and stops RTP on silence

        try withExtendedLifetime(arena) {
            try PJ.check(pjsua_init(ua, log, media), "pjsua_init")
        }
    }

    /// UDP is required; TCP and TLS failures are logged and only disable accounts of that kind.
    private func createTransports(_ network: NetworkSettings) throws {
        func make(_ type: pjsip_transport_type_e, _ port: UInt16) -> (pjsua_transport_id, pj_status_t) {
            var id = PJ.invalidID
            let status = cpjsua_transport_create2(type, UInt32(port), bindAddress, &id)
            return (id, status)
        }
        let (udp, udpStatus) = make(PJSIP_TRANSPORT_UDP, network.localPort)
        try PJ.check(udpStatus, "UDP transport on port \(network.localPort)")
        transports[.udp] = udp

        let (tcp, tcpStatus) = make(PJSIP_TRANSPORT_TCP, network.localPort)
        if tcpStatus == PJ.success {
            transports[.tcp] = tcp
        } else {
            bridge.engineLogger.error("TCP transport: \(PJ.errorText(tcpStatus), privacy: .public)")
        }
        // Client-side TLS needs no certificate; listen on a random port.
        let (tls, tlsStatus) = make(PJSIP_TRANSPORT_TLS, 0)
        if tlsStatus == PJ.success {
            transports[.tls] = tls
        } else {
            bridge.engineLogger.error("TLS transport: \(PJ.errorText(tlsStatus), privacy: .public)")
        }
    }

    /// Local SIP port of a transport, 0 if unknown (diagnostics, CLI).
    public func localPort(of kind: TransportKind) -> Int {
        guard isStarted, let id = transports[kind] else { return 0 }
        PJ.registerThread()
        return Int(cpjsua_transport_port(id))
    }

    // MARK: - Helpers

    func emit(_ event: EngineEvent) {
        continuation.yield(event)
    }

    /// Throws unless started; registers the current queue thread with pjlib.
    func requireStarted() throws {
        guard isStarted, PJ.registerThread() else { throw EngineError.notStarted }
    }
}

// MARK: - Accounts

extension Engine {
    public func addAccount(_ cfg: AccountConfig, password: String) throws {
        try requireStarted()
        guard accounts[cfg.id] == nil else {
            throw EngineError.invalidArgument("account \(cfg.id.raw) is already added")
        }
        let settings = try AccountMapping.settings(for: cfg, password: password,
                                                   network: network, transports: transports,
                                                   bindAddress: bindAddress)
        var index = PJ.invalidID
        try AccountMapping.withPJConfig(settings) { p in
            // Never register inside pjsua_acc_add: the callbacks need the index mapping first.
            p.pointee.register_on_acc_add = 0
            try PJ.check(pjsua_acc_add(p, cfg.isDefaultOutgoing ? 1 : 0, &index), "pjsua_acc_add")
        }
        accounts[cfg.id] = AccountEntry(index: index, config: cfg, password: password)
        bridge.setAccount(index, cfg.id)
        bridge.setRegistration(cfg.id, .unregistered, force: true)
        if cfg.enabled {
            try setRegistered(cfg.id, true)
        }
    }

    /// `password == nil` keeps the current one. Re-registers when `cfg.enabled`.
    public func updateAccount(_ cfg: AccountConfig, password: String?) throws {
        try requireStarted()
        guard var entry = accounts[cfg.id] else { throw EngineError.unknownAccount(cfg.id) }
        let pw = password ?? entry.password
        let settings = try AccountMapping.settings(for: cfg, password: pw,
                                                   network: network, transports: transports,
                                                   bindAddress: bindAddress)
        let wasActive = bridge.registration(of: cfg.id) != .unregistered
        if !cfg.enabled && wasActive {
            try setRegistered(cfg.id, false)
        }
        try AccountMapping.withPJConfig(settings) { p in
            // We decide about (re-)registration below, not pjsua_acc_modify.
            p.pointee.disable_reg_on_modify = 1
            try PJ.check(pjsua_acc_modify(entry.index, p), "pjsua_acc_modify")
        }
        if cfg.isDefaultOutgoing {
            PJ.warn(pjsua_acc_set_default(entry.index), "set default account")
        }
        entry.config = cfg
        entry.password = pw
        accounts[cfg.id] = entry
        if cfg.enabled {
            try setRegistered(cfg.id, true)
        }
    }

    /// Hangs up the account's calls, unregisters and deletes it.
    public func removeAccount(_ id: AccountID) throws {
        try requireStarted()
        guard let entry = accounts[id] else { throw EngineError.unknownAccount(id) }
        for slot in CallSnapshot.allSlots() {
            if let snap = CallSnapshot.read(slot), snap.accIndex == entry.index, snap.state != .disconnected {
                PJ.warn(pjsua_call_hangup(slot, 0, nil, nil), "hang up call \(slot) of removed account")
            }
        }
        try PJ.check(pjsua_acc_del(entry.index), "pjsua_acc_del")
        accounts[id] = nil
        bridge.setAccount(entry.index, nil)
    }

    public func setRegistered(_ id: AccountID, _ on: Bool) throws {
        try requireStarted()
        guard let entry = accounts[id] else { throw EngineError.unknownAccount(id) }
        if !on && bridge.registration(of: id) == .unregistered { return }
        let status = pjsua_acc_set_registration(entry.index, on ? 1 : 0)
        guard status == PJ.success else {
            let err = PJ.error(status, on ? "register" : "unregister")
            if on {
                bridge.setRegistration(id, .failed(code: 0, reason: PJ.errorText(status)))
            }
            throw err
        }
        if !on {
            // The un-REGISTER result arrives via on_reg_state2; show the intent right away.
            bridge.setRegistration(id, .unregistered)
        }
    }

    public func registrationState(of id: AccountID) -> RegistrationState {
        bridge.registration(of: id)
    }
}

// MARK: - Calls

extension Engine {
    public func makeCall(to dial: DialString, from account: AccountID) throws -> CallID {
        try requireStarted()
        guard let entry = accounts[account] else { throw EngineError.unknownAccount(account) }
        guard Int(cpjsua_active_call_count()) < Engine.maxConcurrentCalls else {
            throw EngineError.tooManyCalls(limit: Engine.maxConcurrentCalls)
        }
        let serial = bridge.allocateSerial()
        var slot = PJ.invalidID
        try PJ.check(cpjsua_call_make(entry.index, dial.uri, serial, &slot), "call \(dial.uri)")
        return CallID(raw: slot, serial: serial)
    }

    public func answer(_ id: CallID) throws {
        let slot = try liveSlot(id)
        try PJ.check(cpjsua_call_answer(slot, 200), "answer")
        reconcileTones()
    }

    public func reject(_ id: CallID, code: Int = 486) throws {
        guard (300...699).contains(code) else { throw EngineError.invalidArgument("reject code \(code)") }
        let slot = try liveSlot(id)
        try PJ.check(pjsua_call_hangup(slot, UInt32(code), nil, nil), "reject")
        reconcileTones()
    }

    public func hangup(_ id: CallID) throws {
        let slot = try liveSlot(id)
        try PJ.check(pjsua_call_hangup(slot, 0, nil, nil), "hangup")
        reconcileTones()
    }

    public func hangupAll() {
        guard isStarted, PJ.registerThread() else { return }
        pjsua_call_hangup_all()
        reconcileTones()
    }

    /// Local hold (re-INVITE sendonly) or resume (re-INVITE with PJSUA_CALL_UNHOLD).
    /// Holding one call does not resume another; the UI decides.
    public func setHold(_ id: CallID, _ on: Bool) throws {
        let slot = try liveSlot(id)
        if on {
            try PJ.check(pjsua_call_set_hold2(slot, 0, nil), "hold")
        } else {
            try PJ.check(cpjsua_call_unhold(slot), "unhold")
        }
        try updateRecord(slot) { $0.localHold = on }
    }

    /// Disconnects (or reconnects) the microphone from the call's conference port.
    public func setMute(_ id: CallID, _ on: Bool) throws {
        let slot = try liveSlot(id)
        try updateRecord(slot) { $0.isMuted = on }
    }

    /// RFC 2833 telephone-events; SIP INFO when the remote did not offer telephone-event.
    public func sendDTMF(_ id: CallID, _ digits: String) throws {
        let allowed = Set("0123456789*#ABCDabcd")
        guard !digits.isEmpty, digits.allSatisfy({ allowed.contains($0) }) else {
            throw EngineError.invalidArgument("DTMF digits \"\(digits)\"")
        }
        let slot = try liveSlot(id)
        var usedInfo: Int32 = 0
        try PJ.check(cpjsua_call_send_dtmf(slot, digits, &usedInfo), "DTMF")
        if usedInfo != 0 {
            bridge.engineLogger.info("call \(slot): DTMF sent with SIP INFO (no RFC 2833 at remote)")
        }
    }

    public func blindTransfer(_ id: CallID, to dial: DialString) throws {
        let slot = try liveSlot(id)
        let arena = CStringArena()
        var dest = arena.pj(dial.uri)
        try withExtendedLifetime(arena) {
            try PJ.check(pjsua_call_xfer(slot, &dest, nil), "transfer to \(dial.uri)")
        }
    }

    /// REFER with Replaces: the party on `id` is connected to the party on `other`.
    public func attendedTransfer(_ id: CallID, replacing other: CallID) throws {
        let slot = try liveSlot(id)
        let otherSlot = try liveSlot(other)
        try PJ.check(pjsua_call_xfer_replaces(slot, otherSlot, UInt32(PJSUA_XFER_NO_REQUIRE_REPLACES), nil),
                     "attended transfer")
    }

    /// Every live call (disconnected ones excluded), in pjsua slot order (not by age).
    public func calls() -> [CallInfo] {
        guard isStarted, PJ.registerThread() else { return [] }
        return CallSnapshot.allSlots().compactMap { slot in
            guard let snap = CallSnapshot.read(slot), snap.state != .disconnected else { return nil }
            return bridge.callInfo(snap).0
        }
    }

    /// RTP counters of the call's audio stream.
    public func mediaStats(_ id: CallID) throws -> CallMediaStats {
        let slot = try liveSlot(id)
        var st = cpjsua_rtp_stat()
        try PJ.check(cpjsua_call_rtp_stat(slot, &st), "stream statistics")
        return CallMediaStats(
            rxPackets: Int(st.rx_packets),
            txPackets: Int(st.tx_packets),
            rxLost: Int(st.rx_lost),
            rxJitterMs: Double(st.rx_jitter_usec_mean) / 1000,
            rttMs: Double(st.rtt_usec_mean) / 1000
        )
    }

    // MARK: internals

    /// Validates that `id` still names the same live call and returns its pjsua slot.
    func liveSlot(_ id: CallID) throws -> pjsua_call_id {
        try requireStarted()
        guard id.raw >= 0, id.raw < Int32(pjsua_call_get_max_count()),
              pjsua_call_is_active(id.raw) != 0,
              let snap = CallSnapshot.read(id.raw),
              (bridge.record(id.raw)?.serial ?? snap.serial) == id.serial
        else { throw EngineError.noSuchCall(id) }
        return id.raw
    }

    private func updateRecord(_ slot: pjsua_call_id, _ change: @escaping @Sendable (inout CallRecord) -> Void) throws {
        guard let snap = CallSnapshot.read(slot) else {
            throw EngineError.noSuchCall(CallID(raw: slot, serial: 0))
        }
        let (info, record) = bridge.callInfo(snap, mutate: change)
        reconcileMedia(slot)
        if record.announced { emit(.callChanged(info)) }
    }

    /// Wires the call's conference port: remote -> speaker always while media flows,
    /// microphone -> remote unless muted. Idempotent; runs after every media change.
    func reconcileMedia(_ slot: pjsua_call_id) {
        guard isStarted, PJ.registerThread(),
              let snap = CallSnapshot.read(slot), snap.confSlot != PJ.invalidID else { return }
        let muted = bridge.record(slot)?.isMuted ?? false
        let port = snap.confSlot
        switch snap.mediaStatus {
        case .active, .remoteHold:
            connect(port, 0, true)
            connect(0, port, !muted)
        case .localHold, .none, .error:
            connect(port, 0, false)
            connect(0, port, false)
        }
    }

    private func connect(_ src: pjsua_conf_port_id, _ sink: pjsua_conf_port_id, _ on: Bool) {
        let isConnected = cpjsua_conf_is_connected(src, sink) != 0
        guard isConnected != on else { return }
        let status = on ? pjsua_conf_connect(src, sink) : pjsua_conf_disconnect(src, sink)
        if status != PJ.success {
            bridge.engineLogger.error("conf \(on ? "connect" : "disconnect") \(src)->\(sink): \(PJ.errorText(status), privacy: .public)")
        }
    }

    // Follow-up work scheduled by the callbacks (asynchronously, see EngineBridge).

    func handleCallStateChanged() {
        reconcileTones()
    }

    func handleMediaStateChanged(_ slot: pjsua_call_id) {
        reconcileMedia(slot)
        reconcileTones()
    }

    func handleTransferSucceeded(_ id: CallID) {
        guard let slot = try? liveSlot(id) else { return }
        PJ.warn(pjsua_call_hangup(slot, 0, nil, nil), "hang up transferred call \(slot)")
    }
}

// MARK: - Ringtone and ringback

extension Engine {
    /// Ringtone while an incoming call rings; ringback while an outgoing call got 180/182
    /// without early media. Idempotent; runs after every call state change.
    func reconcileTones() {
        guard isStarted, PJ.registerThread() else { return }
        var ringingCalls: Set<CallID> = []
        var ringbackNeeded = false
        for slot in CallSnapshot.allSlots() {
            guard let s = CallSnapshot.read(slot) else { continue }
            if !s.isOutgoing && (s.state == .incoming || s.state == .early) {
                ringingCalls.insert(CallID(raw: slot, serial: bridge.record(slot)?.serial ?? s.serial))
            }
            if s.isOutgoing && s.state == .early && (s.lastStatus == 180 || s.lastStatus == 182)
                && s.mediaStatus != .active {
                ringbackNeeded = true
            }
        }
        silencedCalls.formIntersection(ringingCalls)
        ringingCalls.isSubset(of: silencedCalls) ? stopRingtone() : startRingtone()
        ringbackNeeded ? startRingback() : stopRingback()
    }

    /// Stops the ringtone; the calls keep ringing (180) until answered or rejected.
    /// A call that starts ringing later plays the ringtone again.
    public func silenceRingtone() {
        guard isStarted, PJ.registerThread() else { return }
        for slot in CallSnapshot.allSlots() {
            guard let s = CallSnapshot.read(slot), !s.isOutgoing,
                  s.state == .incoming || s.state == .early else { continue }
            silencedCalls.insert(CallID(raw: slot, serial: bridge.record(slot)?.serial ?? s.serial))
        }
        stopRingtone()
    }

    private func startRingtone() {
        guard ringtone == nil else { return }
        do {
            ringtone = try TonePlayer(name: "ringtone", source: ringtoneSource,
                                      deviceID: separateRingtoneDevice())
        } catch {
            bridge.engineLogger.error("ringtone: \(String(describing: error), privacy: .public)")
            // A missing/broken WAV or device must not leave the call silent.
            if ringtoneSource != .tone(.ringtone) || ringtoneDeviceID != nil {
                ringtone = try? TonePlayer(name: "ringtone", source: .tone(.ringtone), deviceID: nil)
            }
        }
    }

    func stopRingtone() {
        ringtone?.stop()
        ringtone = nil
    }

    private func startRingback() {
        guard ringback == nil else { return }
        do {
            ringback = try TonePlayer(name: "ringback", source: .tone(.ringback), deviceID: nil)
        } catch {
            bridge.engineLogger.error("ringback: \(String(describing: error), privacy: .public)")
        }
    }

    func stopRingback() {
        ringback?.stop()
        ringback = nil
    }

    /// The ringtone device when it differs from the call output, else nil (conference bridge).
    private func separateRingtoneDevice() -> Int? {
        guard let dev = ringtoneDeviceID, !nullAudio else { return nil }
        var capture: Int32 = 0
        var playback: Int32 = 0
        guard pjsua_get_snd_dev(&capture, &playback) == PJ.success else { return dev }
        if playback >= 0, Int(playback) == dev { return nil }
        return dev
    }
}

// MARK: - Audio devices and codecs

extension Engine {
    public func audioDevices() -> [AudioDevice] {
        guard isStarted, PJ.registerThread() else { return [] }
        var entries = [cpjsua_aud_dev_entry](repeating: cpjsua_aud_dev_entry(), count: 64)
        var count = UInt32(entries.count)
        let status = entries.withUnsafeMutableBufferPointer { p -> pj_status_t in
            guard let base = p.baseAddress else { return -1 }
            return cpjsua_aud_devs(base, &count)
        }
        guard status == PJ.success else { return [] }
        return entries.prefix(Int(count)).map {
            AudioDevice(id: Int($0.id), name: PJ.string(tuple: $0.name),
                        inputChannels: Int($0.input_count), outputChannels: Int($0.output_count))
        }
    }

    /// nil = system default. Devices open on demand (no immediate microphone access).
    public func setAudioDevices(input: Int?, output: Int?) throws {
        try requireStarted()
        let capture = input.map(Int32.init) ?? PJMEDIA_AUD_DEFAULT_CAPTURE_DEV
        let playback = output.map(Int32.init) ?? PJMEDIA_AUD_DEFAULT_PLAYBACK_DEV
        try PJ.check(cpjsua_set_snd_devs(capture, playback), "select audio devices")
    }

    /// nil = ring on the call output device.
    public func setRingtoneDevice(_ id: Int?) {
        ringtoneDeviceID = id
        restartRingtoneIfPlaying()
    }

    /// nil = the generated tone. Hook for the bundled ringtone WAV.
    public func setRingtoneFile(_ url: URL?) {
        ringtoneSource = url.map { .wavFile($0) } ?? .tone(.ringtone)
        restartRingtoneIfPlaying()
    }

    private func restartRingtoneIfPlaying() {
        guard ringtone != nil else { return }
        stopRingtone()
        reconcileTones()
    }

    /// All codecs, highest priority first. Priority 0 = disabled.
    public func codecs() -> [CodecInfo] {
        guard isStarted, PJ.registerThread() else { return [] }
        return (try? codecList()) ?? []
    }

    /// Listed codecs get descending priorities (first = highest); unlisted codecs are
    /// disabled; unknown names are ignored. If no listed name is known, nothing changes.
    /// An empty list restores `defaultCodecOrder`.
    public func setCodecPriorities(_ ordered: [String]) throws {
        try requireStarted()
        try applyCodecPriorities(ordered)
    }

    func codecList() throws -> [CodecInfo] {
        var entries = [cpjsua_codec_entry](repeating: cpjsua_codec_entry(), count: 32)
        var count = UInt32(entries.count)
        let status = entries.withUnsafeMutableBufferPointer { p -> pj_status_t in
            guard let base = p.baseAddress else { return -1 }
            return cpjsua_codecs(base, &count)
        }
        try PJ.check(status, "pjsua_enum_codecs")
        return entries.prefix(Int(count))
            .map { CodecInfo(id: PJ.string(tuple: $0.id), priority: UInt8(clamping: $0.priority)) }
            .sorted { $0.priority > $1.priority }
    }

    func applyCodecPriorities(_ requested: [String]) throws {
        let ordered = requested.isEmpty ? Engine.defaultCodecOrder : requested
        let available = try codecList().map(\.id)
        let plan = CodecMapping.plan(requested: ordered, available: available)
        guard plan.contains(where: { $0.priority > 0 }) else {
            bridge.engineLogger.error("codec list \(ordered, privacy: .public) has no known codec; unchanged")
            return
        }
        let arena = CStringArena()
        try withExtendedLifetime(arena) {
            for item in plan {
                var id = arena.pj(item.id)
                try PJ.check(pjsua_codec_set_priority(&id, item.priority), "codec priority \(item.id)")
            }
        }
    }

    /// Microphone level 0...1 as seen by the conference bridge (slot 0). The sound device
    /// opens on demand, so this is 0 unless a call (or tone) keeps the device open.
    public func inputLevel() -> Float {
        guard isStarted, PJ.registerThread() else { return 0 }
        var tx: UInt32 = 0
        var rx: UInt32 = 0
        guard pjsua_conf_get_signal_level(0, &tx, &rx) == PJ.success else { return 0 }
        return Float(min(rx, 255)) / 255
    }

    func handleAudioDevicesChanged() {
        guard isStarted, PJ.registerThread() else { return }
        let status = pjmedia_aud_dev_refresh()
        if status != PJ.success {
            bridge.engineLogger.error("audio device refresh: \(PJ.errorText(status), privacy: .public)")
        }
        emit(.audioDevicesChanged)
    }
}

#if FULL
// Full-edition API: stubs only until Lite ships (owner's rule, 2026-10-10).
extension Engine {
    public func merge(_ ids: [CallID]) throws { throw EngineError.unsupported("merge") }
    public func split(_ id: CallID) throws { throw EngineError.unsupported("split") }
    public func startRecording(_ id: CallID, to wavURL: URL) throws { throw EngineError.unsupported("recording") }
    public func stopRecording(_ id: CallID) throws -> URL { throw EngineError.unsupported("recording") }
    public func subscribePresence(uri: String) throws { throw EngineError.unsupported("presence") }
    public func unsubscribePresence(uri: String) throws { throw EngineError.unsupported("presence") }
    public func publishPresence(_ status: PresenceStatus, for account: AccountID) throws {
        throw EngineError.unsupported("presence")
    }
}
#endif
