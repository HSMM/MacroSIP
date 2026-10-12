import Foundation
import MacroSIPCore

@MainActor
final class Interactive {
    let engine: Engine
    var accounts: [(name: String, config: AccountConfig)] = []
    var currentAccount: AccountConfig?
    var calls: [CallID: CallInfo] = [:]
    var currentCall: CallID?

    init(engine: Engine) {
        self.engine = engine
    }

    static func run(_ options: Options) async {
        let engine = Engine(logLevel: options.logLevel ?? 3, nullAudio: options.nullAudio,
                            bindAddress: options.bind)
        let cli = Interactive(engine: engine)
        let events = Task { @MainActor in
            for await e in engine.events {
                cli.apply(e)
                printEvent(e)
            }
        }
        do {
            try await engine.start(
                network: NetworkSettings(stunServer: options.stun, localPort: options.port),
                codecPriorities: Engine.defaultCodecOrder)
        } catch {
            print("start failed: \(error)")
            exit(1)
        }
        print("macrosip-cli ready. SIP UDP port \(await engine.localPort(of: .udp)), " +
              "TCP \(await engine.localPort(of: .tcp)), TLS \(await engine.localPort(of: .tls)). Type 'help'.")
        for await line in Interactive.stdinLines() {
            let words = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard let cmd = words.first else { continue }
            if cmd == "quit" || cmd == "exit" { break }
            do {
                try await cli.handle(cmd, Array(words.dropFirst()))
            } catch {
                print("error: \(error)")
            }
        }
        await engine.stop()
        events.cancel()
        print("bye")
    }

    /// Reads stdin on its own thread so the main actor keeps printing events.
    nonisolated static func stdinLines() -> AsyncStream<String> {
        AsyncStream { continuation in
            let thread = Thread {
                while let line = readLine() { continuation.yield(line) }
                continuation.finish()
            }
            thread.start()
        }
    }

    func apply(_ e: EngineEvent) {
        switch e {
        case let .incomingCall(c):
            calls[c.id] = c
            currentCall = c.id
            print(">>> incoming call from \(c.remote.uri) - type 'answer' or 'hangup'")
        case let .callChanged(c):
            calls[c.id] = c
            if currentCall == nil { currentCall = c.id }
        case let .callEnded(c, _):
            calls[c.id] = nil
            if currentCall == c.id { currentCall = calls.keys.first }
        default:
            break
        }
    }

    func call() throws -> CallID {
        if let id = currentCall, calls[id] != nil { return id }
        guard let id = calls.keys.first else { throw CLIError("no call") }
        return id
    }

    func account() async throws -> AccountConfig {
        if let a = currentAccount { return a }
        // Convenience for direct IP calls: a local, never-registered account.
        let local = AccountConfig(displayName: "local", username: "macrosip", domain: "127.0.0.1",
                                  enabled: false, isDefaultOutgoing: true)
        try await engine.addAccount(local, password: "")
        accounts.append(("local", local))
        currentAccount = local
        print("(using local account sip:macrosip@127.0.0.1 for direct calls)")
        return local
    }

    func handle(_ cmd: String, _ args: [String]) async throws {
        switch cmd {
        case "help":
            print("""
            acc add <name> <user> <domain> <password> [udp|tcp|tls] [disabled|optional|mandatory] [noverify]
                                            add account (not registered); SRTP mode; noverify = no TLS cert check
            acc list | acc use <name> | acc del <name> | acc publish on|off
            reg | unreg                     register / unregister the current account
            call <dial>                     number, user@host or sip: URI
            answer | reject [code] | hangup [all]
            hold | unhold | mute | unmute
            dtmf <digits>                   RFC 2833, SIP INFO fallback
            xfer <dial>                     blind transfer of the current call
            axfer                           attended transfer: current call -> other call
            use <slot>                      make call in slot current
            merge | split                   conference of all connected calls / take current call out
            rec <file.wav> | stoprec        record the current call (WAV)
            sub <uri> | unsub <uri>         watch / stop watching a contact's presence
            status available|away|dnd|offline   publish presence (account needs publishing on)
            acc publish on|off              PUBLISH presence for the current account
            calls | stats | devs | setdev <in|-> <out|-> | ringdev <id|->
            codecs [id ...]                 list, or set priority order
            quit
            """)
        case "acc":
            try await handleAccount(args)
        case "reg", "unreg":
            let a = try await account()
            try await engine.setRegistered(a.id, cmd == "reg")
        case "call":
            guard let raw = args.first else { throw CLIError("call <dial>") }
            let a = try await account()
            guard let dial = DialString.parse(raw, account: a) else { throw CLIError("cannot parse \(raw)") }
            let id = try await engine.makeCall(to: dial, from: a.id)
            currentCall = id
            print("calling \(dial.uri) as \(id)")
        case "answer":
            let ringing = calls.values.first { $0.state == .incoming }?.id
            let id = try ringing ?? call()
            try await engine.answer(id)
            currentCall = id
        case "reject":
            try await engine.reject(try call(), code: args.first.flatMap(Int.init) ?? 486)
        case "hangup":
            if args.first == "all" { await engine.hangupAll() } else { try await engine.hangup(try call()) }
        case "hold", "unhold":
            try await engine.setHold(try call(), cmd == "hold")
        case "mute", "unmute":
            try await engine.setMute(try call(), cmd == "mute")
        case "dtmf":
            guard let digits = args.first else { throw CLIError("dtmf <digits>") }
            try await engine.sendDTMF(try call(), digits)
        case "xfer":
            guard let raw = args.first else { throw CLIError("xfer <dial>") }
            let a = try await account()
            guard let dial = DialString.parse(raw, account: a) else { throw CLIError("cannot parse \(raw)") }
            try await engine.blindTransfer(try call(), to: dial)
        case "axfer":
            let id = try call()
            guard let other = calls.keys.first(where: { $0 != id }) else { throw CLIError("need a second call") }
            try await engine.attendedTransfer(id, replacing: other)
        case "use":
            guard let slot = args.first.flatMap(Int32.init),
                  let id = calls.keys.first(where: { $0.raw == slot }) else { throw CLIError("use <slot>") }
            currentCall = id
        case "merge":
            let ids = await engine.calls().filter { $0.state == .connected || $0.state == .held }.map(\.id)
            try await engine.merge(ids)
        case "split":
            try await engine.split(try call())
        case "rec":
            guard let path = args.first else { throw CLIError("rec <file.wav>") }
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            try await engine.startRecording(try call(), to: url)
            print("recording \(try call()) to \(url.path)")
        case "stoprec":
            print("recorded \(try await engine.stopRecording(try call()).path)")
        case "sub", "unsub":
            guard let uri = args.first else { throw CLIError("\(cmd) <uri>") }
            if cmd == "sub" { try await engine.subscribePresence(uri: uri) } else { try await engine.unsubscribePresence(uri: uri) }
        case "status":
            guard let raw = args.first, let status = PresenceStatus(rawValue: raw) else {
                throw CLIError("status available|away|dnd|offline")
            }
            try await engine.publishPresence(status, for: try await account().id)
        case "calls":
            let list = await engine.calls()
            if list.isEmpty { print("no calls") }
            for c in list { print("\(c.id == currentCall ? "*" : " ") \(describe(c))") }
        case "stats":
            let s = try await engine.mediaStats(try call())
            print("rx \(s.rxPackets) pkts (lost \(s.rxLost), jitter \(s.rxJitterMs) ms), tx \(s.txPackets) pkts, rtt \(s.rttMs) ms")
        case "devs":
            for d in await engine.audioDevices() {
                print("[\(d.id)] \(d.name)  in \(d.inputChannels) out \(d.outputChannels)")
            }
        case "setdev":
            guard args.count == 2 else { throw CLIError("setdev <in|-> <out|->") }
            try await engine.setAudioDevices(input: Int(args[0]), output: Int(args[1]))
        case "ringdev":
            await engine.setRingtoneDevice(args.first.flatMap(Int.init))
        case "codecs":
            if !args.isEmpty { try await engine.setCodecPriorities(args) }
            for c in await engine.codecs() { print("\(c.id.padding(toLength: 16, withPad: " ", startingAt: 0)) \(c.priority)") }
        default:
            print("unknown command '\(cmd)'; try 'help'")
        }
    }

    func handleAccount(_ args: [String]) async throws {
        switch args.first {
        case "add":
            let verify = !args.contains("noverify")
            let args = args.filter { $0 != "noverify" }
            guard args.count >= 5 else {
                throw CLIError("acc add <name> <user> <domain> <password> [udp|tcp|tls] [disabled|optional|mandatory] [noverify]")
            }
            let transport = args.count > 5 ? TransportKind(rawValue: args[5].lowercased()) : .udp
            guard let transport else { throw CLIError("transport must be udp, tcp or tls") }
            let srtp = args.count > 6 ? SRTPMode(rawValue: args[6].lowercased()) : .disabled
            guard let srtp else { throw CLIError("SRTP must be disabled, optional or mandatory") }
            let cfg = AccountConfig(displayName: args[1], username: args[2], domain: args[3],
                                    transport: transport, srtp: srtp, enabled: false,
                                    isDefaultOutgoing: accounts.isEmpty, verifyTLSCertificate: verify)
            try await engine.addAccount(cfg, password: args[4])
            accounts.append((args[1], cfg))
            currentAccount = cfg
            print("account \(args[1]) added (\(cfg.uri), \(transport.rawValue), SRTP \(srtp.rawValue)); 'reg' to register")
        case "use":
            guard args.count == 2, let a = accounts.first(where: { $0.name == args[1] }) else { throw CLIError("acc use <name>") }
            currentAccount = a.config
        case "publish":
            guard args.count == 2, ["on", "off"].contains(args[1]), var cfg = currentAccount,
                  let i = accounts.firstIndex(where: { $0.config.id == cfg.id }) else {
                throw CLIError("acc publish on|off (current account)")
            }
            cfg.publishPresence = args[1] == "on"
            // updateAccount unregisters a disabled account; keep a registered one registered
            // (the re-REGISTER also starts the PUBLISH session).
            if case .registered = await engine.registrationState(of: cfg.id) { cfg.enabled = true }
            try await engine.updateAccount(cfg, password: nil)
            accounts[i].config = cfg
            currentAccount = cfg
        case "del":
            guard args.count == 2, let i = accounts.firstIndex(where: { $0.name == args[1] }) else { throw CLIError("acc del <name>") }
            try await engine.removeAccount(accounts[i].config.id)
            if currentAccount?.id == accounts[i].config.id { currentAccount = nil }
            accounts.remove(at: i)
        default:
            for a in accounts {
                let st = await engine.registrationState(of: a.config.id)
                print("\(a.config.id == currentAccount?.id ? "*" : " ") \(a.name)  \(a.config.uri) \(a.config.transport.rawValue)  \(describe(st))")
            }
        }
    }
}

struct CLIError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}
