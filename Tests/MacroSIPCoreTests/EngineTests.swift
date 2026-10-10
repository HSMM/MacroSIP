import Foundation
import Testing
@testable import MacroSIPCore

/// Tests that create pjsua (one instance per process) or read its global defaults.
/// `.serialized` keeps them from overlapping with each other.
@Suite("Engine (pjsua)", .serialized)
struct EngineTests {
    static let network = NetworkSettings(stunServer: nil, localPort: 0, keepAliveSeconds: 15,
                                         useICE: false, echoCancellation: true)

    @Test func startAddDisabledAccountListCodecsDevicesStop() async throws {
        let engine = Engine(logLevel: 1, nullAudio: true, bindAddress: "127.0.0.1")
        try await engine.start(network: Self.network, codecPriorities: Engine.defaultCodecOrder)

        let account = AccountConfig(displayName: "Test", username: "1001", domain: "127.0.0.1", enabled: false)
        try await engine.addAccount(account, password: "secret")
        #expect(await engine.registrationState(of: account.id) == .unregistered)

        let codecs = await engine.codecs()
        #expect(codecs.map(\.id) == Engine.defaultCodecOrder)
        #expect(codecs.map(\.priority) == [254, 253, 252, 251])

        let devices = await engine.audioDevices()
        #expect(devices.allSatisfy { !$0.name.isEmpty && ($0.inputChannels > 0 || $0.outputChannels > 0) })
        #expect(await engine.calls().isEmpty)
        #expect(await engine.localPort(of: .udp) > 0)

        // Adding the same account twice is refused; unknown accounts are reported.
        await #expect(throws: EngineError.self) { try await engine.addAccount(account, password: "x") }
        let stranger = AccountID()
        await #expect(throws: EngineError.unknownAccount(stranger)) {
            try await engine.setRegistered(stranger, true)
        }

        try await engine.removeAccount(account.id)
        await engine.stop()
        #expect(await engine.codecs().isEmpty)
        await #expect(throws: EngineError.notStarted) {
            try await engine.addAccount(account, password: "secret")
        }
    }

    @Test func codecPrioritiesFollowOrderAndIgnoreUnknownNames() async throws {
        let engine = Engine(logLevel: 1, nullAudio: true, bindAddress: "127.0.0.1")
        try await engine.start(network: Self.network, codecPriorities: ["PCMA/8000/1", "bogus/8000/1", "pcmu"])
        var codecs = await engine.codecs()
        #expect(codecs.prefix(2).map(\.id) == ["PCMA/8000/1", "PCMU/8000/1"])
        #expect(codecs.prefix(2).map(\.priority) == [254, 253])
        #expect(codecs.dropFirst(2).allSatisfy { $0.priority == 0 })   // unlisted = disabled

        try await engine.setCodecPriorities(["nothing-known"])          // ignored entirely
        #expect(await engine.codecs() == codecs)

        try await engine.setCodecPriorities([])                         // back to the default order
        codecs = await engine.codecs()
        #expect(codecs.map(\.id) == Engine.defaultCodecOrder)
        await engine.stop()
    }

    @Test func onlyOneStartedEngineAndRestart() async throws {
        let a = Engine(logLevel: 1, nullAudio: true, bindAddress: "127.0.0.1")
        let b = Engine(logLevel: 1, nullAudio: true, bindAddress: "127.0.0.1")
        try await a.start(network: Self.network)
        await #expect(throws: EngineError.alreadyStarted) { try await b.start(network: Self.network) }
        await a.stop()
        try await b.start(network: Self.network)        // pjsua can be created again
        #expect(await b.codecs().count == 4)
        await b.stop()
        try await a.start(network: Self.network)
        await a.stop()
    }

    @Test func callAPIRejectsStaleOrUnknownCalls() async throws {
        let engine = Engine(logLevel: 1, nullAudio: true, bindAddress: "127.0.0.1")
        try await engine.start(network: Self.network)
        let ghost = CallID(raw: 0, serial: 999)
        await #expect(throws: EngineError.noSuchCall(ghost)) { try await engine.hangup(ghost) }
        await #expect(throws: EngineError.self) { try await engine.sendDTMF(ghost, "12x") }
        let account = AccountConfig(displayName: "T", username: "u", domain: "127.0.0.1", enabled: false)
        try await engine.addAccount(account, password: "")
        let dial = try #require(DialString.parse("100", account: account))
        await #expect(throws: EngineError.unknownAccount(AccountID.unknown)) {
            _ = try await engine.makeCall(to: dial, from: .unknown)
        }
        await engine.stop()
    }

    // MARK: pjsua_acc_config mapping

    struct MappingCase: Sendable, CustomTestStringConvertible {
        let account: AccountConfig
        let expectedRegURI: String
        let expectedTransportID: Int32
        let expectedSecureSignaling: Int
        let expectedProxies: [String]
        let expectedAuthUser: String
        var testDescription: String { "\(account.transport.rawValue)/\(account.srtp.rawValue)" }
    }

    static let transportIDs: [TransportKind: Int32] = [.udp: 0, .tcp: 1, .tls: 2]

    static let mappingCases: [MappingCase] = [
        MappingCase(
            account: AccountConfig(displayName: "U", username: "1001", domain: "sip.example.com",
                                   transport: .udp, srtp: .disabled),
            expectedRegURI: "sip:sip.example.com", expectedTransportID: 0,
            expectedSecureSignaling: 0, expectedProxies: [], expectedAuthUser: "1001"),
        MappingCase(
            account: AccountConfig(displayName: "T", username: "1002", domain: "sip.example.com",
                                   registrar: "reg.example.com", outboundProxy: "proxy.example.com:5060",
                                   authID: "auth-1002", transport: .tcp, srtp: .optional,
                                   registrationInterval: 600),
            expectedRegURI: "sip:reg.example.com;transport=tcp", expectedTransportID: 1,
            expectedSecureSignaling: 0, expectedProxies: ["sip:proxy.example.com:5060;transport=tcp;lr"],
            expectedAuthUser: "auth-1002"),
        MappingCase(
            account: AccountConfig(displayName: "S", username: "1003", domain: "sip.example.com",
                                   outboundProxy: "sip:edge.example.com:5061;transport=tls;lr",
                                   transport: .tls, srtp: .mandatory),
            expectedRegURI: "sip:sip.example.com;transport=tls", expectedTransportID: 2,
            expectedSecureSignaling: 1, expectedProxies: ["sip:edge.example.com:5061;transport=tls;lr"],
            expectedAuthUser: "1003"),
        MappingCase(
            account: AccountConfig(displayName: "M", username: "1004", domain: "sip.example.com",
                                   authID: "", transport: .udp, srtp: .mandatory),
            expectedRegURI: "sip:sip.example.com", expectedTransportID: 0,
            expectedSecureSignaling: 0, expectedProxies: [], expectedAuthUser: "1004"),
        MappingCase(
            account: AccountConfig(displayName: "O", username: "1005", domain: "sip.example.com",
                                   transport: .tls, srtp: .optional),
            expectedRegURI: "sip:sip.example.com;transport=tls", expectedTransportID: 2,
            expectedSecureSignaling: 0, expectedProxies: [], expectedAuthUser: "1005"),
    ]

    @Test(arguments: mappingCases)
    func accountConfigMapping(_ c: MappingCase) throws {
        let network = NetworkSettings(stunServer: nil, keepAliveSeconds: 25, useICE: true)
        let s = try AccountMapping.settings(for: c.account, password: "pw", network: network,
                                            transports: Self.transportIDs)
        #expect(s.idURI == "sip:\(c.account.username)@sip.example.com")
        #expect(s.regURI == c.expectedRegURI)
        #expect(s.authRealm == "*")
        #expect(s.authScheme == "digest")
        #expect(s.authUsername == c.expectedAuthUser)
        #expect(s.password == "pw")
        #expect(s.regTimeout == c.account.registrationInterval)
        #expect(s.proxies == c.expectedProxies)
        #expect(s.srtp == c.account.srtp)
        #expect(s.srtpSecureSignaling == c.expectedSecureSignaling)
        #expect(s.transportID == c.expectedTransportID)
        #expect(s.allowContactRewrite && s.allowViaRewrite)
        #expect(s.keepAliveSeconds == 25)
        #expect(s.iceEnabled)
        #expect(s.bindAddress == nil)

        // What actually lands in pjsua_acc_config reads back identically.
        let back = AccountMapping.withPJConfig(s) { AccountMapping.readBack($0) }
        #expect(back == s)
    }

    @Test func mappingFailsWithoutTransportAndKeepsBindAddress() throws {
        let tls = AccountConfig(displayName: "S", username: "1", domain: "d", transport: .tls)
        #expect(throws: EngineError.transportUnavailable(.tls)) {
            _ = try AccountMapping.settings(for: tls, password: "", network: .default, transports: [.udp: 0])
        }
        let udp = AccountConfig(displayName: "U", username: "1", domain: "127.0.0.1")
        let s = try AccountMapping.settings(for: udp, password: "", network: .default,
                                            transports: [.udp: 0], bindAddress: "127.0.0.1")
        let back = AccountMapping.withPJConfig(s) { AccountMapping.readBack($0) }
        #expect(back.bindAddress == "127.0.0.1")
        #expect(back.rtpPortRange > 0 && back.randomizeRTPPort)
    }
}

/// Pure Swift parts of the engine (no pjsua).
@Suite("Engine helpers")
struct EngineHelperTests {
    @Test func proxyURINormalisation() {
        #expect(AccountMapping.proxyURI("proxy.example.com", transport: .udp) == "sip:proxy.example.com;lr")
        #expect(AccountMapping.proxyURI("sip:p.example.com;lr", transport: .udp) == "sip:p.example.com;lr")
        #expect(AccountMapping.proxyURI("p.example.com:5061", transport: .tls) == "sip:p.example.com:5061;transport=tls;lr")
        #expect(AccountMapping.proxyURI("sips:p.example.com;transport=tls", transport: .tls) == "sips:p.example.com;transport=tls;lr")
    }

    @Test func codecPlan() {
        let available = ["PCMU/8000/1", "PCMA/8000/1", "G722/16000/1", "opus/48000/2"]
        let plan = CodecMapping.plan(requested: ["opus/48000/2", "speex/8000/1", "g722", "opus/48000/2"],
                                     available: available)
        #expect(plan.map(\.id) == ["opus/48000/2", "G722/16000/1", "PCMU/8000/1", "PCMA/8000/1"])
        #expect(plan.map(\.priority) == [254, 253, 0, 0])
        #expect(CodecMapping.plan(requested: ["nope"], available: available).allSatisfy { $0.priority == 0 })
    }

    @Test func remotePartyParsing() {
        let a = RemoteParty.parse("\"Alice Smith\" <sip:100@example.com;transport=tcp>")
        #expect(a == RemoteParty(displayName: "Alice Smith", uri: "sip:100@example.com;transport=tcp", number: "100"))
        let b = RemoteParty.parse("<sip:+74951234567@example.com>")
        #expect(b == RemoteParty(displayName: nil, uri: "sip:+74951234567@example.com", number: "+74951234567"))
        let c = RemoteParty.parse("sip:test@127.0.0.1:5080")
        #expect(c == RemoteParty(displayName: nil, uri: "sip:test@127.0.0.1:5080", number: "test"))
    }

    func snapshot(outgoing: Bool, state: InviteState, media: MediaStatus = .none,
                  status: Int = 0, text: String = "") -> CallSnapshot {
        CallSnapshot(slot: 2, accIndex: 0, isOutgoing: outgoing, state: state, lastStatus: status,
                     lastStatusText: text, remoteInfo: "<sip:100@example.com>", sipCallID: "x",
                     mediaStatus: media, confSlot: 3, connectDuration: 0, serial: 7,
                     codec: media == .active ? "opus/48000" : nil, isSecure: false)
    }

    @Test func callStateMapping() {
        let inRec = CallRecord(serial: 7, accountID: .unknown, direction: .incoming, announced: true)
        let outRec = CallRecord(serial: 7, accountID: .unknown, direction: .outgoing, announced: true)
        var held = outRec
        held.localHold = true

        #expect(EngineBridge.makeInfo(snapshot(outgoing: false, state: .early), inRec).state == .incoming)
        #expect(EngineBridge.makeInfo(snapshot(outgoing: true, state: .early), outRec).state == .early)
        #expect(EngineBridge.makeInfo(snapshot(outgoing: true, state: .calling), outRec).state == .calling)
        let active = EngineBridge.makeInfo(snapshot(outgoing: true, state: .confirmed, media: .active), outRec)
        #expect(active.state == .connected)
        #expect(active.codec == "opus/48000")
        #expect(active.id == CallID(raw: 2, serial: 7))
        #expect(EngineBridge.makeInfo(snapshot(outgoing: true, state: .confirmed, media: .active), held).state == .held)
        #expect(EngineBridge.makeInfo(snapshot(outgoing: true, state: .confirmed, media: .localHold), outRec).isOnHold)
        #expect(EngineBridge.makeInfo(snapshot(outgoing: true, state: .disconnected, status: 486, text: "Busy Here"),
                                      outRec).state == .disconnected(code: 486, reason: "Busy Here"))

        // .callEnded keeps the codec and SRTP state the call had while media was up.
        var ended = outRec
        ended.lastCodec = "PCMA/8000"
        ended.lastSecure = true
        let endedInfo = EngineBridge.makeInfo(snapshot(outgoing: true, state: .disconnected, status: 200), ended)
        #expect(endedInfo.codec == "PCMA/8000" && endedInfo.isSecure)
        #expect(EngineBridge.makeInfo(snapshot(outgoing: true, state: .confirmed), ended).codec == nil)
    }
}
