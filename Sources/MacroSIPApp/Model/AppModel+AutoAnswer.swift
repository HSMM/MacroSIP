import Foundation
import MacroSIPCore

/// Auto-answer (SCREENS.md 6.5 and 8.7). The decision is `AutoAnswerPolicy`; this arms the countdown.
extension AppModel {
    func armAutoAnswer(for call: CallInfo) {
        guard let delay = AutoAnswerPolicy.decide(
            call: call,
            isContact: contact(forNumber: call.remote.number) != nil,
            settings: settings.autoAnswer,
            onAnotherCall: calls.contains { $0.id != call.id },
            doNotDisturb: doNotDisturb)
        else { return }
        if delay <= 0 { answer(call.id); return }
        let now = Date()
        autoAnswer[call.id] = AutoAnswerCountdown(start: now, fireAt: now.addingTimeInterval(delay))
        let id = call.id
        autoAnswerTasks[id]?.cancel()
        autoAnswerTasks[id] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, self.autoAnswer[id] != nil else { return }
            self.clearAutoAnswer(id)
            // Something else started in the meantime: do not take the call over the user's head.
            guard self.calls.contains(where: { $0.id == id && $0.isRinging }),
                  !self.calls.contains(where: { $0.id != id }) else { return }
            self.answer(id)
        }
    }

    /// Cancel on the strip: the call keeps ringing for a manual answer.
    func cancelAutoAnswer(_ id: CallID) {
        clearAutoAnswer(id)
        // The incoming panel is one row shorter now.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(60))
            self.refreshIncomingPresentation()
        }
    }

    func clearAutoAnswer(_ id: CallID) {
        autoAnswerTasks.removeValue(forKey: id)?.cancel()
        autoAnswer[id] = nil
    }
}
