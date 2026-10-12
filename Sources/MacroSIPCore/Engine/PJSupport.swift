internal import CPJSUA
import Foundation

/// Small helpers over the CPJSUA shim: status checking, string conversion, thread registration.
enum PJ {
    static let success: pj_status_t = 0
    static let invalidID: Int32 = Int32(PJSUA_INVALID_ID.rawValue)

    /// pj_strerror text for a status.
    static func errorText(_ status: pj_status_t) -> String {
        var buf = [CChar](repeating: 0, count: 256)
        return buf.withUnsafeMutableBufferPointer { p -> String in
            guard let base = p.baseAddress else { return "error \(status)" }
            return String(cString: cpjsua_strerror(status, base, p.count))
        }
    }

    static func error(_ status: pj_status_t, _ what: String) -> EngineError {
        .pjsip(status: status, message: "\(what): \(errorText(status))")
    }

    /// Throws `EngineError.pjsip` unless `status` is PJ_SUCCESS.
    static func check(_ status: pj_status_t, _ what: String) throws {
        guard status == success else { throw error(status, what) }
    }

    /// For best-effort calls whose failure must not abort the caller: logs the pj_strerror text.
    static func warn(_ status: pj_status_t, _ what: @autoclosure () -> String) {
        guard status != success else { return }
        let text = "\(what()): \(errorText(status))"
        EngineBridge.shared.engineLogger.error("\(text, privacy: .public)")
        EngineBridge.shared.emit(.log(level: 2, "engine: \(text)"))
    }

    /// Logs a non-fatal error of a best-effort step.
    static func warn(_ error: Error, _ what: String) {
        let text = "\(what): \(error)"
        EngineBridge.shared.engineLogger.error("\(text, privacy: .public)")
        EngineBridge.shared.emit(.log(level: 2, "engine: \(text)"))
    }

    /// Registers the calling thread with pjlib (idempotent, thread-local descriptor in C).
    /// Returns false when pjsua does not exist.
    @discardableResult
    static func registerThread() -> Bool {
        cpjsua_thread_register() == success
    }

    static func string(_ s: pj_str_t) -> String {
        guard let ptr = s.ptr, s.slen > 0 else { return "" }
        return String(decoding: UnsafeRawBufferPointer(start: ptr, count: Int(s.slen)), as: UTF8.self)
    }

    /// Fixed-size C char arrays are imported as tuples; read them as a NUL-terminated string.
    static func string<T>(tuple: T) -> String {
        withUnsafeBytes(of: tuple) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}

/// Owns C copies of Swift strings for the duration of a pjsua call that takes `pj_str_t`.
/// pjsua copies every config string it keeps (pjsua_acc_add, pjsua_init...), so the arena
/// only has to outlive the call. Use with `withExtendedLifetime(arena) { ... }`.
final class CStringArena {
    private var buffers: [UnsafeMutablePointer<CChar>] = []

    func pj(_ s: String) -> pj_str_t {
        guard let p = strdup(s) else { return pj_str_t(ptr: nil, slen: 0) }
        buffers.append(p)
        return cpjsua_str(p)
    }

    func cString(_ s: String) -> UnsafePointer<CChar>? {
        guard let p = strdup(s) else { return nil }
        buffers.append(p)
        return UnsafePointer(p)
    }

    deinit {
        for p in buffers { free(p) }
    }
}

/// pjsip_inv_state as a Swift enum.
enum InviteState: Sendable, Equatable {
    case null, calling, incoming, early, connecting, confirmed, disconnected

    init(_ s: pjsip_inv_state) {
        switch s {
        case PJSIP_INV_STATE_CALLING: self = .calling
        case PJSIP_INV_STATE_INCOMING: self = .incoming
        case PJSIP_INV_STATE_EARLY: self = .early
        case PJSIP_INV_STATE_CONNECTING: self = .connecting
        case PJSIP_INV_STATE_CONFIRMED: self = .confirmed
        case PJSIP_INV_STATE_DISCONNECTED: self = .disconnected
        default: self = .null
        }
    }
}

/// pjsua_call_media_status as a Swift enum.
enum MediaStatus: Sendable, Equatable {
    case none, active, localHold, remoteHold, error

    init(_ s: pjsua_call_media_status) {
        switch s {
        case PJSUA_CALL_MEDIA_ACTIVE: self = .active
        case PJSUA_CALL_MEDIA_LOCAL_HOLD: self = .localHold
        case PJSUA_CALL_MEDIA_REMOTE_HOLD: self = .remoteHold
        case PJSUA_CALL_MEDIA_ERROR: self = .error
        default: self = .none
        }
    }
}

/// Sendable Swift copy of `cpjsua_call_snapshot`.
struct CallSnapshot: Sendable {
    var slot: Int32
    var accIndex: Int32
    var isOutgoing: Bool
    var state: InviteState
    var lastStatus: Int
    var lastStatusText: String
    var remoteInfo: String
    var sipCallID: String
    var mediaStatus: MediaStatus
    var confSlot: Int32
    var connectDuration: TimeInterval
    var serial: UInt64
    var codec: String?
    var isSecure: Bool

    /// Reads the call from pjsua. Must run on a pj-registered thread.
    static func read(_ slot: Int32) -> CallSnapshot? {
        let p = UnsafeMutablePointer<cpjsua_call_snapshot>.allocate(capacity: 1)
        p.initialize(to: cpjsua_call_snapshot())
        defer {
            p.deinitialize(count: 1)
            p.deallocate()
        }
        guard cpjsua_call_snapshot_get(slot, p) == PJ.success else { return nil }
        let s = p.pointee
        let codec = s.has_audio_stream != 0 ? PJ.string(tuple: s.codec) : ""
        return CallSnapshot(
            slot: slot,
            accIndex: s.acc_id,
            isOutgoing: s.is_outgoing != 0,
            state: InviteState(s.state),
            lastStatus: Int(s.last_status),
            lastStatusText: PJ.string(tuple: s.last_status_text),
            remoteInfo: PJ.string(tuple: s.remote_info),
            sipCallID: PJ.string(tuple: s.sip_call_id),
            mediaStatus: MediaStatus(s.media_status),
            confSlot: s.conf_slot,
            connectDuration: TimeInterval(s.connect_msec) / 1000,
            serial: UInt64(UInt(bitPattern: s.user_data)),
            codec: codec.isEmpty ? nil : codec,
            isSecure: s.is_secure != 0
        )
    }

    /// Ids of every call slot pjsua currently uses.
    static func allSlots() -> [Int32] {
        var ids = [pjsua_call_id](repeating: PJ.invalidID, count: 16)
        let n = ids.withUnsafeMutableBufferPointer { p -> UInt32 in
            guard let base = p.baseAddress else { return 0 }
            return cpjsua_enum_calls(base, UInt32(p.count))
        }
        return Array(ids.prefix(Int(n)))
    }
}

extension AccountID {
    /// Placeholder for calls whose pjsua account is not (or no longer) known to the engine.
    static let unknown = AccountID(raw: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)))
}

extension RemoteParty {
    /// Parses a printed name-addr such as `"Alice" <sip:100@example.com;transport=tcp>`.
    static func parse(_ raw: String) -> RemoteParty {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var name: String?
        var uri = trimmed
        if let lt = trimmed.firstIndex(of: "<"),
           let gt = trimmed[lt...].firstIndex(of: ">") {
            uri = String(trimmed[trimmed.index(after: lt)..<gt])
            let n = trimmed[..<lt]
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            name = n.isEmpty ? nil : n
        }
        var number = DialString.userPart(of: uri)
        if let semi = number.firstIndex(of: ";") { number = String(number[..<semi]) }
        return RemoteParty(displayName: name, uri: uri, number: number)
    }
}

/// `Call-Info` header parsing (the C parser in shim.c, also used on incoming INVITEs).
enum CallInfoHeader {
    /// Seconds of an `answer-after=N` parameter in a Call-Info header value, nil if absent.
    static func answerAfter(_ value: String) -> Int? {
        let n = value.withCString { cpjsua_parse_answer_after($0) }
        return n >= 0 ? Int(n) : nil
    }
}
