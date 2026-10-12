import Foundation

// Public value types of the engine (docs/ENGINE.md "Public types").
// AccountID, AccountConfig, TransportKind, SRTPMode and NetworkSettings live in Model/.

public enum RegistrationState: Equatable, Sendable {
    case unregistered
    case registering
    case registered(expires: Int)
    case failed(code: Int, reason: String)
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

    public init(
        id: CallID, accountID: AccountID, direction: CallDirection, state: CallState,
        remote: RemoteParty, startedAt: Date? = nil, isMuted: Bool = false,
        isOnHold: Bool = false, isRecording: Bool = false, inConference: Bool = false,
        codec: String? = nil, isSecure: Bool = false, answerAfter: Int? = nil
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

public enum PresenceStatus: String, Codable, Sendable {   // presence status of a contact or of our own account
    case available, away, dnd, offline
}

public enum EngineEvent: Sendable {
    case registration(AccountID, RegistrationState)
    case incomingCall(CallInfo)
    case callChanged(CallInfo)
    case callEnded(CallInfo, duration: TimeInterval)
    case transferStatus(CallID, code: Int, final: Bool)
    case dtmfReceived(CallID, digit: Character)
    case buddyPresence(contactURI: String, PresenceStatus)   // presence update for a watched contact
    case audioDevicesChanged
    case log(level: Int, String)
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
