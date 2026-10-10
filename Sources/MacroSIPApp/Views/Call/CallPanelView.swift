import SwiftUI
import MacroSIPCore

/// Screens 4 and 5: the Dialpad tab body while any call exists.
struct CallPanelView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let incoming = model.incomingCall {
            IncomingCallContent(call: incoming, inPanel: false)
        } else if model.showKeypad, let call = model.currentCall {
            DTMFKeypadView(call: call)
        } else if model.liveCalls.count >= 2 {
            MultiCallView()
        } else if let call = model.liveCalls.first {
            SingleCallView(call: call)
        }
    }
}

/// 4.1 Connected call (and the calling / ringing / held variants).
struct SingleCallView: View {
    @Environment(AppModel.self) private var model
    let call: CallInfo

    var body: some View {
        let name = model.name(for: call.remote)
        VStack(spacing: 8) {
            AvatarView(name: name, size: 48)
            Text(name).font(.system(size: 17, weight: .semibold)).lineLimit(1)
            Text(call.remote.number).font(.system(size: 12)).foregroundStyle(Theme.label2).lineLimit(1)
            LiveElapsed(call: call).font(.system(size: 22, weight: .light))
            stateLabel
            chips
            if model.micDenied { micDenied }
            Spacer(minLength: 0)
            CallControlGrid(call: call)
            EndCallButton(title: L.callEnd) { model.hangup(call.id) }
                .keyboardShortcut("d", modifiers: .command)
                .padding(.top, 4)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var stateLabel: some View {
        switch call.state {
        case .calling, .connecting: Text(L.callCalling).foregroundStyle(Theme.label2).font(.system(size: 11, weight: .medium))
        case .early: Text(L.callRinging).foregroundStyle(Theme.label2).font(.system(size: 11, weight: .medium))
        case .held: Text(L.callHeld).foregroundStyle(Theme.orange).font(.system(size: 11, weight: .medium))
        default:
            if call.isOnHold { Text(L.callHeld).foregroundStyle(Theme.orange).font(.system(size: 11, weight: .medium)) }
            else { Text(L.callConnected).foregroundStyle(Theme.green).font(.system(size: 11, weight: .medium)) }
        }
    }

    private var chips: some View {
        HStack(spacing: 6) {
            Chip { Text(L.callVia(model.accountName(call.accountID))) }
            if let codec = codecDisplay(call.codec) {
                Chip { Text(codec); SignalBars() }
                    .help(codec)
            }
            if call.isSecure {
                Chip { Image(systemName: "lock.fill").font(.system(size: 9)); Text(L.callSRTP) }
                    .help(L.callSRTPHelp)
            }
        }
        .lineLimit(1)
    }

    private var micDenied: some View {
        VStack(spacing: 4) {
            Text(L.micDenied).font(.system(size: 11.5, weight: .medium))
            Button(L.micOpenSettings) {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
            }
            .controlSize(.small)
        }
        .padding(8)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.orange.opacity(0.15)))
    }
}

/// 5.1 and 5.3: up to four call rows, controls for the active call, End Call with <name>.
struct MultiCallView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let calls = model.liveCalls
        let target = model.activeCall ?? calls.first
        VStack(spacing: 8) {
            HStack {
                Text(L.callsCount(calls.count).uppercased())
                Spacer()
                Text(L.callsSwitchHint)
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Theme.label2)
            .padding(.horizontal, 4)

            VStack(spacing: 2) {
                ForEach(calls) { call in CallRow(call: call) }
            }

            if let t = model.transfer, let consult = t.consult,
               let original = calls.first(where: { $0.id == t.original }),
               let consultCall = calls.first(where: { $0.id == consult }) {
                TransferBanner(original: original, consult: consultCall)
            }

            Spacer(minLength: 0)
            if let target {
                CallControlGrid(call: target)
                EndCallButton(title: L.callEndWith(model.name(for: target.remote))) { model.hangup(target.id) }
                    .keyboardShortcut("d", modifiers: .command)
                    .padding(.top, 2)
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct CallRow: View {
    @Environment(AppModel.self) private var model
    let call: CallInfo

    private var isConsulting: Bool { model.transfer?.consult == call.id }
    private var isWaiting: Bool { model.transfer?.original == call.id && model.transfer?.consult != nil }
    private var isActive: Bool { !call.isHeldCall }

    var body: some View {
        let name = model.name(for: call.remote)
        HStack(spacing: 8) {
            AvatarView(name: name, size: 26)
            VStack(alignment: .leading, spacing: 0) {
                Text(name).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                subtitle.font(.system(size: 11))
            }
            Spacer(minLength: 4)
            if isActive, !isConsulting, let codec = codecDisplay(call.codec) {
                Chip { Text(codec); SignalBars() }
            }
            if call.isHeldCall && !isWaiting {
                Button { model.toggleHold(call) } label: {
                    HStack(spacing: 3) { Image(systemName: "play.fill").font(.system(size: 8)); Text(L.callResume) }
                        .font(.system(size: 11.5))
                        .padding(.horizontal, 8).frame(height: 20)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.control))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.controlBorder, lineWidth: 0.5))
                }
                .buttonStyle(.plain)
            }
            MiniEndButton(help: L.callsEndHelp) { model.hangup(call.id) }
        }
        .padding(.horizontal, 8).padding(.vertical, 7)
        .frame(minHeight: 44)
        .background(RoundedRectangle(cornerRadius: 8).fill(isActive ? Theme.blueTint : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture { model.switchTo(call) }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var subtitle: some View {
        if isWaiting {
            Text(L.callsWaitingTransfer).foregroundStyle(Theme.orange).fontWeight(.medium)
        } else if isConsulting {
            TickingText { L.callsConsulting(elapsedText(call, at: $0)) }.foregroundStyle(Theme.blue).fontWeight(.medium)
        } else if call.isHeldCall {
            TickingText { L.callsHeld(elapsedText(call, at: $0)) }.foregroundStyle(Theme.orange).fontWeight(.medium)
        } else if call.isEstablished {
            TickingText { L.callsActive(elapsedText(call, at: $0)) }.foregroundStyle(Theme.blue).fontWeight(.medium)
        } else {
            Text(call.state == .early ? L.callRinging : L.callCalling).foregroundStyle(Theme.label2)
        }
    }
}

/// 5.3: "Transfer A to B?" with Cancel and Complete Transfer.
struct TransferBanner: View {
    @Environment(AppModel.self) private var model
    let original: CallInfo
    let consult: CallInfo

    var body: some View {
        let a = model.name(for: original.remote)
        let b = model.name(for: consult.remote)
        VStack(alignment: .leading, spacing: 7) {
            Text(L.transferBannerTitle(a, b)).font(.system(size: 12, weight: .bold))
            Text(L.transferBannerBody(first(a), first(b))).font(.system(size: 12)).foregroundStyle(Theme.label2)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Spacer()
                Button(L.commonCancel) { model.cancelTransfer() }.controlSize(.small)
                Button(L.transferComplete) { model.completeTransfer() }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!consult.isEstablished)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.fill))
    }

    private func first(_ name: String) -> String { name.split(separator: " ").first.map(String.init) ?? name }
}

/// 4.2 DTMF keypad.
struct DTMFKeypadView: View {
    @Environment(AppModel.self) private var model
    let call: CallInfo
    @FocusState private var focused: Bool

    private let rows: [[Character]] = [["1", "2", "3"], ["4", "5", "6"], ["7", "8", "9"], ["*", "0", "#"]]

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Button { model.showKeypad = false; model.dtmfSent = "" } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.left").font(.system(size: 11, weight: .bold))
                        Text(L.keypadBack).font(.system(size: 12.5, weight: .medium))
                    }
                    .foregroundStyle(Theme.blue)
                }
                .buttonStyle(.plain)
                Spacer()
                TickingText { L.keypadWho(model.name(for: call.remote), elapsedText(call, at: $0)) }
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.label2)
                    .lineLimit(1)
            }
            Text(model.dtmfSent.isEmpty ? " " : model.dtmfSent)
                .font(.system(size: 20, weight: .medium, design: .monospaced))
                .kerning(5)
                .lineLimit(1)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, minHeight: 24)
            VStack(spacing: 7) {
                ForEach(rows, id: \.self) { row in
                    HStack(spacing: 7) {
                        ForEach(row, id: \.self) { key in
                            Button { model.sendDTMF(key) } label: {
                                Text(String(key)).font(.system(size: 18))
                                    .frame(maxWidth: .infinity, minHeight: 38, maxHeight: .infinity)
                                    .contentShape(RoundedRectangle(cornerRadius: 9))
                            }
                            .buttonStyle(KeyStyle(cornerRadius: 9))
                        }
                    }
                }
            }
            EndCallButton(title: L.callEnd) { model.hangup(call.id) }
                .keyboardShortcut("d", modifiers: .command)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onAppear { focused = true }
        .onKeyPress(characters: CharacterSet(charactersIn: "0123456789*#"), phases: .down) { press in
            guard let ch = press.characters.first else { return .ignored }
            model.sendDTMF(ch)
            return .handled
        }
    }
}

/// 4.3 and 13: summary bar on the Contacts / Call Log tabs while any call exists.
struct CallSummaryBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.liveCalls.isEmpty, let incoming = model.incomingCall {
            HStack(spacing: 8) {
                Circle().fill(Theme.orange).frame(width: 7, height: 7)
                Text("\(L.callbarIncoming): \(model.name(for: incoming.remote))")
                    .font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 4)
                Button { model.decline(incoming.id) } label: {
                    Image(systemName: "phone.down.fill").font(.system(size: 10)).foregroundStyle(.white)
                        .frame(width: 22, height: 22).background(Circle().fill(Theme.red))
                }
                .buttonStyle(.plain).help(L.incomingDecline)
                Button { model.answer(incoming.id) } label: {
                    Image(systemName: "phone.fill").font(.system(size: 10)).foregroundStyle(.white)
                        .frame(width: 22, height: 22).background(Circle().fill(Theme.green))
                }
                .buttonStyle(.plain).help(L.incomingAnswer)
            }
            .padding(.horizontal, 10).frame(height: 28)
            .background(Theme.blueTint)
            .overlay(alignment: .bottom) { Divider() }
        } else if let call = model.currentCall {
            HStack(spacing: 8) {
                Circle().fill(call.isHeldCall ? Theme.orange : Theme.green).frame(width: 7, height: 7)
                    .overlay(Circle().stroke((call.isHeldCall ? Theme.orange : Theme.green).opacity(0.25), lineWidth: 3))
                Text(model.name(for: call.remote)).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                LiveElapsed(call: call).font(.system(size: 12)).foregroundStyle(Theme.label2)
                if call.isMuted {
                    Image(systemName: "mic.slash.fill").font(.system(size: 10)).foregroundStyle(Theme.red).help(L.callbarMuted)
                }
                if model.heldCount > (call.isHeldCall ? 1 : 0) {
                    Text(L.callbarMoreHeld(model.heldCount - (call.isHeldCall ? 1 : 0)))
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.orange).lineLimit(1)
                }
                Spacer(minLength: 4)
                MiniEndButton(help: L.callEnd) { model.hangup(call.id) }
            }
            .padding(.horizontal, 10).frame(height: 28)
            .background(Theme.blueTint)
            .overlay(alignment: .bottom) { Divider() }
            .contentShape(Rectangle())
            .onTapGesture { model.tab = .dialpad }
            .help(L.callbarHelp)
            .accessibilityElement(children: .combine)
            .accessibilityHint(L.callbarHelp)
        }
    }
}
