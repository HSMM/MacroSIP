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
    /// Codecs built since 26.2, in the order the UI lists them after G.711. Not in
    /// `defaultCodecOrder`, so they are disabled (priority 0) until the user enables them.
    /// G.729 is not built.
    public static let optionalCodecs = [
        "G7221/16000/1", "G7221/32000/1",       // G.722.1 (Siren7), G.722.1C (Siren14)
        "GSM/8000/1", "iLBC/8000/1",
        "speex/8000/1", "speex/16000/1", "speex/32000/1",
    ]
    /// A fifth incoming call is rejected with 486; `makeCall` throws `.tooManyCalls`.
    public static let maxConcurrentCalls = 4
    /// Echo canceller tail (software canceller; VoiceProcessingIO ignores it).
    static let echoTailMs: UInt32 = 200

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
    /// false: no NWPathMonitor; the network counts as online from `start` and only paths
    /// injected by tests change it (tests, independent of the host's network).
    let monitorNetwork: Bool

    struct AccountEntry {
        var index: pjsua_acc_id
        var config: AccountConfig
        var password: String
        /// Last status given to `publishPresence` (re-applied when the account changes).
        var presence: PresenceStatus = .available
        /// Registration requested (cfg.registers or setRegistered): retried after temporary
        /// failures and network changes, paused while asleep.
        var wantsRegistration = false
    }

    /// Conference connection (source slot -> sink slot) as last requested by the engine.
    struct Wire: Hashable {
        let src: pjsua_conf_port_id
        let sink: pjsua_conf_port_id
    }

    var isStarted = false
    var network = NetworkSettings.default
    /// DNS servers of the SIP resolver since `start` (empty: SRV off, plain lookups).
    var dnsServers: [DNSServer] = []
    var transports = TransportIDs()
    var accounts: [AccountID: AccountEntry] = [:]
    var requestedWiring: [Wire: Bool] = [:]
    /// Level (0...2) last requested for each connection that is requested on (per-call speaker
    /// and microphone volume live on the call<->sound device connections).
    var requestedLevels: [Wire: Float] = [:]
    /// Who owned each conference slot at the last `reconcileMedia` (call serial or recorder):
    /// requests for a slot whose owner changed are forgotten, PJSIP dropped them with the port.
    var slotOwners: [pjsua_conf_port_id: PortOwner] = [:]
    /// Active recordings by call (at most one per call).
    var recordings: [CallID: Recording] = [:]
    /// File sets of recordings that ended with their call (`recordingFiles(of:)`), bounded.
    var finishedRecordings: [CallID: RecordingFiles] = [:]
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
    /// Audio processing for the selected devices (`audioProcessingMode()`), and whether the
    /// software echo canceller (`PJMEDIA_ECHO_USE_SW_ECHO`) is what pjsua opens the sound
    /// device with now (nil = not applied yet).
    var processingMode: AudioProcessingMode = .systemVoiceProcessing
    var appliedSoftwareEC: Bool?
    var processingModeAnnounced = false
    /// The sound device fell back to the null device after a failed reopen (calls silent).
    var soundOnNullFallback = false
    /// Device events (`audioDevicesEventArrived`) are handled once, this long after the last one.
    static let deviceEventDebounce: Duration = .milliseconds(400)
    var deviceEventGeneration: UInt64 = 0
    /// Tests: pretend these are the system default device names (nil = ask CoreAudio).
    var defaultDeviceNamesOverride: (input: String?, output: String?)?

    var ringtoneSource: RingtoneSource = .tone(.ringtone)
    var ringtone: TonePlayer?
    /// Separate device the ringtone was opened on (nil = conference bridge).
    var ringtoneDevice: Int?
    var ringback: TonePlayer?
    /// Ringing calls the user silenced; a new incoming call rings again.
    var silencedCalls: Set<CallID> = []
    var deviceWatcher: AudioDeviceWatcher?

    // Release 26.1 audio (Engine+Quality.swift).
    /// Per-call speaker/microphone gain (0...2), re-applied by `reconcileMedia`.
    var callVolumes: [CallID: CallVolume] = [:]
    /// Gain every new call starts with (`setDefaultCallVolume`).
    var defaultCallVolume = CallVolume()
    /// Ringtone gain 0...1, kept across ringtone start/stop.
    var ringtoneVolume: Float = 1
    /// Previous RTCP sample per call (`quality(of:)` reports the window since it).
    var qualitySamples: [CallID: QualitySample] = [:]
    var codecOptions = CodecOptions()

    // Release 26.1 call options (Engine+CallOptions.swift).
    var callOptions = CallOptions()
    /// Plays while an incoming call rings during a connected call (`.callWaiting`).
    var callWaitingTone: TonePlayer?
    /// Repeat period of the call-waiting tone (tests shorten it).
    var callWaitingPeriodMs = CallWaitingTone.periodMs
    /// In-band DTMF generators by call (`DTMFMethod.inband`).
    var dtmfGenerators: [CallID: TonePlayer] = [:]

    // Hold music, recording notice, UI sounds (Engine+HoldMusic, Engine+RecordingNotice, Engine+Sounds).
    var holdMusic: HoldMusic = .builtIn
    /// The WAV played for `HoldMusic.file` (the file itself, or its converted copy below).
    var holdMusicWAV: URL?
    var holdMusicTempWAV: URL?
    var holdMusicGeneration: UInt64 = 0
    /// One looping player per call on local hold, connected to that call's port only.
    var holdMusicPlayers: [CallID: TonePlayer] = [:]
    var recordingNotice = RecordingNoticeOptions()
    /// Tests: beep interval instead of the setting.
    var noticeIntervalOverride: Duration?
    /// Notice beep generators and timers by recording owner.
    var noticePlayers: [CallID: TonePlayer] = [:]
    var noticeTimers: [CallID: Task<Void, Never>] = [:]
    var testTone: TonePlayer?
    var testToneTask: Task<Void, Never>?
    /// Bumped by every `playTestTone`/`stopTestTone`, so the timer of a replaced tone cannot stop its successor.
    var testToneGeneration: UInt64 = 0
    /// Short UI sounds still playing (`playEventSound`), by token.
    var eventSounds: [UInt64: TonePlayer] = [:]
    var nextEventSoundID: UInt64 = 1

    // Network resilience (Engine+Network.swift).
    var networkStatus: NetworkState = .online
    /// `.network` was emitted since `start` (the first path evaluation).
    var networkAnnounced = false
    var pathMonitor: NetworkPathMonitor?
    /// Consumes `pathMonitor.paths` in order.
    var pathConsumer: Task<Void, Never>?
    /// Incremented for every monitor; updates from a cancelled one are ignored.
    var pathGeneration: UInt64 = 0
    var pathDebounce: Task<Void, Never>?
    var pendingPath: NetworkPath?
    /// The last path applied while online (the primary route the engine is set up for).
    var handledPath: NetworkPath?
    /// The last path applied at all (online or offline).
    var lastEvaluatedPath: NetworkPath?
    /// When the network last changed (offline/online, route change, wake, simulated change).
    var lastNetworkEvent: ContinuousClock.Instant?
    var sleeping = false
    /// handleWake ran; the next online path evaluation re-registers and re-INVITEs.
    var wakePending = false
    var ipChangeRound: UInt64 = 0
    /// The round pjsua is handling now; rounds never overlap.
    var ipChange: IPChange?
    var ipChangeTimer: Task<Void, Never>?
    /// A change that arrived while a round ran (the latest wins, flags merged).
    var queuedIPChange: IPChangeRequest?
    /// A change that waits for an outgoing call to stop ringing (pjsua would hang it up).
    var postponedIPChange: IPChangeRequest?
    /// 491/5xx retries of the engine's own re-INVITE in the current round, per call.
    var reinviteAttempts: [CallID: Int] = [:]
    /// Scheduled busy/491 re-INVITE retries (cancelled when a new round starts).
    var reinviteTasks: [CallID: Task<Void, Never>] = [:]
    /// When each call's pending re-INVITE was first wanted (gives up after 2 x the timeout).
    var reinviteSince: [CallID: ContinuousClock.Instant] = [:]
    /// keep_inv_after_tsx_timeout as last set by the engine.
    var keepInvApplied = false
    var registrationRetries: [AccountID: Task<Void, Never>] = [:]
    var mediaWatch: [CallID: MediaWatch] = [:]
    var watchdog: Task<Void, Never>?
    /// No RTP for this long: `isReconnecting` (right after a network change, or when RTCP is
    /// silent too).
    var mediaSilenceThreshold: TimeInterval = 3
    /// RTCP silence that, with RTP silence, counts as reconnecting without a network event
    /// (RTCP reports come every ~5 s).
    var rtcpSilenceThreshold: TimeInterval = 12
    /// A network event this recent makes RTP silence alone count as reconnecting.
    var networkEventWindow: TimeInterval = 30
    /// No RTP and no RTCP for this long while online (after RTCP was seen): the dialog is
    /// probed with OPTIONS and the call ends on 408/481 ("connection lost").
    var connectionLostTimeout: TimeInterval = 60
    /// Tests: SIP transaction timeout (Timer B/F) in ms instead of PJSIP's 32 s.
    var transactionTimeoutOverrideMs: UInt32?
    /// PJSIP's compiled-in transaction timeout (PJSIP_TD_TIMEOUT), independent of overrides.
    static let defaultTransactionTimeoutMs: UInt32 = UInt32(cpjsua_default_tsx_timeout())
    var transactionTimeoutMs: UInt32 { transactionTimeoutOverrideMs ?? Engine.defaultTransactionTimeoutMs }

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
    ///   - monitorNetwork: watch the network path (NWPathMonitor). false: the network counts as
    ///     online and never changes by itself (tests and tools that must not depend on the
    ///     host's network).
    public init(logLevel: Int = 3, nullAudio: Bool = false, bindAddress: String? = nil,
                caBundleURL: URL? = nil, monitorNetwork: Bool = true) {
        self.monitorNetwork = monitorNetwork
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

    /// `codecOptions` are applied to the Opus codec's defaults right after the codec
    /// priorities (they stay in effect across `stop`/`start` only when passed again).
    /// `callOptions` replace whatever `setCallOptions` set before.
    public func start(network: NetworkSettings = .default,
                      codecPriorities: [String] = Engine.defaultCodecOrder,
                      codecOptions: CodecOptions = CodecOptions(),
                      callOptions: CallOptions = CallOptions()) throws {
        guard !isStarted else { throw EngineError.alreadyStarted }
        try bridge.attach(self, sink: continuation)
        self.callOptions = callOptions
        bridge.setCallOptions(callOptions.withNormalizedKnownNumbers())
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
            cpjsua_set_tsx_timeout(transactionTimeoutMs)
            try applyCodecPriorities(codecPriorities)
            self.codecOptions = codecOptions
            applyCodecOptionsAtStart()
        } catch {
            if created { PJ.warn(pjsua_destroy(), "pjsua_destroy after failed start") }
            transports = TransportIDs()
            bridge.detach(self)
            throw error
        }
        isStarted = true
        appliedSoundDevices = nil
        // initPJSUA opened nothing and set ec_options without USE_SW_ECHO (VoiceProcessingIO).
        appliedSoftwareEC = network.echoCancellation ? false : nil
        processingModeAnnounced = false
        soundOnNullFallback = false
        applySoundDevices()
        deviceWatcher = AudioDeviceWatcher { [weak self] in
            Task { await self?.audioDevicesEventArrived() }
        }
        startNetworkMonitoring()
    }

    /// The 26.0 signature (`SIPEngine` conformance): call options are the defaults.
    public func start(network: NetworkSettings = .default,
                      codecPriorities: [String] = Engine.defaultCodecOrder,
                      codecOptions: CodecOptions = CodecOptions()) throws {
        try start(network: network, codecPriorities: codecPriorities, codecOptions: codecOptions,
                  callOptions: CallOptions())
    }

    /// Hangs up every call, unregisters, destroys pjsua. Emits `.unregistered` for each account.
    public func stop() {
        guard isStarted else { return }
        PJ.registerThread()
        stopNetworkMonitoring()
        deviceWatcher?.invalidate()
        deviceWatcher = nil
        stopRingtone()
        stopRingback()
        stopCallWaitingTone()
        stopAllDTMFGenerators()
        stopAllHoldMusic()
        stopAllRecordingNotices()
        stopTestTone()
        stopAllEventSounds()
        silencedCalls = []
        // Finalise the WAV files while the bridge still runs; the calls' `.callEnded` (held
        // back because they were recorded) is released after pjsua_destroy.
        for id in Array(recordings.keys) { finishRecorder(id, keepFiles: true) }
        // No presence events during shutdown: the subscriptions end with pjsua.
        bridge.unwatchAll()
        buddies = [:]
        pendingHolds = [:]
        pjsua_call_hangup_all()
        PJ.warn(pjsua_destroy(), "pjsua_destroy")
        if transactionTimeoutOverrideMs != nil { cpjsua_set_tsx_timeout(Engine.defaultTransactionTimeoutMs) }
        cpjsua_set_keep_inv_after_tsx_timeout(0)     // pjsua's timer that would clear it is gone
        keepInvApplied = false
        bridge.releaseDeferredEnds()
        requestedWiring = [:]
        requestedLevels = [:]
        slotOwners = [:]
        callVolumes = [:]
        qualitySamples = [:]
        isStarted = false
        transports = TransportIDs()
        appliedSoundDevices = nil
        appliedSoftwareEC = nil
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
        // DNS SRV (NetworkSettings.dnsSRV): a nameserver makes pjsua create the SIP resolver;
        // registrar and proxy hosts without a port are then looked up as _sip._udp/_sip._tcp/
        // _sips._tcp SRV records first. Ports other than 53 are set after pjsua_init.
        dnsServers = DNSServers.forSettings(network)
        if network.dnsSRV && dnsServers.isEmpty {
            emit(.log(level: 2, "engine: DNS SRV is on but no DNS server is known; using plain address lookups"))
        }
        let nameservers = dnsServers.prefix(DNSServers.maxCount).map { arena.pj($0.host) }
        ua.pointee.nameserver_count = UInt32(nameservers.count)
        withUnsafeMutableBytes(of: &ua.pointee.nameserver) { raw in
            let slots = raw.bindMemory(to: pj_str_t.self)
            for (i, str) in nameservers.enumerated() where i < slots.count { slots[i] = str }
        }
        installPJCallbacks(&ua.pointee.cb)

        pjsua_logging_config_default(log)
        log.pointee.level = UInt32(logLevel)
        log.pointee.console_level = UInt32(logLevel)
        log.pointee.msg_logging = 1
        log.pointee.cb = pjLogWriter

        pjsua_media_config_default(media)
        media.pointee.ec_tail_len = network.echoCancellation ? Engine.echoTailMs : 0
        // No PJMEDIA_ECHO_USE_SW_ECHO: CoreAudio devices advertise echo cancellation, so pjsua
        // opens VoiceProcessingIO. `applySoundDevices` switches to the WebRTC canceller when a
        // non-default device is selected (docs/ENGINE.md, "Voice processing").
        media.pointee.ec_options = UInt32(PJMEDIA_ECHO_WEBRTC.rawValue)
        media.pointee.enable_ice = network.useICE ? 1 : 0
        media.pointee.no_vad = 1   // VAD clips speech and stops RTP on silence

        try withExtendedLifetime(arena) {
            try PJ.check(pjsua_init(ua, log, media), "pjsua_init")
        }
        if dnsServers.contains(where: { $0.port != 53 }) { applyNameservers(dnsServers) }
        if !dnsServers.isEmpty {
            emit(.log(level: 3, "engine: DNS SRV via \(dnsServers.map(\.description).joined(separator: ", "))"))
        }
        // rport (RFC 3581) in Via: a pjsip endpoint setting read for every request, global and
        // kept across pjsua_destroy, so it is set on every start.
        pjsip_cfg().pointee.endpt.disable_rport = network.useRport ? 0 : 1

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
