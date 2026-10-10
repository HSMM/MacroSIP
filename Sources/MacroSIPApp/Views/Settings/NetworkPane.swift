import SwiftUI

/// 8.4 Network: STUN, local port, keep-alive, ICE. Port changes restart the engine (re-register).
struct NetworkPane: View {
    @Environment(AppModel.self) private var model
    @Local private var stun = ""
    @FocusState private var stunFocused: Bool

    var body: some View {
        let net = model.settings.network
        PaneContainer {
            FormGroup(header: L.netConnectionHeader) {
                FormRow(label: L.netSTUN, help: L.netSTUNHelp) {
                    TextField("stun.example.org:3478", text: $stun)
                        .textFieldStyle(.plain)
                        .focused($stunFocused)
                        .padding(.horizontal, 7).frame(width: 220, height: 24)
                        .fieldBackground(focused: stunFocused)
                        .onSubmit { commitSTUN() }
                        .onChange(of: stunFocused) { _, f in if !f { commitSTUN() } }
                }
                FormDivider()
                FormRow(label: L.netPort, help: L.netPortHelp) {
                    NumberStepperField(
                        value: Binding(get: { Int(net.localPort) }, set: { v in model.updateSettings { $0.network.localPort = UInt16(v) } }),
                        width: 70,
                        isValid: { $0 == 0 || (1024...65535).contains($0) },
                        step: { cur, dir in
                            if dir > 0 { return cur == 0 ? 1024 : min(65535, cur + 1) }
                            return cur <= 1024 ? 0 : cur - 1
                        })
                }
                FormDivider()
                FormRow(label: L.netKeepAlive, help: L.netKeepAliveHelp) {
                    HStack(spacing: 6) {
                        NumberStepperField(
                            value: Binding(get: { net.keepAliveSeconds }, set: { v in model.updateSettings { $0.network.keepAliveSeconds = v } }),
                            width: 50,
                            isValid: { $0 == 0 || (5...600).contains($0) },
                            step: { cur, dir in
                                if dir > 0 { return cur == 0 ? 5 : min(600, cur + 1) }
                                return cur <= 5 ? 0 : cur - 1
                            })
                        Text(L.unitSeconds).font(.system(size: 12)).foregroundStyle(Theme.label2)
                    }
                }
                FormDivider()
                FormRow(label: L.netICE, help: L.netICEHelp) {
                    Toggle("", isOn: model.binding(\.network.useICE)).labelsHidden().toggleStyle(.switch)
                }
            }
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "info.circle").foregroundStyle(Theme.label2)
                Text(L.netFooter).font(.system(size: 11.5)).foregroundStyle(Theme.label2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 10)
        }
        .onAppear { stun = net.stunServer ?? "" }
    }

    private func commitSTUN() {
        let v = stun.trimmingCharacters(in: .whitespaces)
        model.updateSettings { $0.network.stunServer = v.isEmpty ? nil : v }
    }
}
