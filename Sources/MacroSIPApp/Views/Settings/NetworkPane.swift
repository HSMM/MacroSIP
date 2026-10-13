import SwiftUI
import MacroSIPCore

/// 8.4 Network: STUN, local port, keep-alive, ICE, RTP port range, rport, DNS. What the running engine cannot change
/// (port range, DNS...) waits for "Restart now" (the engine stops and starts again, accounts register again).
struct NetworkPane: View {
    @Environment(AppModel.self) private var model
    @Local private var stun = ""
    @Local private var nameserver = ""
    @FocusState private var stunFocused: Bool
    @FocusState private var nameserverFocused: Bool

    var body: some View {
        let net = model.settings.network
        PaneContainer {
            if model.networkRestartNeeded { restartBanner }
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
            FormGroup(header: L.netRTPHeader) {
                FormRow(label: L.netRTPPortRange, help: L.netRTPPortRangeHelp) {
                    HStack(spacing: 6) {
                        Text(L.netRTPStart).font(.system(size: 12)).foregroundStyle(Theme.label2)
                        NumberStepperField(
                            value: Binding(get: { Int(net.rtpPortStart) }, set: { v in model.updateSettings { $0.network.rtpPortStart = .init(clamping: v) } }),
                            width: 56,
                            isValid: { RTPRange.validStart($0, count: Int(net.rtpPortCount)) },
                            step: { cur, dir in RTPRange.clampStart(cur + dir, count: Int(net.rtpPortCount)) })
                        Text(L.netRTPCount).font(.system(size: 12)).foregroundStyle(Theme.label2).padding(.leading, 6)
                        NumberStepperField(
                            value: Binding(get: { Int(net.rtpPortCount) }, set: { v in model.updateSettings { $0.network.rtpPortCount = .init(clamping: v) } }),
                            width: 56,
                            isValid: { RTPRange.validCount($0, start: Int(net.rtpPortStart)) },
                            step: { cur, dir in RTPRange.clampCount(cur + dir, start: Int(net.rtpPortStart)) })
                    }
                }
                FormDivider()
                FormRow(label: L.netRport, help: L.netRportHelp) {
                    Toggle("", isOn: model.binding(\.network.useRport)).labelsHidden().toggleStyle(.switch)
                }
            }
            FormGroup(header: L.netDNSHeader) {
                FormRow(label: L.netDNSSRV, help: L.netDNSSRVHelp) {
                    Toggle("", isOn: model.binding(\.network.dnsSRV)).labelsHidden().toggleStyle(.switch)
                }
                FormDivider()
                FormRow(label: L.netNameserver, help: L.netNameserverHelp) {
                    TextField(L.netNameserverPlaceholder, text: $nameserver)
                        .textFieldStyle(.plain)
                        .focused($nameserverFocused)
                        .padding(.horizontal, 7).frame(width: 220, height: 24)
                        .fieldBackground(focused: nameserverFocused)
                        .onSubmit { commitNameserver() }
                        .onChange(of: nameserverFocused) { _, f in if !f { commitNameserver() } }
                }
                .disabled(!net.dnsSRV)
                .opacity(net.dnsSRV ? 1 : 0.5)
            }
            VStack(alignment: .leading, spacing: 6) {
                note(L.netFooter)
                note(L.netRestartFooter)
            }
            .padding(.horizontal, 10)
        }
        .onAppear { stun = net.stunServer ?? ""; nameserver = net.nameserver ?? "" }
    }

    private func note(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "info.circle").foregroundStyle(Theme.label2)
            Text(text).font(.system(size: 11.5)).foregroundStyle(Theme.label2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The engine could not apply a change while running.
    private var restartBanner: some View {
        let inCall = !model.calls.isEmpty
        return HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(Theme.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text(L.netRestartBanner).font(.system(size: 12.5)).fixedSize(horizontal: false, vertical: true)
                if inCall { Text(L.netRestartBusy).font(.system(size: 11.5)).foregroundStyle(Theme.label2) }
            }
            Spacer(minLength: 8)
            Button(L.netRestartNow) { model.restartEngineForNetwork() }
                .disabled(inCall || !model.engineReady)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 9).fill(Theme.orange.opacity(0.14)))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.orange.opacity(0.4), lineWidth: 0.5))
    }

    private func commitNameserver() {
        let v = nameserver.trimmingCharacters(in: .whitespaces)
        model.updateSettings { $0.network.nameserver = v.isEmpty ? nil : v }
    }

    private func commitSTUN() {
        let v = stun.trimmingCharacters(in: .whitespaces)
        model.updateSettings { $0.network.stunServer = v.isEmpty ? nil : v }
    }
}

/// The RTP port range: start 1024...65535, at least 8 ports (two per call), the end not past 65535.
enum RTPRange {
    static let minStart = 1024, maxPort = 65535, minCount = NetworkSettings.minRTPPortCount

    static func validStart(_ start: Int, count: Int) -> Bool {
        (minStart...maxPort).contains(start) && start + count - 1 <= maxPort
    }
    static func validCount(_ count: Int, start: Int) -> Bool {
        count >= minCount && start + count - 1 <= maxPort
    }
    static func clampStart(_ start: Int, count: Int) -> Int { min(max(start, minStart), maxPort - count + 1) }
    static func clampCount(_ count: Int, start: Int) -> Int { min(max(count, minCount), maxPort - start + 1) }
}
