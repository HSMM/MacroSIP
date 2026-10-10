import SwiftUI
import MacroSIPCore

/// 8.2 Accounts: live-status table, add / remove / edit, last error with Retry.
struct AccountsPane: View {
    @Environment(AppModel.self) private var model
    @Local private var confirmDelete: AccountID?

    private var selected: AccountConfig? { model.settingsSelectedAccount.flatMap(model.account(_:)) }

    var body: some View {
        @Bindable var model = model
        PaneContainer(minHeight: 400) {
            FormGroup(footer: L.accountsFooter) {
                VStack(spacing: 0) {
                    header
                    Divider()
                    if model.accounts.isEmpty {
                        Text(L.accountsEmpty).font(.system(size: 12.5)).foregroundStyle(Theme.label2)
                            .frame(maxWidth: .infinity, minHeight: 120)
                    } else {
                        List(selection: $model.settingsSelectedAccount) {
                            ForEach(model.accounts) { account in
                                AccountTableRow(account: account, selected: model.settingsSelectedAccount == account.id)
                                    .tag(account.id)
                                    .listRowInsets(EdgeInsets())
                                    .listRowSeparator(.hidden)
                                    .contentShape(Rectangle())
                                    .onTapGesture(count: 2) { model.settingsEditor = AccountEditorRequest(accountID: account.id) }
                            }
                            .onMove { model.moveAccounts(from: $0, to: $1) }
                        }
                        .listStyle(.plain)
                        .scrollContentBackground(.hidden)
                        .frame(height: max(120, min(CGFloat(model.accounts.count) * 30 + 4, 180)))
                        .onKeyPress(.return) {
                            guard let id = model.settingsSelectedAccount else { return .ignored }
                            model.settingsEditor = AccountEditorRequest(accountID: id); return .handled
                        }
                        .onKeyPress(.delete) {
                            guard let id = model.settingsSelectedAccount else { return .ignored }
                            confirmDelete = id; return .handled
                        }
                    }
                    Divider()
                    HStack(spacing: 0) {
                        IconButton(systemName: "plus", help: L.accountsAddHelp) { model.settingsEditor = AccountEditorRequest(accountID: nil) }
                        IconButton(systemName: "minus", help: L.accountsRemoveHelp) { confirmDelete = model.settingsSelectedAccount }
                            .disabled(selected == nil).opacity(selected == nil ? 0.4 : 1)
                        Spacer()
                        Button(L.accountsEdit) {
                            if let id = model.settingsSelectedAccount { model.settingsEditor = AccountEditorRequest(accountID: id) }
                        }
                        .controlSize(.small)
                        .disabled(selected == nil)
                    }
                    .padding(.horizontal, 6).padding(.vertical, 4)
                }
            }
            if let account = selected, account.enabled, let state = model.registration[account.id], let reason = state.fullReason {
                FormGroup(header: L.accountsLastErrorHeader(account.displayName)) {
                    FormRow(label: reason, help: L.accountsLastErrorBody(
                        (model.registrationTimes[account.id] ?? Date()).formatted(date: .omitted, time: .shortened))) {
                        Button(L.accountsRetry) { model.retryRegistration(account.id) }
                    }
                }
            }
        }
        .sheet(item: $model.settingsEditor) { AccountEditorSheet(accountID: $0.accountID) }
        .alert(confirmDelete.flatMap { model.account($0) }.map { L.accountDeleteTitle($0.displayName) } ?? "",
               isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } })) {
            Button(L.commonCancel, role: .cancel) {}
            Button(L.commonDelete, role: .destructive) {
                if let id = confirmDelete { Task { await model.deleteAccount(id) } }
            }
        } message: { Text(L.accountDeleteBody) }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Color.clear.frame(width: 16)
            Text(L.accountsColName).frame(maxWidth: .infinity, alignment: .leading)
            Text(L.accountsColAddress).frame(maxWidth: .infinity, alignment: .leading)
            Text(L.accountsColTransport).frame(width: 60, alignment: .leading)
            Text(L.accountsColStatus).frame(width: 70, alignment: .leading)
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(Theme.label2)
        .padding(.horizontal, 20).frame(height: 24)
    }
}

struct AccountTableRow: View {
    @Environment(AppModel.self) private var model
    let account: AccountConfig
    let selected: Bool

    var body: some View {
        HStack(spacing: 10) {
            StatusDot(kind: model.dot(for: account), size: 8).frame(width: 16)
            HStack(spacing: 6) {
                Text(account.displayName).lineLimit(1)
                if account.isDefaultOutgoing {
                    Text(L.accountsBadgeDefault)
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 5).frame(height: 16)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.12)))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text("\(account.username)@\(account.domain)").foregroundStyle(.secondary).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(account.transport.rawValue.uppercased()).foregroundStyle(.secondary).frame(width: 60, alignment: .leading)
            statusText.frame(width: 70, alignment: .leading)
        }
        .font(.system(size: 12.5))
        .padding(.horizontal, 12)
        .frame(height: 30)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var statusText: some View {
        if !account.enabled {
            Text(L.accountsDisabled).foregroundStyle(.secondary)
        } else {
            switch model.registration[account.id] ?? .unregistered {
            case .registered: Text(L.accountsRegistered)
            case let .failed(code, reason): Text(code > 0 ? "\(code)" : reason).foregroundStyle(Theme.red)
            default: Text(L.statusRegistering).foregroundStyle(Theme.orange)
            }
        }
    }
}
