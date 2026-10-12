import SwiftUI
import MacroSIPCore

/// Common frame of screens 1 to 5 and 10: account row, number row, tabs, body, status bar. Content size 340 by 520.
struct MainWindowView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                AccountRow()
                NumberRow()
            }
            .zIndex(2)
            SegmentedTabs(
                items: [
                    .init(value: MainTab.dialpad, title: L.tabsDialpad),
                    .init(value: MainTab.contacts, title: L.tabsContacts),
                    .init(value: MainTab.callLog, title: L.tabsCallLog, badge: model.missedUnseen),
                ],
                selection: $model.tab)
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
            Divider()
            tabBody
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.content)
                .zIndex(0)
            Divider()
            StatusBar()
        }
        .frame(width: 340, height: 520)
        .overlay(alignment: .bottom) { BannerView().padding(.bottom, 32) }
        .sheet(item: $model.mainEditor) { request in
            AccountEditorSheet(accountID: request.accountID, compact: true)
        }
        .onChange(of: model.tab) { _, tab in
            if tab == .callLog { model.markLogSeen() }
        }
        .onAppear { model.openSettingsAction = { openSettings() } }
    }

    @ViewBuilder
    private var tabBody: some View {
        switch model.tab {
        case .dialpad:
            if !model.hasAccounts {
                FirstLaunchView()
            } else if model.hasCallActivity {
                CallPanelView()
            } else {
                DialpadView()
            }
        case .contacts:
            VStack(spacing: 0) {
                CallSummaryBar()
                ContactsView()
            }
        case .callLog:
            VStack(spacing: 0) {
                CallSummaryBar()
                CallLogView()
            }
        }
    }
}

struct BannerView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let banner = model.banner {
            HStack(spacing: 6) {
                Image(systemName: banner.isError ? "exclamationmark.triangle.fill" : "info.circle.fill")
                    .foregroundStyle(banner.isError ? Theme.orange : Theme.blue)
                Text(banner.text).font(.system(size: 11.5)).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button { model.banner = nil } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L.commonDone)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.separator))
            .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
            .padding(.horizontal, 10)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .accessibilityElement(children: .combine)
        }
    }
}

struct StatusBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 12) {
            if model.enabledAccounts.isEmpty {
                HStack(spacing: 5) {
                    StatusDot(kind: .off, size: 7)
                    Text(model.accounts.isEmpty ? L.statusNoAccounts : L.statusNoneEnabled)
                }
                Spacer(minLength: 0)
                Button { model.openSettings(tab: .accounts) } label: {
                    Text("\(L.menuSettings) ⌘,")
                }
                .buttonStyle(.plain)
            } else if model.enabledAccounts.count > 3 {
                let shown = model.enabledAccounts
                let ok = shown.filter { model.dot(for: $0) == .registered }.count
                Button { model.openSettings(tab: .accounts) } label: {
                    HStack(spacing: 5) {
                        StatusDot(kind: ok == shown.count ? .registered : (ok == 0 ? .failed : .registering), size: 7)
                        Text(L.statusSummary(ok, shown.count))
                    }
                }
                .buttonStyle(.plain)
                .help(shown.map { "\($0.displayName): \(statusText($0))" }.joined(separator: "\n"))
                Spacer(minLength: 0)
            } else {
                ForEach(model.enabledAccounts) { account in
                    Button { model.openSettings(tab: .accounts, account: account.id) } label: {
                        HStack(spacing: 5) {
                            StatusDot(kind: model.dot(for: account), size: 7)
                            if let reason = model.registration[account.id]?.shortReason, account.registerWithServer {
                                Text(L.statusAccountFailed(account.displayName, reason)).foregroundStyle(Theme.red)
                            } else {
                                Text(account.displayName)
                            }
                        }
                        .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    .help(statusText(account))
                }
                Spacer(minLength: 0)
            }
        }
        .font(.system(size: 11.5))
        .foregroundStyle(Theme.label2)
        .padding(.horizontal, 10)
        .frame(height: 26)
        .lineLimit(1)
    }

    private func statusText(_ account: AccountConfig) -> String {
        guard account.enabled else { return L.accountsDisabled }
        guard account.registerWithServer else { return L.accountsOutgoingOnly }
        switch model.registration[account.id] ?? .unregistered {
        case .registered: return L.accountsRegistered
        case .failed: return model.registration[account.id]?.fullReason ?? ""
        default: return L.statusRegistering
        }
    }
}
