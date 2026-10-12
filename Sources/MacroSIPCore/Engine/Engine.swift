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
    let caBundleURL: URL

    struct AccountEntry {
        var index: pjsua_acc_id
        var config: AccountConfig
        var password: String
        /// Last status given to `publishPresence` (re-applied when the account changes).
        var presence: PresenceStatus = .available
    }

    /// Conference connection (source slot -> sink slot) as last requested by the engine.
    struct Wire: Hashable {
        let src: pjsua_conf_port_id
        let sink: pjsua_conf_port_id
    }

    var isStarted = false
    var network = NetworkSettings.default
    var transports = TransportIDs()
    var accounts: [AccountID: AccountEntry] = [:]
    var requestedWiring: [Wire: Bool] = [:]
    /// Who owned each conference slot at the last `reconcileMedia` (call serial or recorder):
    /// requests for a slot whose owner changed are forgotten, PJSIP dropped them with the port.
    var slotOwners: [pjsua_conf_port_id: PortOwner] = [:]
    /// Active recordings by call (at most one per call).
    var recordings: [CallID: Recording] = [:]
    /// Next local conference id (`CallRecord.conference`).
    var nextConferenceID: UInt64 = 1
    /// Presence subscriptions by normalised URI.
    var buddies: [String: Buddy] = [:]
    /// Hold/resume requests that met a re-INVITE in flight (latest request per call wins);
    /// applied when the call's media or state changes, or by the retry timer.
    var pendingHolds: [CallID: PendingHold] = [:]
    var holdRetryScheduled = false

    // Audio devices are remembered by name (indices change when devices come and go).
    var inputDeviceName: String?
    var outputDeviceName: String?
    var ringtoneDeviceName: String?
    var appliedSoundDevices: (capture: Int32, playback: Int32)?

    var ringtoneSource: RingtoneSource = .tone(.ringtone)
    var ringtone: TonePlayer?
    /// Separate device the ringtone was opened on (nil = conference bridge).
    var ringtoneDevice: Int?
    var ringback: TonePlayer?
    /// Ringing calls the user silenced; a new incoming call rings again.
    var silencedCalls: Set<CallID> = []
    var deviceWatcher: AudioDeviceWatcher?
    let bridge = EngineBridge.shared

    /// - Parameters:
    ///   - logLevel: PJSIP log level 0...6 (3 = info). Logs go to os_log and `.log` events.
    ///   - nullAudio: use PJSIP's null sound device (tests, self-test: no microphone prompt).
    ///     Device selections are remembered but not applied.
    ///   - bindAddress: bind SIP and RTP to this local address and advertise it in Contact/SDP
    ///     (e.g. "127.0.0.1" for calls on this machine). nil = all interfaces, PJSIP picks
    ///     the default-route address (which may be a VPN tunnel).
    ///   - caBundleURL: where `start` writes the macOS system root certificates (PEM) that
    ///     the TLS transport verifies servers against. nil = Application Support/MacroSIP/ca-roots.pem.
    public init(logLevel: Int = 3, nullAudio: Bool = false, bindAddress: String? = nil,
                caBundleURL: URL? = nil) {
        self.logLevel = max(0, min(6, logLevel))
        self.nullAudio = nullAudio
        let addr = bindAddress?.trimmingCharacters(in: .whitespaces)
        self.bindAddress = (addr?.isEmpty ?? true) ? nil : addr
        self.caBundleURL = caBundleURL ?? TLSRoots.defaultURL
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
            transports = TransportIDs()
            bridge.detach(self)
            throw error
        }
        isStarted = true
        appliedSoundDevices = nil
        applySoundDevices()
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
        // Finalise the WAV files while the bridge still runs; the calls' `.callEnded` (held
        // back because they were recorded) is released after pjsua_destroy.
        for id in Array(recordings.keys) { finishRecorder(id) }
        // No presence events during shutdown: the subscriptions end with pjsua.
        bridge.unwatchAll()
        buddies = [:]
        pendingHolds = [:]
        pjsua_call_hangup_all()
        PJ.warn(pjsua_destroy(), "pjsua_destroy")
        bridge.releaseDeferredEnds()
        requestedWiring = [:]
        slotOwners = [:]
        isStarted = false
        transports = TransportIDs()
        appliedSoundDevices = nil
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
        ua.pointee.user_agent = arena.pj("MacroSIP/\(Product.version)")
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

        // RFC 3261 18.1.1: PJSIP puts TCP in front of UDP for a request above 1300 bytes
        // (an authorised INVITE with SDP easily is). Every account is bound to its own
        // transport, so for a UDP account that TCP attempt always fails with
        // PJSIP_ETPNOTSUITABLE ("will try next server") before the UDP copy goes out.
        // Keep the account's transport (docs/ENGINE.md, "Unsuitable transport").
        pjsip_cfg().pointee.endpt.disable_tcp_switch = 1
    }

    /// UDP is required; TCP and TLS failures are logged and only disable accounts of that kind.
    /// TLS exists twice: verifying (system roots + host name) and, for accounts that opted
    /// out with `verifyTLSCertificate == false`, non-verifying.
    private func createTransports(_ network: NetworkSettings) throws {
        var udp = PJ.invalidID
        try PJ.check(cpjsua_transport_create2(PJSIP_TRANSPORT_UDP, UInt32(network.localPort), bindAddress, &udp),
                     "UDP transport on port \(network.localPort)")
        transports.udp = udp

        var tcp = PJ.invalidID
        let tcpStatus = cpjsua_transport_create2(PJSIP_TRANSPORT_TCP, UInt32(network.localPort), bindAddress, &tcp)
        PJ.warn(tcpStatus, "TCP transport on port \(network.localPort)")
        if tcpStatus == PJ.success { transports.tcp = tcp }

        // A missing bundle leaves the verifying transport without CAs: it then rejects every
        // server (fails closed) instead of silently trusting them.
        var caFile: String?
        do {
            let count = try TLSRoots.export(to: caBundleURL)
            caFile = caBundleURL.path
            bridge.engineLogger.info("TLS: \(count) system root certificates in \(self.caBundleURL.path, privacy: .public)")
        } catch {
            let text = "TLS: cannot export system root certificates (\(error)); TLS servers will fail verification"
            bridge.engineLogger.error("\(text, privacy: .public)")
            emit(.log(level: 1, "engine: \(text)"))
        }
        var tls = PJ.invalidID
        let tlsStatus = cpjsua_tls_transport_create(0, bindAddress, 1, caFile, &tls)
        PJ.warn(tlsStatus, "TLS transport (verifying)")
        if tlsStatus == PJ.success { transports.tls = tls }

        var tlsNoVerify = PJ.invalidID
        let noVerifyStatus = cpjsua_tls_transport_create(0, bindAddress, 0, nil, &tlsNoVerify)
        PJ.warn(noVerifyStatus, "TLS transport (no certificate verification)")
        if noVerifyStatus == PJ.success { transports.tlsNoVerify = tlsNoVerify }
    }

    /// Local SIP port of a transport, 0 if unknown (diagnostics, CLI).
    public func localPort(of kind: TransportKind) -> Int {
        guard isStarted, let id = transports.id(for: kind) else { return 0 }
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
