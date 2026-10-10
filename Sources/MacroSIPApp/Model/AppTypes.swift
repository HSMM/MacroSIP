import Foundation
import MacroSIPCore

enum MainTab: Hashable { case dialpad, contacts, callLog }

enum SettingsTab: String, Hashable, CaseIterable { case general, accounts, audio, network, codecs }

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
