import SwiftUI
import AppKit
import MacroSIPCore

/// Where the source sheet is shown (Settings › Directory).
struct DirectoryEditorRequest: Identifiable, Equatable {
    let id = UUID()
    var sourceID: UUID?                 // nil = new source
    var kind: DirectorySourceKind?      // preset type for a new source (demo states)
}

/// Add / Edit Directory Source (SCREENS.md 13 C): the fields depend on the type; Test; results mode.
struct DirectorySourceSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let sourceID: UUID?

    @Local private var kind: DirectorySourceKind = .ldap
    @Local private var name = ""
    @Local private var enabled = true
    @Local private var importIntoContacts = false
    // LDAP
    @Local private var server = ""
    @Local private var baseDN = ""
    @Local private var bindDN = ""
    @Local private var password = ""
    @Local private var filter = LDAPConfig.defaultFilter
    @Local private var startTLS = false
    // URL
    @Local private var urlText = ""
    @Local private var refreshMinutes = 60
    @Local private var format: URLDirectoryFormat = .csv
    @Local private var formatTouched = false
    // Google
    @Local private var googleAccount: String?
    // state
    @Local private var loaded = false
    @Local private var newID = UUID()
    @Local private var testing = false
    @Local private var testResult: DirectoryTestResult?
    @Local private var googleMessage: String?
    @Local private var touched = false

    private var existing: DirectorySource? { sourceID.flatMap { id in model.settings.directory.sources.first { $0.id == id } } }
    private var id: UUID { sourceID ?? newID }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }
    private var serverValid: Bool { !server.trimmingCharacters(in: .whitespaces).isEmpty }
    private var urlValid: Bool {
        guard let u = URL(string: urlText.trimmingCharacters(in: .whitespaces)), let scheme = u.scheme?.lowercased() else { return false }
        return ["http", "https", "file"].contains(scheme) && (scheme == "file" || u.host?.isEmpty == false)
    }

    private var requiredFilled: Bool {
        switch kind {
        case .ldap: return !trimmedName.isEmpty && serverValid && !baseDN.trimmingCharacters(in: .whitespaces).isEmpty
        case .url: return !trimmedName.isEmpty && urlValid
        case .google: return !trimmedName.isEmpty
        case .macContacts: return true
        }
    }

    private var canTest: Bool {
        switch kind {
        case .ldap: return serverValid && !baseDN.trimmingCharacters(in: .whitespaces).isEmpty
        case .url: return urlValid
        case .google: return false
        case .macContacts: return true
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(existing == nil ? L.directoryAddTitle : L.directoryEditTitle)
                .font(.system(size: 13, weight: .bold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 22).padding(.top, 16).padding(.bottom, 8)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    FormGroup(footer: existing == nil ? L.directoryTypesFooter : nil) {
                        FormRow(label: L.directoryAddType) {
                            Picker("", selection: $kind) {
                                Text(L.directoryTypeLDAP).tag(DirectorySourceKind.ldap)
                                Text(L.directoryTypeURL).tag(DirectorySourceKind.url)
                                Text(L.directoryTypeGoogle).tag(DirectorySourceKind.google)
                                Text(L.directoryTypeMacOS).tag(DirectorySourceKind.macContacts)
                            }
                            .labelsHidden().frame(width: 210).disabled(existing != nil)
                        }
                        if kind != .macContacts {
                            FormDivider()
                            FormRow(label: L.directoryAddName) {
                                TextField("", text: $name).textFieldStyle(.roundedBorder).frame(width: 210)
                            }
                        }
                    }
                    switch kind {
                    case .ldap: ldapFields
                    case .url: urlFields
                    case .google: googleFields
                    case .macContacts: macFields
                    }
                    resultsGroup
                }
                .padding(.horizontal, 22).padding(.bottom, 8)
            }
            Divider()
            buttonRow
        }
        .frame(width: 520, height: sheetHeight)
        .background(Theme.groupBackground)
        .onAppear(perform: load)
        .onDisappear { if model.directory.signingIn.contains(id) { model.cancelGoogleSignIn() } }
        .onChange(of: kind) { _, _ in testResult = nil; googleMessage = nil }
        .onChange(of: urlText) { _, text in
            if !formatTouched { format = text.lowercased().hasSuffix(".json") ? .json : .csv }
        }
    }

    private var sheetHeight: CGFloat {
        switch kind {
        case .ldap: return 640
        case .url: return 560
        case .google: return 500
        case .macContacts: return 420
        }
    }

    // MARK: fields

    @ViewBuilder private var ldapFields: some View {
        FormGroup(header: L.directoryTypeLDAP) {
            FormRow(label: L.directoryLDAPServer, help: L.directoryLDAPServerSub) {
                TextField("ldap://ldap.example.com", text: $server).textFieldStyle(.roundedBorder).frame(width: 230)
            }
            FormDivider()
            FormRow(label: L.directoryLDAPStartTLS) {
                Toggle("", isOn: $startTLS).labelsHidden().toggleStyle(.switch)
                    .disabled(server.lowercased().hasPrefix("ldaps://"))
            }
            FormDivider()
            FormRow(label: L.directoryLDAPBaseDN) {
                TextField("ou=people,dc=example,dc=com", text: $baseDN).textFieldStyle(.roundedBorder).frame(width: 230)
            }
            FormDivider()
            FormRow(label: L.directoryLDAPBindDN, help: L.directoryLDAPBindDNSub) {
                TextField("cn=phones,dc=example,dc=com", text: $bindDN).textFieldStyle(.roundedBorder).frame(width: 230)
            }
            FormDivider()
            FormRow(label: L.directoryLDAPPassword, help: L.directoryLDAPPasswordSub) {
                SecureField(existing != nil ? "••••••••" : "", text: $password).textFieldStyle(.roundedBorder).frame(width: 230)
            }
            FormDivider()
            FormRow(label: L.directoryLDAPFilter, help: L.directoryLDAPFilterSub) {
                TextField(LDAPConfig.defaultFilter, text: $filter).textFieldStyle(.roundedBorder).frame(width: 230)
                    .font(.system(size: 12, design: .monospaced))
            }
        }
    }

    @ViewBuilder private var urlFields: some View {
        FormGroup(footer: L.directoryURLFooter) {
            FormRow(label: L.directoryURLURL) {
                TextField("https://intranet.example.com/phones.csv", text: $urlText)
                    .textFieldStyle(.roundedBorder).frame(width: 290)
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(touched && !urlValid ? Theme.red : .clear, lineWidth: 1))
                    .onChange(of: urlText) { _, _ in touched = true }
            }
            FormDivider()
            FormRow(label: L.directoryURLFormat) {
                SegmentedTabs(items: [.init(value: URLDirectoryFormat.csv, title: "CSV"), .init(value: URLDirectoryFormat.json, title: "JSON")],
                              selection: Binding(get: { format }, set: { format = $0; formatTouched = true }))
                    .frame(width: 130)
            }
            FormDivider()
            FormRow(label: L.directoryURLRefresh) {
                Picker("", selection: $refreshMinutes) {
                    Text(L.directoryURLRefreshHour).tag(60)
                    Text(L.directoryURLRefreshHours6).tag(360)
                    Text(L.directoryURLRefreshDay).tag(1440)
                    Text(L.directoryURLRefreshWeek).tag(10080)
                    if !URLConfig.refreshChoices.contains(refreshMinutes) { Text("\(refreshMinutes) min").tag(refreshMinutes) }
                }
                .labelsHidden().frame(width: 130)
            }
        }
    }

    private var googleSigningIn: Bool { model.directory.signingIn.contains(id) }

    @ViewBuilder private var googleFields: some View {
        FormGroup(footer: L.directoryGoogleFooter) {
            FormRow(label: googleAccount ?? L.directoryGoogleAccount, help: googleSigningIn ? L.directoryGoogleSigningIn : nil) {
                HStack(spacing: 8) {
                    if googleSigningIn { ProgressView().controlSize(.small) }
                    if let googleAccount, !googleSigningIn {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.green)
                            .accessibilityLabel(googleAccount)
                    }
                    Button(L.directoryGoogleSignIn) { signInWithGoogle() }.disabled(googleSigningIn)
                }
            }
            if let googleMessage {
                FormDivider()
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.orange)
                    Text(googleMessage).font(.system(size: 12, weight: .semibold))
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12).frame(minHeight: 34)
            }
        }
    }

    @ViewBuilder private var macFields: some View {
        FormGroup(footer: L.directoryMacOSFooter) {
            FormRow(label: L.directoryMacOSName) {
                Button(L.directoryMacOSAllow) { runTest() }.disabled(testing)
            }
            if let result = testResult, result.status.isAccessDenied {
                FormDivider()
                FormRow(label: L.directoryStatusDenied) {
                    Button(L.directoryOpenPrivacy) {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Contacts") { NSWorkspace.shared.open(url) }
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    private var resultsGroup: some View {
        FormGroup(header: L.directoryResultsHeader) {
            radioRow(title: L.directoryResultsSearch, sub: L.directoryResultsSearchSub, on: !importIntoContacts) { importIntoContacts = false }
            FormDivider()
            radioRow(title: L.directoryResultsImport, sub: L.directoryResultsImportSub, on: importIntoContacts) { importIntoContacts = true }
        }
    }

    private func radioRow(title: String, sub: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: on ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 14)).foregroundStyle(on ? Theme.blue : Theme.label3)
                Text(title).font(.system(size: 13))
                Text(sub).font(.system(size: 11.5)).foregroundStyle(Theme.label2)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).frame(minHeight: 36)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    // MARK: buttons

    private var buttonRow: some View {
        HStack(spacing: 10) {
            if kind != .macContacts && kind != .google {
                Button(L.directoryTest) { runTest() }.disabled(!canTest || testing).fixedSize()
            }
            testLine
            Spacer()
            Button(L.directoryAddCancel) { cancel() }.keyboardShortcut(.cancelAction).fixedSize()
            Button(existing == nil ? L.directoryAddConfirm : L.commonSave) { save() }
                .keyboardShortcut(.defaultAction).disabled(!requiredFilled).fixedSize()
        }
        .padding(.horizontal, 22).padding(.vertical, 12)
    }

    @ViewBuilder private var testLine: some View {
        if testing {
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text(L.directoryTesting).font(.system(size: 12)) }
        } else if let result = testResult {
            HStack(spacing: 6) {
                switch result.status {
                case .connected, .syncedAt:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.green)
                    Text(result.entryCount.map(L.directoryTestSuccess) ?? L.directoryTestConnected).font(.system(size: 12, weight: .semibold))
                case .signInRequired:
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.orange)
                    Text(L.directoryStatusSignIn).font(.system(size: 12, weight: .semibold))
                case .error:
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.orange)
                    Text(DirectoryStyle.text(for: result.status)).font(.system(size: 12, weight: .semibold)).lineLimit(2)
                }
            }
            .accessibilityElement(children: .combine)
        }
    }

    // MARK: logic

    private func load() {
        guard !loaded else { return }
        loaded = true
        if let s = existing {
            kind = s.kind
            name = s.name
            enabled = s.isEnabled
            importIntoContacts = s.importIntoContacts
            if let l = s.ldap {
                server = l.server; baseDN = l.baseDN; bindDN = l.bindDN; filter = l.searchFilter; startTLS = l.startTLS
            }
            if let u = s.url { urlText = u.url; refreshMinutes = u.refreshMinutes; format = u.format; formatTouched = true }
            googleAccount = s.google?.accountEmail
        } else if let preset = model.directory.editor?.kind {
            kind = preset
            importIntoContacts = preset == .macContacts
        }
    }

    private func makeSource() -> DirectorySource {
        var s = existing ?? DirectorySource(id: id, kind: kind, name: trimmedName, isEnabled: enabled, importIntoContacts: importIntoContacts)
        s.kind = kind
        s.name = kind == .macContacts ? "" : trimmedName          // the macOS Contacts label follows the language
        s.importIntoContacts = importIntoContacts
        switch kind {
        case .ldap:
            var l = s.ldap ?? LDAPConfig()
            l.server = server.trimmingCharacters(in: .whitespaces)
            l.baseDN = baseDN.trimmingCharacters(in: .whitespaces)
            l.bindDN = bindDN.trimmingCharacters(in: .whitespaces)
            let f = filter.trimmingCharacters(in: .whitespaces)
            l.searchFilter = f.isEmpty ? LDAPConfig.defaultFilter : f
            l.startTLS = startTLS && !l.server.lowercased().hasPrefix("ldaps://")
            s.ldap = l
        case .url:
            var u = s.url ?? URLConfig()
            u.url = urlText.trimmingCharacters(in: .whitespaces)
            u.refreshMinutes = refreshMinutes
            u.format = format
            s.url = u
        case .google:
            var g = s.google ?? GoogleConfig()
            if let googleAccount { g.accountEmail = googleAccount }
            s.google = g
        case .macContacts:
            break
        }
        return s
    }

    /// The same OAuth flow as Settings › Directory, for the source in the sheet (saved or not); the e-mail
    /// replaces the row label and is stored by Save (a saved source is updated at once).
    private func signInWithGoogle() {
        googleMessage = nil
        let sourceID = id
        let saved = existing != nil
        model.cancelGoogleSignIn()
        model.directory.signInTask = Task { @MainActor in
            do {
                let email = try await model.runGoogleSignIn(sourceID: sourceID)
                googleAccount = email
                if saved {
                    model.updateSettings { s in
                        guard let i = s.directory.sources.firstIndex(where: { $0.id == sourceID }) else { return }
                        var g = s.directory.sources[i].google ?? GoogleConfig()
                        g.accountEmail = email
                        s.directory.sources[i].google = g
                    }
                    model.directory.statuses[sourceID] = .connected
                }
            } catch DirectoryError.cancelled {
            } catch is CancellationError {
            } catch {
                googleMessage = (error as? DirectoryError).map { DirectoryStyle.text(for: $0) } ?? describe(error)
            }
        }
    }

    private func runTest() {
        testing = true
        testResult = nil
        let source = makeSource()
        let pw = kind == .ldap && !password.isEmpty ? password : nil
        Task {
            let result = await model.testDirectorySource(source, password: pw)
            testing = false
            testResult = result
        }
    }

    private func save() {
        guard requiredFilled else { return }
        let source = makeSource()
        model.saveDirectorySource(source, password: kind == .ldap ? password : nil, passwordTouched: !password.isEmpty)
        dismiss()
    }

    /// A password typed for Test was never stored; a Google token obtained for a source that is never saved is
    /// deleted, so the Keychain keeps nothing for an id that no source carries.
    private func cancel() {
        if existing == nil, googleAccount != nil { model.discardDirectorySecrets(for: id) }
        dismiss()
    }
}
