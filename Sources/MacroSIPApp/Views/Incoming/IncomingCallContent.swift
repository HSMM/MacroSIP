import SwiftUI
import MacroSIPCore

/// Shared layout of SCREENS.md 6.1 (floating panel), 6.4 (in the main window) and 6.6 (while on a call).
struct IncomingCallContent: View {
    @Environment(AppModel.self) private var model
    let call: CallInfo
    let inPanel: Bool

    private var otherCall: CallInfo? { model.liveCalls.first }

    var body: some View {
        let name = model.name(for: call.remote)
        VStack(spacing: inPanel ? 12 : 10) {
            if !inPanel { Spacer(minLength: 0) }
            HStack(spacing: 12) {
                AvatarView(name: name, size: 48, contact: model.contact(for: call.remote))
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Button { model.silenceRingtone(call.id) } label: {
                            Image(systemName: model.ringtoneSilenced.contains(call.id) ? "bell.slash.fill" : "bell.fill")
                                .font(.system(size: 10))
                        }
                        .buttonStyle(.plain)
                        .help(L.audioRingtoneHeader)
                        .accessibilityLabel(L.audioRingtoneHeader)
                        Text(L.incomingEyebrow(model.accountName(call.accountID)))
                            .lineLimit(1)
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.label2)
                    Text(name).font(.system(size: 17, weight: .semibold)).lineLimit(1)
                    Text(call.remote.number).font(.system(size: 12.5)).foregroundStyle(Theme.label2).lineLimit(1)
                    if !inPanel {
                        Text(L.incomingStateRinging).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.orange)
                    }
                }
                Spacer(minLength: 0)
            }
            if let countdown = model.autoAnswer[call.id] {
                AutoAnswerStrip(countdown: countdown) { model.cancelAutoAnswer(call.id) }
            }
            if let other = otherCall {
                TickingText { L.incomingOnCall(model.name(for: other.remote), elapsedText(other, at: $0)) }
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.label2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 10) {
                    declineButton
                    answerButton(title: L.incomingHoldAnswer, font: 12)
                }
                Button { model.endCurrentAndAnswer(call.id) } label: {
                    Text(L.incomingEndAnswer).font(.system(size: 12.5, weight: .medium))
                        .frame(maxWidth: .infinity, minHeight: 30)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.control))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.controlBorder, lineWidth: 0.5))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                HStack(spacing: 10) {
                    declineButton
                    answerButton(title: L.incomingAnswer, font: 13)
                }
            }
            if !inPanel { Spacer(minLength: 0) }
        }
        .padding(inPanel ? EdgeInsets(top: 14, leading: 16, bottom: 16, trailing: 16) : EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16))
        .frame(maxWidth: .infinity, maxHeight: inPanel ? nil : .infinity)
        .onKeyPress(.escape) {
            model.silenceRingtone(call.id)
            return .handled
        }
    }

    private var declineButton: some View {
        Button { model.decline(call.id) } label: {
            actionLabel(symbol: "phone.down.fill", title: L.incomingDecline, color: Theme.red, font: 13)
        }
        .buttonStyle(.plain)
        .keyboardShortcut(".", modifiers: .command)
    }

    private func answerButton(title: String, font: CGFloat) -> some View {
        Button { model.answer(call.id) } label: {
            actionLabel(symbol: "phone.fill", title: title, color: Theme.green, font: font)
        }
        .buttonStyle(.plain)
        .modifier(AnswerShortcut(command: inPanel, enabled: inPanel || !model.incomingKeyGuard))
    }

    private func actionLabel(symbol: String, title: String, color: Color, font: CGFloat) -> some View {
        HStack(spacing: 7) {
            Image(systemName: symbol).font(.system(size: 14))
            Text(title).font(.system(size: font, weight: .semibold)).lineLimit(1)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, minHeight: 34, maxHeight: 34)
        .background(RoundedRectangle(cornerRadius: 9).fill(color))
        .contentShape(Rectangle())
    }
}

/// Content of the floating NSPanel.
struct IncomingCallPanelView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if let call = model.incomingCall {
                IncomingCallContent(call: call, inPanel: true)
            }
        }
        .frame(width: 300)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
    }
}

/// 6.5: countdown ring, "Auto-answer in N s", Cancel.
struct AutoAnswerStrip: View {
    let countdown: AutoAnswerCountdown
    let cancel: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { ctx in
            let remaining = max(0, countdown.fireAt.timeIntervalSince(ctx.date))
            let progress = countdown.total > 0 ? remaining / countdown.total : 0
            HStack(spacing: 8) {
                ZStack {
                    Circle().stroke(Theme.fill3, lineWidth: 2.5)
                    Circle().trim(from: 0, to: progress)
                        .stroke(Theme.green, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: 22, height: 22)
                Text(L.autoAnswerCountdown(Int(remaining.rounded(.up)))).font(.system(size: 12.5)).monospacedDigit()
                Spacer(minLength: 4)
                Button(L.autoAnswerCancel, action: cancel)
                    .buttonStyle(.plain)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.blue)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.fill))
        }
    }
}

/// Return (Command-Return in the floating window) answers; off while a call has brought the window forward
/// and the user has not clicked into it yet.
private struct AnswerShortcut: ViewModifier {
    let command: Bool
    let enabled: Bool

    @ViewBuilder func body(content: Content) -> some View {
        if enabled { content.keyboardShortcut(.return, modifiers: command ? .command : []) } else { content }
    }
}
