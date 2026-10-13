import SwiftUI
import MacroSIPCore

/// 8.5 Codecs: reorderable list with check boxes. Opus, G.722, PCMU and PCMA are on or off as before; G.722.1, GSM, iLBC
/// and Speex (26.2) are listed after them and off until the user turns them on.
struct CodecsPane: View {
    @Environment(AppModel.self) private var model
    @Local private var selection: String?

    private struct Meta { let name: String; let rate: String; let bitrate: String }
    private func meta(_ id: String) -> Meta {
        switch id {
        case "opus/48000/2": return Meta(name: "Opus", rate: L.unitKHz("48"), bitrate: L.unitKbps("6–510"))
        case "G722/16000/1": return Meta(name: "G.722", rate: L.unitKHz("16"), bitrate: L.unitKbps("64"))
        case "PCMU/8000/1": return Meta(name: L.codecsPCMU, rate: L.unitKHz("8"), bitrate: L.unitKbps("64"))
        case "PCMA/8000/1": return Meta(name: L.codecsPCMA, rate: L.unitKHz("8"), bitrate: L.unitKbps("64"))
        case "G7221/16000/1": return Meta(name: "G.722.1 (Siren 7)", rate: L.unitKHz("16"), bitrate: L.unitKbps("16–32"))
        case "G7221/32000/1": return Meta(name: "G.722.1C (Siren 14)", rate: L.unitKHz("32"), bitrate: L.unitKbps("24–48"))
        case "GSM/8000/1": return Meta(name: "GSM", rate: L.unitKHz("8"), bitrate: L.unitKbps("13"))
        case "iLBC/8000/1": return Meta(name: "iLBC", rate: L.unitKHz("8"), bitrate: L.unitKbps("13–15"))
        case "speex/8000/1": return Meta(name: "Speex 8 kHz", rate: L.unitKHz("8"), bitrate: L.unitKbps("2–25"))
        case "speex/16000/1": return Meta(name: "Speex 16 kHz", rate: L.unitKHz("16"), bitrate: L.unitKbps("4–42"))
        case "speex/32000/1": return Meta(name: "Speex 32 kHz", rate: L.unitKHz("32"), bitrate: L.unitKbps("4–44"))
        default: return Meta(name: id, rate: "", bitrate: "")
        }
    }

    /// Every codec the pane knows, in the stored order; those the stored list lacks (settings from before 26.2) come last.
    private var order: [String] { CodecCatalog.rows(model.settings.codecOrder) }
    private var enabled: Set<String> { model.settings.enabledCodecs }

    var body: some View {
        PaneContainer {
            FormGroup(header: L.codecsHeader) {
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
                                model.updateSettings { s in
                                    var rows = CodecCatalog.rows(s.codecOrder)
                                    rows.move(fromOffsets: from, toOffset: to)
                                    s.codecOrder = rows
                                }
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
            } footerView: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L.codecsFooter)
                    Text(L.codecsWidebandNote)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            FormGroup(header: L.codecsOpusHeader, footer: L.codecsOpusFooter) {
                FormRow(label: L.codecsOpusFEC) { optionToggle(\.opusFEC) }
                FormDivider()
                FormRow(label: L.codecsOpusDTX) { optionToggle(\.opusDTX) }
            }
        }
    }

    private func optionToggle(_ keyPath: WritableKeyPath<CodecOptions, Bool> & Sendable) -> some View {
        Toggle("", isOn: Binding(
            get: { MainActor.assumeIsolated { model.settings.codecOptions[keyPath: keyPath] } },
            set: { v in MainActor.assumeIsolated { model.updateSettings { $0.codecOptions[keyPath: keyPath] = v } } }))
            .labelsHidden().toggleStyle(.switch)
            .disabled(!enabled.contains("opus/48000/2"))
    }

    private func row(_ id: String) -> some View {
        let m = meta(id)
        let isOn = enabled.contains(id)
        let isLast = isOn && enabled.count == 1
        return HStack(spacing: 10) {
            Toggle("", isOn: Binding(
                get: { isOn },
                set: { on in model.updateSettings {
                    $0.codecOrder = CodecCatalog.rows($0.codecOrder)
                    if on { $0.enabledCodecs.insert(id) } else { $0.enabledCodecs.remove(id) }
                } }))
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
        model.updateSettings { s in
            var rows = CodecCatalog.rows(s.codecOrder)
            rows.swapAt(i, i + delta)
            s.codecOrder = rows
        }
    }

    /// Spec default: Opus, G.722, PCMU on; PCMA and the 26.2 codecs off.
    private func restore() {
        model.updateSettings {
            $0.codecOrder = CodecCatalog.rows(AppSettings.defaultCodecOrder)
            $0.enabledCodecs = CodecCatalog.onByDefault
        }
    }
}

/// The codecs of Settings › Codecs and which of them are on in a new installation.
enum CodecCatalog {
    static let all = AppSettings.defaultCodecOrder + [
        "G7221/16000/1", "G7221/32000/1", "GSM/8000/1", "iLBC/8000/1", "speex/8000/1", "speex/16000/1", "speex/32000/1",
    ].filter { !AppSettings.defaultCodecOrder.contains($0) }
    static let onByDefault: Set<String> = ["opus/48000/2", "G722/16000/1", "PCMU/8000/1"]

    /// `stored` with the known codecs it lacks appended; ids the pane does not know are dropped.
    static func rows(_ stored: [String]) -> [String] {
        let known = stored.filter(all.contains)
        return known + all.filter { !known.contains($0) }
    }
}
