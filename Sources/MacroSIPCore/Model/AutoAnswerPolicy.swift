import Foundation

/// Decides whether an incoming call is answered automatically (SCREENS.md 8.7 and 6.5).
/// Pure function so the rules are testable without an engine.
public enum AutoAnswerPolicy {
    /// - Returns: the delay in seconds before answering, or nil when the call must ring normally.
    ///
    /// Rules, in order:
    /// 1. Do Not Disturb wins: never auto-answer.
    /// 2. Never auto-answer while another call exists (connected, held or ringing).
    /// 3. `Call-Info: answer-after=N` is honoured when `settings.honourCallInfo`, even in mode `.off`;
    ///    the header's delay wins over the configured one (N = 0 answers at once).
    /// 4. Mode `.all` answers every call, `.contactsOnly` only when `isContact`, `.off` nothing else.
    public static func decide(
        call: CallInfo,
        isContact: Bool,
        settings: AutoAnswerSettings,
        onAnotherCall: Bool,
        doNotDisturb: Bool
    ) -> TimeInterval? {
        guard call.direction == .incoming, !doNotDisturb, !onAnotherCall else { return nil }
        if settings.honourCallInfo, let after = call.answerAfter {
            return TimeInterval(max(0, after))
        }
        let delay = TimeInterval(max(0, settings.delaySeconds))
        switch settings.mode {
        case .off: return nil
        case .all: return delay
        case .contactsOnly: return isContact ? delay : nil
        }
    }
}
