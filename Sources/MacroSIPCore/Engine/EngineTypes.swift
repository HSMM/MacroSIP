import Foundation

// Public value types of the engine (docs/ENGINE.md "Public types").
// AccountID, AccountConfig, TransportKind, SRTPMode and NetworkSettings live in Model/.

public enum RegistrationState: Equatable, Sendable {
    case unregistered
    case registering
    case registered(expires: Int)
    /// Permanent failure (401/403/404, other 4xx-6xx): no automatic retry.
    case failed(code: Int, reason: String)
    /// Temporary failure (timeout, 5xx, transport or DNS error, TCP/TLS connection lost):
    /// the engine retries after `nextRetryIn` seconds (2, 4, 8, 16, 32, then every 60 s;
    /// while the network is offline the retry waits for it). `attempt` counts the failed
    /// attempts since the last success (1 = first). `lastError` is "408 Request Timeout"
    /// or the transport error text.
    case reconnecting(attempt: Int, nextRetryIn: TimeInterval, lastError: String)
}

/// Whether the Mac has a usable network path (`Engine.networkState()`, `.network` events).
public enum NetworkState: Sendable, Equatable {
    case online, offline
}

/// Identifies one live call.
///
/// `raw` is the pjsua call slot (0..<8). PJSIP reuses slots, so `serial` (unique per
/// engine process) tells two calls in the same slot apart: a `CallID` kept by the UI
/// after `.callEnded` never addresses a newer call.
public struct CallID: Hashable, Sendable, CustomStringConvertible {
    public let raw: Int32
    public let serial: UInt64

    public init(raw: Int32, serial: UInt64) {
        self.raw = raw
        self.serial = serial
    }

    public var description: String { "call#\(raw).\(serial)" }
}

// CallDirection (incoming, outgoing, missed) is declared in Model/CallLogEntry.swift and
// shared with the call log; the engine only ever reports `.incoming` or `.outgoing`.

public enum CallState: Equatable, Sendable {
    case incoming
    case calling
    case early
    case connecting
    case connected
    case held
    case disconnected(code: Int, reason: String)
}

public struct RemoteParty: Equatable, Sendable {
    public var displayName: String?
    public var uri: String
    public var number: String

    public init(displayName: String?, uri: String, number: String) {
        self.displayName = displayName
        self.uri = uri
        self.number = number
    }
}

public struct CallInfo: Identifiable, Equatable, Sendable {
    public var id: CallID
    public var accountID: AccountID
    public var direction: CallDirection
    public var state: CallState
    public var remote: RemoteParty
    public var startedAt: Date?             // when connected
    public var isMuted: Bool
    public var isOnHold: Bool               // local hold
    public var isRecording: Bool            // call is being recorded
    public var inConference: Bool           // call is part of a conference
    public var codec: String?               // "opus/48000" once media is active
    public var isSecure: Bool               // SRTP active
    /// Seconds from `Call-Info: ...;answer-after=N` in the INVITE (intercom/paging); nil if absent.
    public var answerAfter: Int?
    /// Media is being re-established after a network change: the network is offline, the
    /// re-INVITE after a change is in flight, or no RTP arrived for more than 3 s while
    /// online (connected calls only). A call that stays without RTP and RTCP for 60 s
    /// ends with `.disconnected(code: 0, reason: Engine.connectionLostReason)`.
    public var isReconnecting: Bool

    public init(
        id: CallID, accountID: AccountID, direction: CallDirection, state: CallState,
        remote: RemoteParty, startedAt: Date? = nil, isMuted: Bool = false,
        isOnHold: Bool = false, isRecording: Bool = false, inConference: Bool = false,
        codec: String? = nil, isSecure: Bool = false, answerAfter: Int? = nil,
        isReconnecting: Bool = false
    ) {
        self.id = id
        self.accountID = accountID
        self.direction = direction
        self.state = state
        self.remote = remote
        self.startedAt = startedAt
        self.isMuted = isMuted
        self.isOnHold = isOnHold
        self.isRecording = isRecording
        self.inConference = inConference
        self.codec = codec
        self.isSecure = isSecure
        self.answerAfter = answerAfter
        self.isReconnecting = isReconnecting
    }
}

public struct AudioDevice: Identifiable, Equatable, Sendable {
    public var id: Int
    public var name: String
    public var inputChannels: Int
    public var outputChannels: Int

    public init(id: Int, name: String, inputChannels: Int, outputChannels: Int) {
        self.id = id
        self.name = name
        self.inputChannels = inputChannels
        self.outputChannels = outputChannels
    }
}

public struct CodecInfo: Identifiable, Equatable, Sendable {
    public var id: String           // "opus/48000/2"
    public var priority: UInt8      // 0 = disabled

    public init(id: String, priority: UInt8) {
        self.id = id
        self.priority = priority
    }
}

/// RTP counters of a call's audio stream (for diagnostics and the self-test).
public struct CallMediaStats: Equatable, Sendable {
    public var rxPackets: Int
    public var txPackets: Int
    public var rxLost: Int
    public var rxJitterMs: Double
    public var rttMs: Double
}

/// Presence status of a contact or of our own account. `ringing` is only reported for watched
/// contacts (their phone rings: BLF); it is never one of our own statuses.
public enum PresenceStatus: String, Codable, Sendable {
    case available, away, dnd, ringing, offline

    /// Decodes every raw value written so far; an unknown one (a newer version's status) decodes
    /// as `.offline` instead of failing the whole document.
    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = PresenceStatus(rawValue: raw) ?? .offline
    }
}

public enum EngineEvent: Sendable {
    case registration(AccountID, RegistrationState)
    case incomingCall(CallInfo)
    case callChanged(CallInfo)
    case callEnded(CallInfo, duration: TimeInterval)
    case transferStatus(CallID, code: Int, final: Bool)
    case dtmfReceived(CallID, digit: Character)
    /// Presence update for a watched contact. `note` is the PIDF/RPID note as received, trimmed
    /// ("Ringing", "On the phone", "Ready"...), nil when there is none; emitted when the status
    /// or the note changed.
    case buddyPresence(contactURI: String, PresenceStatus, note: String? = nil)
    case audioDevicesChanged
    /// Network path went online/offline; also once after `start` with the first evaluation.
    case network(NetworkState)
    /// Voicemail indicator (RFC 3842 message-summary NOTIFY) of an account with `mwi` on:
    /// whether messages wait and the new/old voice message counts. Emitted when the
    /// indicator changed (and on the first NOTIFY); `Engine.voicemailState(for:)` has the latest.
    case voicemail(AccountID, waiting: Bool, new: Int, old: Int)
    case log(level: Int, String)
}

/// The latest voicemail indicator of an account (`Engine.voicemailState(for:)`).
public struct VoicemailState: Equatable, Sendable {
    /// `Messages-Waiting: yes`.
    public var waiting: Bool
    /// New and old voice messages (`Voice-Message: new/old`).
    public var new: Int
    public var old: Int
    /// Urgent new and old messages (`Voice-Message: new/old (urgent new/urgent old)`), 0 if absent.
    public var urgentNew: Int
    public var urgentOld: Int

    public init(waiting: Bool, new: Int, old: Int, urgentNew: Int = 0, urgentOld: Int = 0) {
        self.waiting = waiting
        self.new = new
        self.old = old
        self.urgentNew = urgentNew
        self.urgentOld = urgentOld
    }
}

/// A short UI sound (`Engine.playEventSound`), played on the call output device, never sent
/// to a call or recorded.
public enum SoundEvent: Equatable, Sendable {
    /// Two rising beeps.
    case callConnected
    /// Two falling beeps.
    case callEnded
    /// The DTMF tone pair of `digit` (0-9, *, #, A-D) for 120 ms.
    case keyPress(Character)
    /// Three beeps.
    case voicemail
    /// Two low beeps.
    case error
}

public enum EngineError: Error, Equatable, Sendable, CustomStringConvertible {
    /// A pjsua call failed; `message` comes from pj_strerror.
    case pjsip(status: Int32, message: String)
    case notStarted
    case alreadyStarted
    case unknownAccount(AccountID)
    case noSuchCall(CallID)
    case tooManyCalls(limit: Int)
    case transportUnavailable(TransportKind)
    case invalidArgument(String)
    case unsupported(String)

    public var description: String {
        switch self {
        case let .pjsip(status, message): return "PJSIP error \(status): \(message)"
        case .notStarted: return "Engine is not started"
        case .alreadyStarted: return "Engine is already started (one pjsua instance per process)"
        case let .unknownAccount(id): return "Unknown account \(id.raw)"
        case let .noSuchCall(id): return "No such call \(id)"
        case let .tooManyCalls(limit): return "Too many calls (limit \(limit))"
        case let .transportUnavailable(kind): return "\(kind.rawValue.uppercased()) transport is not available"
        case let .invalidArgument(what): return "Invalid argument: \(what)"
        case let .unsupported(what): return "Not supported: \(what)"
        }
    }
}

/// How a call is recorded (`Engine.startRecording`).
public enum RecordingLayout: String, Codable, Sendable {
    /// One WAV with everything the call carries: the remote side(s) and our microphone.
    case mono
    /// Two time-aligned WAVs from the same base name: `<base>-local.wav` (our microphone
    /// only) and `<base>-remote.wav` (the remote side, plus every other leg of the call's
    /// conference). `RecordingConverter.convert(files:to:)` makes a stereo M4A of them
    /// (left = local, right = remote).
    case stereoSplit
}

/// The WAV files of one recording. `.mono`: `mixed` is set, `local`/`remote` are nil.
/// `.stereoSplit`: `local` and `remote` are set, `mixed` is nil.
public struct RecordingFiles: Sendable, Equatable {
    public var layout: RecordingLayout
    public var mixed: URL?
    public var local: URL?
    public var remote: URL?

    public init(layout: RecordingLayout, mixed: URL? = nil, local: URL? = nil, remote: URL? = nil) {
        self.layout = layout
        self.mixed = mixed
        self.local = local
        self.remote = remote
    }

    /// The files `Engine.startRecording(_:to: wavURL, layout:)` writes: `.mono` writes
    /// `wavURL` itself; `.stereoSplit` writes `<base>-local.wav` and `<base>-remote.wav` next
    /// to it, where `<base>` is `wavURL` without its extension (`wavURL` itself is not created).
    public static func planned(for wavURL: URL, layout: RecordingLayout) -> RecordingFiles {
        switch layout {
        case .mono:
            return RecordingFiles(layout: .mono, mixed: wavURL)
        case .stereoSplit:
            let dir = wavURL.deletingLastPathComponent()
            let base = wavURL.deletingPathExtension().lastPathComponent
            return RecordingFiles(layout: .stereoSplit,
                                  local: dir.appendingPathComponent("\(base)-local.wav"),
                                  remote: dir.appendingPathComponent("\(base)-remote.wav"))
        }
    }

    /// Every file of the set (mono: one, stereo split: local then remote).
    public var all: [URL] { [mixed, local, remote].compactMap { $0 } }
}

// MARK: - Call quality and audio options (release 26.1)

/// Coarse rating of a call's audio (`CallQuality.level`).
public enum QualityLevel: String, Sendable {
    case good, fair, poor
}

/// Receive-side quality of a call's audio stream (`Engine.quality(of:)`).
public struct CallQuality: Sendable, Equatable {
    /// Packets lost in the window since the previous `quality(of:)` (≈2 s when polled every
    /// 2 s), received direction, 0...100.
    public var lossPercent: Double
    /// RFC 3550 interarrival jitter of the received stream, latest value.
    public var jitterMs: Double
    /// Round-trip time from RTCP; 0 while unknown (no receiver report with LSR yet).
    public var rttMs: Double
    /// Estimated MOS 1.0...4.5 (`CallQualityModel`, a simplified ITU-T G.107 E-model).
    public var mos: Double
    /// good: MOS ≥ 3.8, fair: ≥ 3.0, poor: below.
    public var level: QualityLevel

    public init(lossPercent: Double, jitterMs: Double, rttMs: Double, mos: Double, level: QualityLevel) {
        self.lossPercent = lossPercent
        self.jitterMs = jitterMs
        self.rttMs = rttMs
        self.mos = mos
        self.level = level
    }
}

/// Opus encoder options (`Engine.start(... codecOptions:)`, `Engine.setCodecOptions`).
public struct CodecOptions: Codable, Equatable, Sendable {
    /// In-band FEC: the encoder expects 10 % loss and adds redundancy (0 % = none).
    public var opusFEC: Bool = true
    /// Opus DTX: almost no packets during silence (Opus-internal; PJSIP's own VAD stays off).
    public var opusDTX: Bool = false

    public init(opusFEC: Bool = true, opusDTX: Bool = false) {
        self.opusFEC = opusFEC
        self.opusDTX = opusDTX
    }

    private enum CodingKeys: String, CodingKey { case opusFEC, opusDTX }

    /// Missing keys take the defaults (settings written before a field existed).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        opusFEC = try c.decodeIfPresent(Bool.self, forKey: .opusFEC) ?? true
        opusDTX = try c.decodeIfPresent(Bool.self, forKey: .opusDTX) ?? false
    }
}

/// Which audio processing the calls' sound device uses (`Engine.audioProcessingMode()`).
public enum AudioProcessingMode: Equatable, Sendable {
    /// Apple's VoiceProcessingIO (echo cancellation, noise suppression, gain control) on the
    /// system default input and output: echo cancellation on and both devices on the default.
    case systemVoiceProcessing
    /// PJSIP's WebRTC echo canceller on the selected devices (names as in `audioDevices()`):
    /// echo cancellation on and the input or the output is not the system default.
    case softwareEchoCanceller(input: String, output: String)
    /// Echo cancellation is switched off (`NetworkSettings.echoCancellation`).
    case echoCancellationOff
}

// MARK: - Call options (release 26.1)

/// What happens when an incoming call arrives while another call is in progress
/// (`CallOptions.incomingWhileOnCall`).
public enum IncomingWhileOnCall: String, Codable, Sendable {
    /// The incoming window, and instead of the ringtone a short call-waiting tone in the
    /// call's output (two 440 Hz beeps of 150 ms at -20 dBFS, every 10 s) while the new call
    /// rings and another call is connected (not on local hold). Never sent to the far end and
    /// never recorded.
    case callWaiting
    /// The incoming window and the normal ringtone (the behaviour of 26.0).
    case windowOnly
    /// Single-call mode: a new incoming call is answered 486 Busy Here at once while another
    /// call is connected, held, or an outgoing call is being set up. The UI sees only
    /// `.callEnded(... .disconnected(code: 486 ...))` and a `.log` line.
    case busy
}

/// How `Engine.sendDTMF` sends digits (`CallOptions.dtmfMethod`).
public enum DTMFMethod: String, Codable, Sendable {
    /// RFC 2833 telephone-events when the remote offered telephone-event, else SIP INFO.
    case automatic
    /// RFC 2833 only; `sendDTMF` throws `.unsupported` when the remote did not offer it.
    case rfc2833
    /// SIP INFO (application/dtmf-relay) always.
    case sipINFO
    /// Tones (DTMF frequency pairs) mixed into the call's audio: 100 ms on, 50 ms off.
    case inband
}

/// Which incoming calls the engine turns away before they ring (`CallOptions.denyIncoming`, 26.2).
public enum DenyIncoming: String, Codable, Sendable, CaseIterable {
    /// Every call rings (the behaviour before 26.2).
    case nobody
    /// Every incoming INVITE is answered 603 Decline.
    case everyone
    /// Callers whose number (`CallOptions.knownNumberKey` of the From user part) is not in
    /// `CallOptions.knownNumbers` are answered 603 Decline; anonymous callers too.
    case notInContacts
    /// Anonymous callers (`CallOptions.isAnonymous`) are answered 433 Anonymity Disallowed.
    case anonymous
}

/// Engine-wide call behaviour (`Engine.start(... callOptions:)`, `Engine.setCallOptions`).
/// Not per account: `denyIncoming`, `doNotDisturb` and `incomingWhileOnCall` are evaluated when
/// an INVITE arrives (`incomingWhileOnCall` also on every call state change), `dtmfMethod` on
/// every `sendDTMF` (a change applies to the next digits of calls already in progress).
///
/// Order of the checks on an incoming INVITE: `denyIncoming` (603/433), `doNotDisturb` (486),
/// the call limit (486), single-call mode (486).
public struct CallOptions: Codable, Equatable, Sendable {
    public var incomingWhileOnCall: IncomingWhileOnCall = .callWaiting
    public var dtmfMethod: DTMFMethod = .automatic
    /// Do Not Disturb: every incoming INVITE is answered 486 Busy Here at once, before any
    /// 180, ringtone or call-waiting tone. The UI sees only `.callEnded(... 486)` and a `.log`
    /// line. Calls already in progress and outgoing calls are not affected.
    public var doNotDisturb: Bool = false
    /// Turns calls away before any 180, ringtone or `.incomingCall`: the UI sees only
    /// `.callEnded(... .disconnected(code: 603, reason: "Decline"))` (or 433 "Anonymity
    /// Disallowed") and a `.log` line "engine: call N from X denied with 603 Decline (...)".
    public var denyIncoming: DenyIncoming = .nobody
    /// The numbers of the address book for `.notInContacts`, as `Contact.normalize` gives them
    /// (digits for numbers, the lower-cased user part for SIP addresses). The engine compares
    /// them with `knownNumberKey`, which also ignores a leading "+". Not persisted (not in the
    /// JSON): the app sets it from its contacts every time.
    public var knownNumbers: Set<String> = []

    public init(incomingWhileOnCall: IncomingWhileOnCall = .callWaiting, dtmfMethod: DTMFMethod = .automatic,
                doNotDisturb: Bool = false, denyIncoming: DenyIncoming = .nobody, knownNumbers: Set<String> = []) {
        self.incomingWhileOnCall = incomingWhileOnCall
        self.dtmfMethod = dtmfMethod
        self.doNotDisturb = doNotDisturb
        self.denyIncoming = denyIncoming
        self.knownNumbers = knownNumbers
    }

    private enum CodingKeys: String, CodingKey { case incomingWhileOnCall, dtmfMethod, doNotDisturb, denyIncoming }

    /// Missing keys and unknown values take the defaults (settings written by other versions).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        incomingWhileOnCall = (try? c.decodeIfPresent(IncomingWhileOnCall.self, forKey: .incomingWhileOnCall)) ?? .callWaiting
        dtmfMethod = (try? c.decodeIfPresent(DTMFMethod.self, forKey: .dtmfMethod)) ?? .automatic
        doNotDisturb = (try? c.decodeIfPresent(Bool.self, forKey: .doNotDisturb)) ?? false
        denyIncoming = (try? c.decodeIfPresent(DenyIncoming.self, forKey: .denyIncoming)) ?? .nobody
    }

    /// How a number is compared for `.notInContacts`: `Contact.normalize` without a leading "+"
    /// ("+375 29 111-22-33" and "375291112233" match; "sip:Alice@host" -> "alice").
    public static func knownNumberKey(_ raw: String) -> String {
        let n = Contact.normalize(raw)
        return n.hasPrefix("+") ? String(n.dropFirst()) : n
    }

    /// From user parts that mean "no caller ID" (compared lower-cased).
    public static let anonymousUsers: Set<String> = ["anonymous", "unknown", "restricted", "private", "unavailable"]

    /// An anonymous caller: the From user part is empty or one of `anonymousUsers`, the From host
    /// is "anonymous.invalid" (RFC 3323), or the INVITE carries `Privacy: id` (or `user`/`header`).
    public static func isAnonymous(fromURI: String, privacy: String?) -> Bool {
        if let privacy {
            let tokens = privacy.lowercased().split(whereSeparator: { $0 == ";" || $0 == "," || $0 == " " })
            if tokens.contains(where: { $0 == "id" || $0 == "user" || $0 == "header" }) { return true }
        }
        let uri = fromURI.trimmingCharacters(in: .whitespaces)
        var user = DialString.userPart(of: uri)
        if let semi = user.firstIndex(of: ";") { user = String(user[..<semi]) }
        // "sip:host" has no user part: userPart returns the host.
        let hasUser = uri.contains("@")
        let host = hasUser ? String(uri[uri.index(after: uri.firstIndex(of: "@")!)...]).lowercased() : ""
        if host.hasPrefix("anonymous.invalid") { return true }
        let u = hasUser ? user.trimmingCharacters(in: .whitespaces).lowercased() : ""
        return u.isEmpty || anonymousUsers.contains(u)
    }

    /// The rule's answer for a caller: nil = let it ring, else (code, reason, why) for the log.
    public func denial(fromURI: String, privacy: String?) -> (code: Int, reason: String, why: String)? {
        switch denyIncoming {
        case .nobody:
            return nil
        case .everyone:
            return (603, "Decline", "incoming calls denied for everyone")
        case .anonymous:
            return CallOptions.isAnonymous(fromURI: fromURI, privacy: privacy)
                ? (433, "Anonymity Disallowed", "anonymous caller") : nil
        case .notInContacts:
            if CallOptions.isAnonymous(fromURI: fromURI, privacy: privacy) {
                return (603, "Decline", "anonymous caller, not in contacts")
            }
            var user = DialString.userPart(of: fromURI)
            if let semi = user.firstIndex(of: ";") { user = String(user[..<semi]) }
            let key = CallOptions.knownNumberKey(user)
            let known = knownNumbers.contains(key)
                || knownNumbers.contains { CallOptions.knownNumberKey($0) == key }
            return known ? nil : (603, "Decline", "caller not in contacts")
        }
    }
}
