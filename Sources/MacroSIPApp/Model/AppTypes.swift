import Foundation
import MacroSIPCore

enum MainTab: Hashable { case dialpad, contacts, callLog }

enum SettingsTab: String, Hashable, CaseIterable { case general, accounts, audio, network, codecs, recording, calls, quickKeys, directory }

enum LinkOpenMode: String, CaseIterable {
    case ask, callImmediately, fillOnly
}

struct Banner: Identifiable, Equatable {
    let id = UUID()
    var text: String
    var isError: Bool
}

/// Attended transfer in progress: `original` is held, `consult` is the call to the transfer target.
struct TransferContext: Equatable {
    var original: CallID
    var consult: CallID?
}

enum AccountTestResult: Equatable {
    case success(ms: Int)
    case failed(code: Int, reason: String)
    case timeout
    case error(String)
}

/// Where the account editor sheet is shown.
struct AccountEditorRequest: Identifiable {
    let id = UUID()
    var accountID: AccountID?        // nil = new account
}

extension CallInfo {
    var isHeldCall: Bool { state == .held || isOnHold }
    var isRinging: Bool { state == .incoming }
    var isEstablished: Bool {
        switch state { case .connected, .held: return true; default: return false }
    }
    var isLive: Bool {
        if case .disconnected = state { return false }
        return true
    }
}

extension RegistrationState {
    /// A temporary failure the engine is retrying: attempts so far, wait before the next one, last error.
    var retry: (attempt: Int, nextRetryIn: TimeInterval, lastError: String)? {
        if case let .reconnecting(attempt, next, error) = self { return (attempt, next, error) }
        return nil
    }

    var shortReason: String? {
        if case let .failed(code, reason) = self { return code > 0 ? "\(code)" : reason }
        return nil
    }
    var fullReason: String? {
        if case let .failed(code, reason) = self { return code > 0 ? "\(code) \(reason)" : reason }
        return nil
    }
}

extension EngineError {
    var uiText: String { description }
}

func describe(_ error: Error) -> String {
    if let e = error as? EngineError { return e.description }
    if let e = error as? KeychainError { return "Keychain error: \(e)" }
    return error.localizedDescription
}

/// A recording in progress: the temporary WAV the engine writes (`wav`; a stereo set derives its
/// `-local` / `-remote` files from it, `files` once the engine reports them) and what the file name needs.
struct RecordingJob {
    var wav: URL
    var layout: RecordingLayout = .mono
    var files: RecordingFiles?
    var startedAt: Date
    var direction: CallDirection
}

/// Auto-answer armed for a ringing call (SCREENS.md 6.5): answers at `fireAt` unless cancelled.
struct AutoAnswerCountdown: Equatable {
    var start: Date
    var fireAt: Date
    var total: TimeInterval { fireAt.timeIntervalSince(start) }
}

/// A dictionary that keeps the `capacity` most recently added keys.
struct RecentMap<Key: Hashable, Value> {
    private var storage: [Key: Value] = [:]
    private var order: [Key] = []
    let capacity: Int

    init(capacity: Int) { self.capacity = capacity }

    subscript(key: Key) -> Value? {
        get { storage[key] }
        set {
            if let newValue {
                if storage.updateValue(newValue, forKey: key) == nil { order.append(key) }
                while order.count > capacity { storage[order.removeFirst()] = nil }
            } else if storage.removeValue(forKey: key) != nil {
                order.removeAll { $0 == key }
            }
        }
    }

    @discardableResult
    mutating func removeValue(forKey key: Key) -> Value? {
        let old = self[key]
        self[key] = nil
        return old
    }
}

/// Codes stored in `CallLogEntry.note`; the text is looked up when a row is shown (`L.logNoteText`).
enum CallLogNote {
    static let callLimit = "callLimit"
    static let connectionLost = "connectionLost"
    static let busy = "busy"
    static let denied = "denied"            // turned away by Settings › Calls › Incoming calls
}
