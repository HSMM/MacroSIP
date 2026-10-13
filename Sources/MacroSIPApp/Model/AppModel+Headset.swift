import Foundation
import MacroSIPCore

/// Headset call-control buttons (`Platform/HeadsetButtons.swift`): what a button does to the calls, and
/// which LEDs the headset shows for them.
extension AppModel {
    /// Creates the controller and, outside demo launches, starts watching for HID telephony devices.
    func startHeadsetButtons() {
        guard headsetButtons == nil else { return }
        let controller = HeadsetButtons(
            handler: { [weak self] event in self?.handleHeadsetEvent(event) },
            deviceChanged: { [weak self] name in self?.headsetButtonsDevice = name })
        headsetButtons = controller
        syncHeadsetIndicators()
        if headsetButtonsEnabled, !launch.isDemo { controller.start() }
    }

    func stopHeadsetButtons() {
        headsetButtons?.stop()
        headsetButtons = nil
        headsetButtonsDevice = nil
    }

    /// Settings › Audio "Headset buttons": off stops the controller (LEDs off, devices released), on starts it.
    func setHeadsetButtonsEnabled(_ on: Bool) {
        guard headsetButtonsEnabled != on else { return }
        headsetButtonsEnabled = on
        guard engineReady || headsetButtons != nil else { return }        // bootstrap starts it with the stored value
        if on {
            if headsetButtons == nil { startHeadsetButtons() } else if !launch.isDemo { headsetButtons?.start() }
        } else {
            headsetButtons?.stop()
            headsetButtonsDevice = nil
        }
    }

    /// Hook switch: off-hook answers the ringing call (the active one goes on hold), on-hook ends the active call.
    /// A hook button (momentary) does whichever applies: answer a ringing call, else hang up the current one.
    /// Flash answers the waiting call or swaps the held one in; Phone Mute toggles the microphone of the
    /// current call; Redial calls the last outgoing number when nothing is going on.
    func handleHeadsetEvent(_ event: HeadsetEvent) {
        switch event {
        case .offHook:
            if let ringing = incomingCall {
                answer(ringing.id)
                headsetButtons?.callAnswered()          // a release within a second is a long press, not a hang-up
            }
        case .onHook:
            if let active = activeCall { hangup(active.id) }
        case .hookPress:
            if let ringing = incomingCall { answer(ringing.id) }
            else if let current = currentCall { hangup(current.id) }
        case .flash:
            if let ringing = incomingCall { answer(ringing.id) }
            else if let held = liveCalls.first(where: \.isHeldCall) { switchTo(held) }
        case .hold:
            if let current = currentCall { toggleHold(current) }
        case .drop:
            if let current = currentCall { hangup(current.id) }
        case .mute:
            toggleMuteCurrent()
        case .redial:
            guard calls.isEmpty, let last = lastDialedNumber else { return }
            placeCall(to: last)
        }
    }

    /// What the headset shows: Off-Hook while a call is answered or being placed, Ring while one rings,
    /// Mute when the current call is muted. Called from `afterCallsChanged`.
    func syncHeadsetIndicators() {
        headsetButtons?.setIndicators(headsetIndicators)
    }

    var headsetIndicators: HeadsetIndicators {
        HeadsetIndicators(offHook: !liveCalls.isEmpty, ring: incomingCall != nil, mute: currentCall?.isMuted ?? false)
    }
}
