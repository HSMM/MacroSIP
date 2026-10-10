import SwiftUI
import MacroSIPCore

/// 8.5 Codecs: reorderable list with check boxes. Only Opus, G.722, PCMU and PCMA are shown.
struct CodecsPane: View {
    @Environment(AppModel.self) private var model
    @Local private var selection: String?

    private struct Meta { let name: String; let rate: String; let bitrate: String }
    private func meta(_ id: String) -> Meta {
        switch id {
        case "opus/48000/2": return Meta(name: "Opus", rate: "48 kHz", bitrate: "6–510 kbit/s")
        case "G722/16000/1": return Meta(name: "G.722", rate: "16 kHz", bitrate: "64 kbit/s")
        case "PCMU/8000/1": return Meta(name: L.codecsPCMU, rate: "8 kHz", bitrate: "64 kbit/s")
        case "PCMA/8000/1": return Meta(name: L.codecsPCMA, rate: "8 kHz", bitrate: "64 kbit/s")
        default: return Meta(name: id, rate: "", bitrate: "")
        }
    }

    private var order: [String] { model.settings.codecOrder }
    private var enabled: Set<String> { model.settings.enabledCodecs }

    var body: some View {
        PaneContainer {
            FormGroup(header: L.codecsHeader, footer: L.codecsFooter) {
                VStack(spacing: 0) {
                    HStack(spacing: 10) {
                        Color.clear.frame(width: 18)
                        Text(L.codecsColCodec).frame(maxWidth: .infinity, alignment: .leading)
                        Text(L.codecsColRate).frame(width: 90, alignment: .leading)
                        Text(L.codecsColBitrate).frame(width: 90, alignment: .leading)
                        Color.clear.frame(width: 16)
                    }
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.label2)
                    .padding(.horizontal, 20).frame(height: 24)
                    Divider()
                    List(selection: $selection) {
                        ForEach(order, id: \.self) { id in
                            row(id).tag(id).listRowInsets(EdgeInsets()).listRowSeparator(.hidden)
                        }
                            .onMove { from, to in
                                model.updateSettings { $0.codecOrder.move(fromOffsets: from, toOffset: to) }
                            }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .frame(height: CGFloat(order.count) * 30 + 8)
                    Divider()
                    HStack(spacing: 0) {
                        IconButton(systemName: "chevron.up", help: L.codecsMoveUp) { move(-1) }
                            .disabled(!canMove(-1)).opacity(canMove(-1) ? 1 : 0.4)
                        IconButton(systemName: "chevron.down", help: L.codecsMoveDown) { move(1) }
                            .disabled(!canMove(1)).opacity(canMove(1) ? 1 : 0.4)
                        Spacer()
                        Button(L.codecsRestore) { restore() }.controlSize(.small)
                    }
                    .padding(.horizontal, 6).padding(.vertical, 4)
                }
            }
        }
    }

    private func row(_ id: String) -> some View {
        let m = meta(id)
        let isOn = enabled.contains(id)
        let isLast = isOn && enabled.count == 1
        return HStack(spacing: 10) {
            Toggle("", isOn: Binding(
                get: { isOn },
                set: { on in model.updateSettings { if on { $0.enabledCodecs.insert(id) } else { $0.enabledCodecs.remove(id) } } }))
                .labelsHidden()
                .toggleStyle(.checkbox)
                .disabled(isLast)
                .frame(width: 18)
            Text(m.name).frame(maxWidth: .infinity, alignment: .leading).lineLimit(1)
            Text(m.rate).monospacedDigit().foregroundStyle(Theme.label2).frame(width: 90, alignment: .leading)
            Text(m.bitrate).foregroundStyle(Theme.label2).frame(width: 90, alignment: .leading)
            Image(systemName: "line.3.horizontal").foregroundStyle(Theme.label3).frame(width: 16)
        }
        .font(.system(size: 12.5))
        .padding(.horizontal, 12).frame(height: 30)
        .opacity(isOn ? 1 : 0.7)
    }

    private func canMove(_ delta: Int) -> Bool {
        guard let s = selection, let i = order.firstIndex(of: s) else { return false }
        return order.indices.contains(i + delta)
    }

    private func move(_ delta: Int) {
        guard let s = selection, let i = order.firstIndex(of: s), order.indices.contains(i + delta) else { return }
        model.updateSettings { $0.codecOrder.swapAt(i, i + delta) }
    }

    /// Spec default: Opus, G.722, PCMU on; PCMA off.
    private func restore() {
        model.updateSettings {
            $0.codecOrder = AppSettings.defaultCodecOrder
            $0.enabledCodecs = Set(AppSettings.defaultCodecOrder).subtracting(["PCMA/8000/1"])
        }
    }
}
