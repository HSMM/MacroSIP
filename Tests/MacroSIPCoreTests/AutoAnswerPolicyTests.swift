import Testing
import Foundation
@testable import MacroSIPCore

@Suite("Auto-answer policy")
struct AutoAnswerPolicyTests {
    private func call(direction: CallDirection = .incoming, answerAfter: Int? = nil) -> CallInfo {
        CallInfo(id: CallID(raw: 0, serial: 1), accountID: AccountID(raw: UUID()), direction: direction,
                 state: .incoming, remote: RemoteParty(displayName: nil, uri: "sip:100@h", number: "100"),
                 answerAfter: answerAfter)
    }

    @Test func offModeNeverAnswers() {
        let s = AutoAnswerSettings(mode: .off, delaySeconds: 5, honourCallInfo: false)
        #expect(AutoAnswerPolicy.decide(call: call(), isContact: true, settings: s, onAnotherCall: false, doNotDisturb: false) == nil)
    }

    @Test func allModeUsesConfiguredDelay() {
        let s = AutoAnswerSettings(mode: .all, delaySeconds: 7)
        #expect(AutoAnswerPolicy.decide(call: call(), isContact: false, settings: s, onAnotherCall: false, doNotDisturb: false) == 7)
    }

    @Test func contactsOnlyRequiresContact() {
        let s = AutoAnswerSettings(mode: .contactsOnly, delaySeconds: 3)
        #expect(AutoAnswerPolicy.decide(call: call(), isContact: false, settings: s, onAnotherCall: false, doNotDisturb: false) == nil)
        #expect(AutoAnswerPolicy.decide(call: call(), isContact: true, settings: s, onAnotherCall: false, doNotDisturb: false) == 3)
    }

    @Test func dndAndSecondCallWin() {
        let s = AutoAnswerSettings(mode: .all, delaySeconds: 1)
        #expect(AutoAnswerPolicy.decide(call: call(answerAfter: 0), isContact: true, settings: s, onAnotherCall: false, doNotDisturb: true) == nil)
        #expect(AutoAnswerPolicy.decide(call: call(answerAfter: 0), isContact: true, settings: s, onAnotherCall: true, doNotDisturb: false) == nil)
    }

    @Test func callInfoHeaderOverridesModeAndDelay() {
        let honour = AutoAnswerSettings(mode: .off, delaySeconds: 5, honourCallInfo: true)
        #expect(AutoAnswerPolicy.decide(call: call(answerAfter: 2), isContact: false, settings: honour, onAnotherCall: false, doNotDisturb: false) == 2)
        #expect(AutoAnswerPolicy.decide(call: call(answerAfter: 0), isContact: false, settings: honour, onAnotherCall: false, doNotDisturb: false) == 0)
        let ignore = AutoAnswerSettings(mode: .all, delaySeconds: 5, honourCallInfo: false)
        #expect(AutoAnswerPolicy.decide(call: call(answerAfter: 2), isContact: false, settings: ignore, onAnotherCall: false, doNotDisturb: false) == 5)
    }

    @Test func outgoingCallsAreNeverAutoAnswered() {
        let s = AutoAnswerSettings(mode: .all, delaySeconds: 0)
        #expect(AutoAnswerPolicy.decide(call: call(direction: .outgoing), isContact: true, settings: s, onAnotherCall: false, doNotDisturb: false) == nil)
    }
}
