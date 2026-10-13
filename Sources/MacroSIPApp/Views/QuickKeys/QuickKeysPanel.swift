import SwiftUI
import MacroSIPCore

/// Screen 11: speed-dial and BLF panel. `.right` is a 220 pt column beside the main window, `.bottom` a
/// 3-column strip under the status bar (two rows visible, the rest scrolls).
struct QuickKeysPanel: View {
    enum Placement { case side, dock }
    @Environment(AppModel.self) private var model
    let placement: Placement

    static let sideWidth: CGFloat = 220
    static let dockHeight: CGFloat = 92

    var body: some View {
        VStack(spacing: 0) {
            header
            switch placement {
            case .side: sideList
            case .dock: dockGrid
            }
        }
        .frame(width: placement == .side ? Self.sideWidth : nil, height: placement == .side ? nil : Self.dockHeight)
        .frame(maxWidth: placement == .side ? nil : .infinity, maxHeight: placement == .side ? .infinity : nil, alignment: .top)
        .background(Theme.content)
        .overlay(alignment: placement == .side ? .leading : .top) {
            Rectangle().fill(Theme.separator)
                .frame(width: placement == .side ? 0.5 : nil, height: placement == .side ? nil : 0.5)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L.quickKeysTitle)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(L.quickKeysTitle).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.label2)
            Spacer(minLength: 0)
            Button { model.openQuickKeysSettings() } label: {
                Image(systemName: "gearshape").font(.system(size: 12, weight: .medium))
                    .frame(width: 22, height: 20).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.label2)
            .help(L.menuSettings)
            .accessibilityLabel(L.menuSettings)
        }
        .padding(.leading, 10).padding(.trailing, 6)
        .frame(height: 26)
    }

    private var sideList: some View {
        let keys = model.quickKeyList
        return ScrollView {
            VStack(spacing: 3) {
                ForEach(Array(keys.enumerated()), id: \.element.id) { index, key in
                    QuickKeyButton(key: key, index: index, compact: false)
                }
                ForEach(0..<max(0, QuickKeysSettings.maxKeys - keys.count), id: \.self) { _ in
                    EmptyQuickKeySlot(title: L.quickKeysAdd, compact: false)
                }
            }
            .padding(.horizontal, 6).padding(.top, 6).padding(.bottom, 8)
        }
        .scrollIndicators(.automatic)
    }

    private var dockGrid: some View {
        let keys = model.quickKeyList
        let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 3)
        return ScrollView {
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(Array(keys.enumerated()), id: \.element.id) { index, key in
                    QuickKeyButton(key: key, index: index, compact: true)
                }
                if keys.count < QuickKeysSettings.maxKeys {
                    EmptyQuickKeySlot(title: L.quickKeysAddShort, compact: true)
                }
            }
            .padding(.horizontal, 10).padding(.top, 2).padding(.bottom, 8)
        }
        .scrollIndicators(.automatic)
    }
}

/// A dashed slot that opens Settings › Quick keys on a new row.
struct EmptyQuickKeySlot: View {
    @Environment(AppModel.self) private var model
    let title: String
    let compact: Bool

    var body: some View {
        Button { model.openQuickKeysSettings(newKey: true) } label: {
            HStack(spacing: 4) {
                Image(systemName: "plus").font(.system(size: compact ? 9 : 10, weight: .semibold))
                Text(title).font(.system(size: compact ? 11.5 : 12)).lineLimit(1)
            }
            .foregroundStyle(Theme.label2)
            .frame(maxWidth: .infinity)
            .frame(height: compact ? 28 : 32)
            .background(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.label3, style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

struct QuickKeyButton: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let key: QuickKey
    let index: Int
    let compact: Bool
    @Local private var hovering = false

    var body: some View {
        let state = model.quickKeyState(key)
        let enabled = model.quickKeyEnabled(key)
        let ringing = state == .ringing
        Button { model.pressQuickKey(key) } label: {
            HStack(spacing: compact ? 5 : 7) {
                if let state {
                    BLFDot(state: state, size: compact ? 7 : 9, animated: !reduceMotion)
                } else if !compact {
                    Color.clear.frame(width: 8, height: 8)
                }
                if compact {
                    Text(key.title).font(.system(size: 11.5, weight: .medium)).lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 0)
                } else {
                    // The name goes last: when the line is too narrow the "· ringing" suffix drops first, then
                    // the number (the orange tint and the tooltip still say it), and only then the name shortens.
                    ViewThatFits(in: .horizontal) {
                        titleLine(subtitle: ringing ? "\(key.trimmedNumber) · \(L.quickKeysRinging)" : key.trimmedNumber, ringing: ringing)
                        if ringing { titleLine(subtitle: key.trimmedNumber, ringing: ringing) }
                        titleLine(subtitle: nil, ringing: ringing)
                    }
                    Spacer(minLength: 0)
                    QuickKeyGlyph(type: key.type, size: 12)
                        .foregroundStyle(Theme.label2)
                }
            }
            .padding(.horizontal, compact ? 6 : 8)
            .frame(maxWidth: .infinity)
            .frame(height: compact ? 28 : 32)
            .background(RoundedRectangle(cornerRadius: 7).fill(background(ringing: ringing)))
            .overlay {
                if ringing { RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.orange.opacity(0.6), lineWidth: 0.5) }
            }
            .contentShape(Rectangle())
            .opacity(enabled ? 1 : 0.45)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hovering = $0 }
        .help(tooltip(state: state))
        .accessibilityLabel(accessibilityText(state: state))
        .contextMenu {
            Button(L.quickKeysEdit) { model.openQuickKeysSettings(editing: key) }
            Button(L.quickKeysRemove) { model.removeQuickKey(key.id) }
        }
    }

    private func titleLine(subtitle: String?, ringing: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(key.title).font(.system(size: 12.5, weight: .medium)).lineLimit(1).truncationMode(.tail)
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 11)).monospacedDigit()
                    .foregroundStyle(ringing ? Theme.orange : Theme.label2)
                    .fontWeight(ringing ? .medium : .regular)
                    .lineLimit(1)
            }
        }
    }

    private func background(ringing: Bool) -> Color {
        if ringing { return Theme.orange.opacity(0.16) }
        return hovering ? Theme.fill2 : Theme.fill
    }

    private func tooltip(state: QuickKeyLineState?) -> String {
        var first = [key.title]
        if !key.trimmedNumber.isEmpty, key.title != key.trimmedNumber { first.append(key.trimmedNumber) }
        if let state { first.append(model.quickKeyStateText(key, state: state)) }
        var second = [L.quickKeyTypeName(key.type)]
        if let s = model.quickKeyShortcut(at: index) { second.append(s) }
        return first.joined(separator: " · ") + "\n" + second.joined(separator: " · ")
    }

    private func accessibilityText(state: QuickKeyLineState?) -> String {
        [key.title, key.trimmedNumber, state.map { model.quickKeyStateText(key, state: $0) }, L.quickKeyTypeName(key.type)]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
    }
}

/// BLF dot: green available, red on the phone, orange blinking ringing, grey no information.
struct BLFDot: View {
    let state: QuickKeyLineState
    var size: CGFloat = 9
    var animated = true

    var body: some View {
        if state == .ringing && animated {
            TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
                dot.opacity(Int(ctx.date.timeIntervalSinceReferenceDate * 2) % 2 == 0 ? 1 : 0.15)
            }
        } else {
            dot
        }
    }

    private var dot: some View {
        Circle().fill(color).frame(width: size, height: size).accessibilityHidden(true)
    }

    private var color: Color {
        switch state {
        case .available: return Theme.green
        case .busy: return Theme.red
        case .ringing: return Theme.orange
        case .unknown: return Color.primary.opacity(0.28)
        }
    }
}

/// The glyph of a key type: handset for Call, # for DTMF, arrows for transfers, people for conference; the
/// smart types show the handset, a slash and the glyph of what they do in a call.
struct QuickKeyGlyph: View {
    let type: QuickKeyType
    var size: CGFloat = 12

    var body: some View {
        HStack(spacing: 1) {
            switch type {
            case .call: handset
            case .dtmf: Text("#").font(.system(size: size, weight: .semibold, design: .monospaced))
            case .blindTransfer, .attendedTransfer: arrows
            case .conference: people
            case .smartBlindTransfer, .smartAttendedTransfer:
                handset; slash; arrows
            case .smartConference:
                handset; slash; people
            }
        }
        .accessibilityHidden(true)
    }

    private var handset: some View { Image(systemName: "phone.fill").font(.system(size: size * 0.85)) }
    private var arrows: some View { Image(systemName: "arrow.left.arrow.right").font(.system(size: size * 0.9, weight: .medium)) }
    private var people: some View { Image(systemName: "person.2").font(.system(size: size * 0.95)) }
    private var slash: some View { Text("/").font(.system(size: size * 0.8)).opacity(0.6).padding(.horizontal, 1) }
}

extension L {
    static func quickKeyTypeName(_ type: QuickKeyType) -> String {
        switch type {
        case .call: return quickKeysTypeCall
        case .dtmf: return quickKeysTypeDTMF
        case .blindTransfer: return quickKeysTypeBlind
        case .attendedTransfer: return quickKeysTypeAttended
        case .conference: return quickKeysTypeConference
        case .smartBlindTransfer: return quickKeysTypeCallBlind
        case .smartAttendedTransfer: return quickKeysTypeCallAttended
        case .smartConference: return quickKeysTypeCallConference
        }
    }

    static func quickKeyStateName(_ state: QuickKeyLineState) -> String {
        switch state {
        case .available: return quickKeysBlfAvailable
        case .busy: return quickKeysBlfBusy
        case .ringing: return quickKeysBlfRinging
        case .unknown: return quickKeysBlfUnknown
        }
    }
}
