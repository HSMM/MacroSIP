import SwiftUI
import AppKit
import MacroSIPCore

/// Settings › Directory (SCREENS.md 13 B): source list with on/off switches and status, the sign-in group,
/// and the search options.
struct DirectoryPane: View {
    @Environment(AppModel.self) private var model
    @Local private var confirmRemove: UUID?

    private var selected: UUID? {
        get { model.directory.selectedSource }
        nonmutating set { model.directory.selectedSource = newValue }
    }
    private var sources: [DirectorySource] { model.settings.directory.sources }
    private var selectedSource: DirectorySource? { sources.first { $0.id == selected } }

    var body: some View {
        @Bindable var directory = model.directory
        ScrollView { paneContent }
            .frame(maxHeight: 640)
            .background(Theme.groupBackground)
            .sheet(item: $directory.editor) { DirectorySourceSheet(sourceID: $0.sourceID) }
            .alert(confirmRemove.flatMap { id in sources.first { $0.id == id } }.map { L.directoryRemoveTitle($0.shownName) } ?? "",
                   isPresented: Binding(get: { confirmRemove != nil }, set: { if !$0 { confirmRemove = nil } })) {
                Button(L.commonCancel, role: .cancel) {}
                Button(L.commonDelete, role: .destructive) {
                    if let id = confirmRemove { model.removeDirectorySource(id); selected = nil }
                }
            } message: { Text(L.directoryRemoveBody) }
    }

    private var paneContent: some View {
        @Bindable var directory = model.directory
        return PaneContainer(minHeight: 420) {
            ContactsSortGroup()
            FormGroup(footer: L.directorySourcesFooter) {
                VStack(spacing: 0) {
                    header
                    Divider()
                    if sources.isEmpty {
                        VStack(spacing: 8) {
                            Text(L.directoryNoSources).font(.system(size: 12.5)).foregroundStyle(Theme.label2)
                            Button(L.directoryAddHelp) { model.directory.editor = DirectoryEditorRequest(sourceID: nil) }
                                .controlSize(.small)
                        }
                        .frame(maxWidth: .infinity, minHeight: 110)
                    } else {
                        List(selection: $directory.selectedSource) {
                            ForEach(sources) { source in
                                DirectoryRow(source: source)
                                    .tag(source.id)
                                    .listRowInsets(EdgeInsets())
                                    .listRowSeparator(.hidden)
                                    .contentShape(Rectangle())
                                    .onTapGesture(count: 2) { model.directory.editor = DirectoryEditorRequest(sourceID: source.id) }
                            }
                            .onMove { model.moveDirectorySources(from: $0, to: $1) }
                        }
                        .listStyle(.plain)
                        .scrollContentBackground(.hidden)
                        .frame(height: max(110, min(CGFloat(sources.count) * 44 + 4, 220)))
                        .onKeyPress(.return) {
                            guard let id = selected else { return .ignored }
                            model.directory.editor = DirectoryEditorRequest(sourceID: id); return .handled
                        }
                        .onKeyPress(.delete) {
                            guard let id = selected else { return .ignored }
                            confirmRemove = id; return .handled
                        }
                    }
                    Divider()
                    HStack(spacing: 0) {
                        IconButton(systemName: "plus", help: L.directoryAddHelp) { model.directory.editor = DirectoryEditorRequest(sourceID: nil) }
                        IconButton(systemName: "minus", help: L.directoryRemoveHelp) { confirmRemove = selected }
                            .disabled(selectedSource == nil).opacity(selectedSource == nil ? 0.4 : 1)
                        Spacer()
                        Button(L.directoryEdit) {
                            if let id = selected { model.directory.editor = DirectoryEditorRequest(sourceID: id) }
                        }
                        .controlSize(.small)
                        .disabled(selectedSource == nil)
                    }
                    .padding(.horizontal, 6).padding(.vertical, 4)
                }
            }
            ForEach(sources.filter { model.directory.reports[$0.id] != nil }) { source in
                if let report = model.directory.reports[source.id] { ImportBanner(name: source.shownName, report: report) }
            }
            if let source = selectedSource, source.kind == .google, model.directory.statuses[source.id] == .signInRequired {
                let signingIn = model.directory.signingIn.contains(source.id)
                FormGroup(header: source.shownName) {
                    FormRow(label: L.directorySignInTitle,
                            help: signingIn ? L.directoryGoogleSigningIn : (model.directory.signInMessages[source.id] ?? L.directorySignInSub)) {
                        HStack(spacing: 8) {
                            if signingIn { ProgressView().controlSize(.small) }
                            Button(L.directorySignInButton) { model.signInToGoogle(source) }.disabled(signingIn)
                        }
                    }
                }
            }
            FormGroup(header: L.directorySearchHeader) {
                FormRow(label: L.directorySearchEnable) {
                    Toggle("", isOn: model.binding(\.directory.searchFromNumberField)).labelsHidden().toggleStyle(.switch)
                }
                FormDivider()
                FormRow(label: L.directoryMinLength, help: L.directoryMinLengthSub) {
                    NumberStepperField(value: model.binding(\.directory.minimumQueryLength), width: 44,
                                       isValid: { (1...5).contains($0) }, step: { min(5, max(1, $0 + $1)) })
                }
                FormDivider()
                FormRow(label: L.directoryResultsPerSource) {
                    NumberStepperField(value: model.binding(\.directory.resultsPerSource), width: 44,
                                       isValid: { DirectorySettings.resultsPerSourceRange.contains($0) },
                                       step: { min(10, max(1, $0 + $1)) })
                }
                FormDivider()
                FormRow(label: L.directoryLookupEnable, help: L.directoryLookupSub) {
                    Toggle("", isOn: model.binding(\.directory.lookupIncomingCallers)).labelsHidden().toggleStyle(.switch)
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text(L.directoryColumnSource).frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 30)
            Text(L.directoryColumnStatus).frame(width: 172, alignment: .leading)
            Text(L.directoryColumnOn).frame(width: 52, alignment: .leading)
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(Theme.label2)
        .padding(.horizontal, 20).frame(height: 24)
    }
}

/// One source of the list: kind icon, name and address, status, switch. Import sources get "Import now".
private struct DirectoryRow: View {
    @Environment(AppModel.self) private var model
    let source: DirectorySource

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: DirectoryStyle.icon(for: source.kind))
                .font(.system(size: 14)).foregroundStyle(source.isEnabled ? Theme.blue : Theme.label3)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(source.shownName).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    .foregroundStyle(source.isEnabled ? .primary : .secondary)
                Text(detail).font(.system(size: 11)).foregroundStyle(Theme.label2).lineLimit(1).truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    statusDot
                    Text(statusText).foregroundStyle(statusColor).lineLimit(1).minimumScaleFactor(0.8)
                }
                if source.importIntoContacts && source.isEnabled { importButton }
            }
            .font(.system(size: 12))
            .frame(width: 172, alignment: .leading)
            Toggle("", isOn: Binding(get: { source.isEnabled },
                                     set: { v in MainActor.assumeIsolated { model.setDirectorySource(source.id, enabled: v) } }))
                .labelsHidden().toggleStyle(.switch).controlSize(.small)
                .frame(width: 52, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .accessibilityElement(children: .combine)
    }

    private var detail: String {
        let mode = source.importIntoContacts ? L.directoryModeImport : L.directoryModeSearch
        let address = source.kind == .macContacts ? L.directorySummaryThisMac : source.address
        return address.isEmpty ? mode : "\(address) · \(mode)"
    }

    private var status: DirectorySourceStatus? { model.directory.statuses[source.id] }

    @ViewBuilder private var statusDot: some View {
        if source.isEnabled, let status {
            switch status {
            case .connected, .syncedAt: StatusDot(kind: .registered, size: 7)
            case .signInRequired: StatusDot(kind: .registering, size: 7)
            case .error: StatusDot(kind: .failed, size: 7)
            }
        } else {
            StatusDot(kind: .off, size: 7)
        }
    }

    private var statusText: String {
        guard source.isEnabled else { return L.directoryStatusOff }
        guard let status else { return "—" }
        return DirectoryStyle.text(for: status)
    }

    private var statusColor: Color {
        guard source.isEnabled, let status else { return Theme.label2 }
        switch status {
        case .connected, .syncedAt: return .primary
        case .signInRequired: return Theme.orange
        case .error: return Theme.red
        }
    }

    @ViewBuilder private var importButton: some View {
        if model.directory.importing.contains(source.id) {
            HStack(spacing: 5) { ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 12, height: 12); Text(L.directoryImporting) }
                .font(.system(size: 11)).foregroundStyle(Theme.label2)
        } else {
            Button(L.directoryImportNow) { model.importDirectory(source) }
                .controlSize(.mini).disabled(status == .signInRequired)
        }
    }
}

/// The result line of "Import now" ("Imported 120 contacts (14 updated)").
private struct ImportBanner: View {
    let name: String
    let report: DirectoryImportReport

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: report.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(report.isError ? Theme.orange : Theme.green)
            Text("\(name): \(report.text)").font(.system(size: 12.5, weight: .medium)).lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 9).fill((report.isError ? Theme.orange : Theme.green).opacity(0.14)))
        .accessibilityElement(children: .combine)
    }
}

/// Icons and status texts shared by the pane and the sheet.
enum DirectoryStyle {
    static func icon(for kind: DirectorySourceKind) -> String {
        switch kind {
        case .ldap: return "building.2"
        case .url: return "link"
        case .google: return "globe"
        case .macContacts: return "person.crop.square"
        }
    }

    static func text(for status: DirectorySourceStatus) -> String {
        switch status {
        case .connected: return L.directoryStatusConnected
        case .signInRequired: return L.directoryStatusSignIn
        case .syncedAt(let date): return L.directoryStatusSynced(relative(date))
        case .error(let error): return text(for: error)
        }
    }

    /// The reason a source failed, in the app's language (`.server` text comes from a library and is shown as is).
    static func text(for error: DirectoryError) -> String {
        switch error {
        case .accessDenied: return L.directoryStatusDenied
        case .accessNotRequested: return L.directoryErrorAccessNotRequested
        case .signInRequired: return L.directoryStatusSignIn
        case .timedOut: return L.directoryErrorTimedOut
        case .cancelled: return L.directoryErrorCancelled
        case .cannotConnect(let host): return L.directoryErrorCannotConnect(host)
        case .invalidCredentials: return L.directoryErrorInvalidCredentials
        case .http(let code): return L.directoryErrorHTTP(code)
        case .notConfigured(.emptyServer): return L.directoryErrorEmptyServer
        case .notConfigured(.badLDAPURL): return L.directoryErrorBadLDAPURL
        case .notConfigured(.badFeedURL): return L.directoryErrorBadFeedURL
        case .notConfigured(.googleClientID): return L.directoryErrorGoogleClientID
        case .badFeed(.notText): return L.directoryErrorNotText
        case .badFeed(.noNumberColumn): return L.directoryErrorNoNumberColumn
        case .badFeed(.invalidJSON): return L.directoryErrorInvalidJSON
        case .badFeed(.noContactArray): return L.directoryErrorNoContactArray
        case .unsupportedSource: return L.directoryErrorUnsupported
        case .notConnected: return L.directoryErrorNotConnected
        case .server(let text): return text
        }
    }

    static func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        f.locale = Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en")
        return f.localizedString(for: date, relativeTo: Date())
    }
}
