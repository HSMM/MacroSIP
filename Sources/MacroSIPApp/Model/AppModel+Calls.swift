import SwiftUI
import AppKit
import AVFoundation
import MacroSIPCore

extension AppModel {
    // MARK: - Placing calls

    /// Account used for a dial: explicit > contact preference > picker > default.
    func accountForDial(explicit: AccountID? = nil, contact: Contact? = nil) -> AccountConfig? {
        if let e = explicit, let a = account(e), a.enabled { return a }
        if let c = contact?.preferredAccountID, let a = account(c), a.enabled { return a }
        return effectiveAccount
    }

    /// Dial pad / Return / Call button. Empty field redials the last number.
    func placeCallFromField() {
        let text = dialText.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            if let last = lastDialedNumber { placeCall(to: last) }
            return
        }
        placeCall(to: text, account: nil)
    }

    func placeCall(to text: String, account explicit: AccountID? = nil, contact: Contact? = nil) {
        let target = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return }
        guard let acct = accountForDial(explicit: explicit, contact: contact) else {
            showBanner(L.bannerNoAccount); return
        }
        guard let dial = DialString.parse(target, account: acct) else { return }
        guard calls.count < 4 else { showBanner(L.bannerTooManyCalls); return }
        run {
            await self.ensureMicrophone()
            // A second call holds the active one first.
            for active in self.activeCalls { try await self.engine.setHold(active.id, true) }
            _ = try await self.engine.makeCall(to: dial, from: acct.id)
            self.dialText = ""
            self.selectedAccountID = nil
            self.tab = .dialpad
            self.showKeypad = false
        }
    }

    func placeCall(to contact: Contact, account: AccountID? = nil) {
        placeCall(to: contact.number, account: account, contact: contact)
    }

    func callBack(_ entry: CallLogEntry, account: AccountID? = nil) {
        placeCall(to: entry.remoteNumber, account: account ?? (self.account(entry.accountID) != nil ? entry.accountID : nil))
    }

    /// Microphone permission is requested on the first real call, not at launch.
    func ensureMicrophone() async {
        guard !isMockEngine else { return }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: micDenied = false
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            micDenied = !granted
        default: micDenied = true
        }
    }

    // MARK: - In-call actions

    func hangup(_ id: CallID) { run { try await self.engine.hangup(id) } }

    func endCurrentCall() {
        guard let c = currentCall else { return }
        hangup(c.id)
    }

    /// In a conference the microphone is muted for every leg.
    func toggleMute(_ call: CallInfo) {
        let legs = legs(of: call)
        let on = !call.isMuted
        run { for leg in legs { try await self.engine.setMute(leg.id, on) } }
    }

    func toggleMuteCurrent() { if let c = currentCall { toggleMute(c) } }

    /// Hold toggle. A conference is one unit: holding or resuming one leg does the same to all legs.
    /// Resuming holds the other active calls first (but never a leg of the same conference).
    func toggleHold(_ call: CallInfo) {
        let unit = legs(of: call)
        run {
            if call.isHeldCall {
                for other in self.activeCalls where !unit.contains(where: { $0.id == other.id }) {
                    try await self.engine.setHold(other.id, true)
                }
                if call.inConference, unit.count >= 2 { try await self.engine.merge(unit.map(\.id)) }   // merge un-holds the legs
                else { try await self.engine.setHold(call.id, false) }
            } else {
                for leg in unit { try await self.engine.setHold(leg.id, true) }
            }
        }
    }

    func switchTo(_ call: CallInfo) {
        guard call.isHeldCall else { return }
        toggleHold(call)
    }

    func sendDTMF(_ digit: Character) {
        guard let call = currentCall else { return }
        dtmfSent.append(digit)
        run { try await self.engine.sendDTMF(call.id, String(digit)) }
    }

    // MARK: - Incoming calls

    /// Answer holds the active call first (the call becomes active, the other one held).
    func answer(_ id: CallID) {
        clearAutoAnswer(id)
        run {
            for active in self.activeCalls { try await self.engine.setHold(active.id, true) }
            try await self.engine.answer(id)
            self.tab = .dialpad
        }
    }

    func holdAndAnswer(_ id: CallID) { clearAutoAnswer(id); answer(id) }

    func endCurrentAndAnswer(_ id: CallID) {
        clearAutoAnswer(id)
        run {
            if let current = self.currentCall { try await self.engine.hangup(current.id) }
            try await self.engine.answer(id)
            self.tab = .dialpad
        }
    }

    func decline(_ id: CallID) {
        clearAutoAnswer(id)
        run { try await self.engine.reject(id, code: 486) }
    }

    func silenceRingtone(_ id: CallID) {
        ringtoneSilenced.insert(id)
        Task { await engine.silenceRingtone() }
    }

    // MARK: - Conference

    /// Calls that Merge would join: everything answered.
    var mergeableCalls: [CallInfo] { liveCalls.filter(\.isEstablished) }

    var canMerge: Bool {
        let calls = mergeableCalls
        return calls.count >= 2 && !calls.allSatisfy(\.inConference) && transfer == nil
    }

    func mergeCalls() {
        let ids = mergeableCalls.map(\.id)
        guard ids.count >= 2 else { return }
        run { try await self.engine.merge(ids) }
    }

    /// The leg leaves the conference and stays on hold (SCREENS 5.4).
    func split(_ call: CallInfo) {
        run {
            try await self.engine.split(call.id)
            try await self.engine.setHold(call.id, true)
        }
    }

    func endConference() {
        let ids = conferenceCalls.map(\.id)
        run {
            var firstError: Error?
            for id in ids {
                do { try await self.engine.hangup(id) } catch { firstError = firstError ?? error }
            }
            if let firstError { throw firstError }
        }
    }

    // MARK: - Transfer

    func blindTransfer(_ call: CallInfo, to target: String) {
        guard let acct = account(call.accountID), let dial = DialString.parse(target, account: acct) else { return }
        run { try await self.engine.blindTransfer(call.id, to: dial) }
    }

    /// Attended: hold the current call, call the target, then show the "Complete Transfer" banner.
    func startAttendedTransfer(_ call: CallInfo, to target: String) {
        guard let acct = account(call.accountID), let dial = DialString.parse(target, account: acct) else { return }
        guard calls.count < 4 else { showBanner(L.bannerTooManyCalls); return }
        run {
            try await self.engine.setHold(call.id, true)
            let id = try await self.engine.makeCall(to: dial, from: call.accountID)
            self.transfer = TransferContext(original: call.id, consult: id)
            self.showKeypad = false
        }
    }

    func completeTransfer() {
        guard let t = transfer, let consult = t.consult else { return }
        run { try await self.engine.attendedTransfer(t.original, replacing: consult) }
    }

    /// Cancel: hang up the consultation call and resume the original one.
    func cancelTransfer() {
        guard let t = transfer else { return }
        transfer = nil
        run {
            if let c = t.consult { try await self.engine.hangup(c) }
            try await self.engine.setHold(t.original, false)
        }
    }

    // MARK: - Do Not Disturb

    func toggleDND() {
        updateSettings { $0.general.doNotDisturb.toggle() }
    }

    // MARK: - Links (sip:, sips:, tel:)

    var linkOpenMode: LinkOpenMode {
        get { LinkOpenMode(rawValue: prefs.string(forKey: "linkOpenMode") ?? "") ?? (settings.general.askBeforeCallingFromURL ? .ask : .callImmediately) }
        set {
            prefs.set(newValue.rawValue, forKey: "linkOpenMode")
            updateSettings { $0.general.askBeforeCallingFromURL = newValue != .callImmediately }
        }
    }

    func handleURL(_ url: URL) {
        guard settings.general.handleURLSchemes, ["sip", "sips", "tel"].contains(url.scheme?.lowercased() ?? "") else { return }
        var number = url.absoluteString
        if url.scheme?.lowercased() == "tel" { number = String(number.dropFirst(4)) }
        number = number.removingPercentEncoding ?? number
        guard hasAccounts else { showMainWindow(); showBanner(L.bannerNoAccount); return }
        switch linkOpenMode {
        case .callImmediately:
            placeCall(to: number)
            showMainWindow()
        case .ask:
            dialText = number
            tab = .dialpad
            showMainWindow()
            showBanner(L.bannerLinkFilled(number), isError: false)
        case .fillOnly:
            dialText = number
            tab = .dialpad
        }
    }
}
