import SwiftUI
import MacroSIPCore

/// "opus/48000/2" -> "Opus 48 kHz".
func codecDisplay(_ id: String?) -> String? {
    guard let id else { return nil }
    let parts = id.split(separator: "/")
    guard let name = parts.first else { return nil }
    let pretty: String
    switch name.lowercased() {
    case "opus": pretty = "Opus"
    case "g722": pretty = "G.722"
    default: pretty = String(name).uppercased()
    }
    if parts.count > 1, let hz = Double(parts[1]) {
        let khz = hz / 1000
        let value = String(format: khz.rounded() == khz ? "%.0f" : "%.1f", khz)
        return "\(pretty) \(L.unitKHz(value))"
    }
    return pretty
}

func elapsedText(_ call: CallInfo, at now: Date = Date()) -> String {
    guard let start = call.startedAt else { return "00:00" }
    return formatDuration(now.timeIntervalSince(start))
}

struct LiveElapsed: View {
    let call: CallInfo
    var body: some View {
        if call.startedAt == nil { Text("00:00").monospacedDigit() }
        else { TickingText { elapsedText(call, at: $0) } }
    }
}

/// Signal bars. No RTCP numbers reach the UI yet, so 3 of 4 bars are drawn (see report).
struct SignalBars: View {
    var level = 3
    var body: some View {
        HStack(alignment: .bottom, spacing: 1.5) {
            ForEach(0..<4, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(i < level ? Theme.green : Theme.fill3)
                    .frame(width: 2.5, height: [3, 5, 7.5, 10][i])
            }
        }
        .frame(height: 10)
    }
}

struct Chip<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        HStack(spacing: 4) { content }
            .font(.system(size: 11))
            .foregroundStyle(Theme.label2)
            .padding(.horizontal, 6)
            .frame(height: 17)
            .background(RoundedRectangle(cornerRadius: 5).fill(Theme.fill))
    }
}

struct EndCallButton: View {
    let title: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: "phone.down.fill").font(.system(size: 14))
                Text(title).font(.system(size: 13, weight: .medium)).lineLimit(1)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 30, maxHeight: 30)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.red))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

/// Chips that wrap onto a second line when they do not fit, centred.
struct ChipFlow: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 4

    private func lines(_ subviews: Subviews, width: CGFloat) -> [[Int]] {
        var result: [[Int]] = [[]]
        var x: CGFloat = 0
        for (i, v) in subviews.enumerated() {
            let w = v.sizeThatFits(.unspecified).width
            if x > 0, x + w > width { result.append([]); x = 0 }
            result[result.count - 1].append(i)
            x += w + spacing
        }
        return result
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = lines(subviews, width: width)
        let height = rows.reduce(CGFloat(0)) { acc, row in
            acc + (row.map { subviews[$0].sizeThatFits(.unspecified).height }.max() ?? 0)
        } + lineSpacing * CGFloat(max(0, rows.count - 1))
        let used = rows.map { row in row.reduce(CGFloat(0)) { $0 + subviews[$1].sizeThatFits(.unspecified).width } + spacing * CGFloat(max(0, row.count - 1)) }.max() ?? 0
        return CGSize(width: proposal.width ?? used, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in lines(subviews, width: bounds.width) {
            let sizes = row.map { subviews[$0].sizeThatFits(.unspecified) }
            let total = sizes.reduce(CGFloat(0)) { $0 + $1.width } + spacing * CGFloat(max(0, row.count - 1))
            var x = bounds.midX - total / 2
            for (k, i) in row.enumerated() {
                subviews[i].place(at: CGPoint(x: x, y: y), proposal: .unspecified)
                x += sizes[k].width + spacing
            }
            y += (sizes.map(\.height).max() ?? 0) + lineSpacing
        }
    }
}

/// Red "REC 00:12" pill (SCREENS.md 4.1) with a white dot.
struct RecChip: View {
    let since: Date?
    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(.white).frame(width: 5, height: 5)
            if let since { TickingText { L.callRecChip(formatDuration($0.timeIntervalSince(since))) } }
            else { Text(L.callRecShort) }
        }
        .font(.system(size: 10.5, weight: .semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 7)
        .frame(height: 17)
        .background(Capsule().fill(Theme.red))
        .accessibilityLabel(L.callRecShort)
    }
}

struct CallControlButton: View {
    let symbol: String
    let title: String
    var isOn = false
    var onColor: Color?             // filled circle colour when on; default inverse of the label colour
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 16))
                    .foregroundStyle(isOn ? (onColor != nil ? Color.white : Theme.content) : Color.primary)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(isOn ? (onColor ?? Color.primary) : Theme.fill2))
                Text(title).font(.system(size: 10.5)).foregroundStyle(.primary).lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// Mute, Hold, Transfer, Keypad, Record, Merge in three columns. Acts on `call`.
struct CallControlGrid: View {
    @Environment(AppModel.self) private var model
    let call: CallInfo
    @Local private var showTransfer = false

    var body: some View {
        let ready = call.isEstablished
        let legs = model.legs(of: call)
        let recording = legs.contains(where: \.isRecording)
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 3), spacing: 10) {
            CallControlButton(symbol: call.isMuted ? "mic.slash.fill" : "mic.fill", title: L.callMute,
                              isOn: call.isMuted, enabled: ready) { model.toggleMute(call) }
            CallControlButton(symbol: call.isHeldCall ? "play.fill" : "pause.fill",
                              title: call.isHeldCall ? L.callResume : L.callHold,
                              isOn: false, enabled: ready) { model.toggleHold(call) }
            CallControlButton(symbol: "phone.arrow.right", title: L.callTransfer,
                              isOn: showTransfer, enabled: ready && model.transfer == nil && !call.inConference) { showTransfer = true }
                .popover(isPresented: $showTransfer, arrowEdge: .top) {
                    TransferPopover(call: call) { showTransfer = false }
                }
            CallControlButton(symbol: "circle.grid.3x3.fill", title: L.callKeypad, enabled: ready) {
                model.showKeypad = true
            }
            CallControlButton(symbol: "record.circle", title: L.callRecord, isOn: recording, onColor: Theme.red,
                              enabled: ready) { model.toggleRecording(call) }
            CallControlButton(symbol: "arrow.triangle.merge", title: L.callMerge, enabled: model.canMerge) { model.mergeCalls() }
        }
    }
}
