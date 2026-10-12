import SwiftUI
import MacroSIPCore

/// Screen 9: account editor sheet with Test (temporary registration) and Delete.
struct AccountEditorSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let accountID: AccountID?
    var compact = false          // the main window is only 520 pt tall

    @Local private var name = ""
    @Local private var displayName = ""
    @Local private var server = ""
    @Local private var username = ""
    @Local private var authUsername = ""
    @Local private var password = ""
    @Local private var domain = ""
    @Local private var proxy = ""
    @Local private var transport: TransportKind = .udp
    @Local private var srtp: SRTPMode = .disabled
    @Local private var expiry = 300
    @Local private var enabled = true
    @Local private var register = true
    @Local private var isDefault = false
    @Local private var publishPresence = false
    @Local private var verifyTLS = true
    @Local private var serverTouched = false
    @Local private var loaded = false
    @Local private var testing = false
    @Local private var testResult: AccountTestResult?
    @Local private var confirmDelete = false
    @Local private var saving = false

    private var existing: AccountConfig? { accountID.flatMap(model.account(_:)) }

    private var serverValid: Bool { Self.isValidHost(server.trimmingCharacters(in: .whitespaces)) }
    private var expiryValid: Bool { (60...3600).contains(expiry) }
    private var canTest: Bool { serverValid && !username.trimmingCharacters(in: .whitespaces).isEmpty && !password.isEmpty }
    private var canSave: Bool {
        canTest && !name.trimmingCharacters(in: .whitespaces).isEmpty && expiryValid && !saving
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(existing == nil ? L.accountTitleNew : L.accountTitleEdit)
                .font(.system(size: 13, weight: .bold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 22).padding(.top, 16).padding(.bottom, 8)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    FormGroup(header: L.accountGroupIdentity) {
                        row(L.accountName) { TextField("", text: $name).textFieldStyle(.roundedBorder).frame(width: 210) }
                        FormDivider()
                        row(L.accountDisplayName, help: L.accountDisplayNameHelp) {
                            TextField("", text: $displayName).textFieldStyle(.roundedBorder).frame(width: 210)
                        }
                    }
                    FormGroup(header: L.accountGroupServer, footer: serverTouched && !serverValid ? L.accountErrorServer : nil) {
                        row(L.accountServer) {
                            TextField("pbx.example.com", text: $server)
                                .textFieldStyle(.roundedBorder).frame(width: 210)
                                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(serverTouched && !serverValid ? Theme.red : .clear, lineWidth: 1))
                                .onChange(of: server) { _, _ in serverTouched = true }
                        }
                        FormDivider()
                        row(L.accountUsername) { TextField("", text: $username).textFieldStyle(.roundedBorder).frame(width: 210) }
                        FormDivider()
                        row(L.accountAuthUsername, help: L.accountAuthUsernameHelp) {
                            TextField(L.accountOptional, text: $authUsername).textFieldStyle(.roundedBorder).frame(width: 210)
                        }
                        FormDivider()
                        row(L.accountPassword, help: L.accountPasswordHelp) {
                            SecureField("", text: $password).textFieldStyle(.roundedBorder).frame(width: 210)
                        }
                        FormDivider()
                        row(L.accountDomain, help: L.accountDomainHelp) {
                            TextField("pbx.example.com", text: $domain).textFieldStyle(.roundedBorder).frame(width: 210)
                        }
                        FormDivider()
                        row(L.accountProxy) {
                            TextField(L.accountProxyPlaceholder, text: $proxy).textFieldStyle(.roundedBorder).frame(width: 210)
                        }
                    }
                    FormGroup(header: L.accountGroupConnection) {
                        row(L.accountTransport) {
                            SegmentedTabs(items: TransportKind.allCases.map { .init(value: $0, title: $0.rawValue.uppercased()) },
                                          selection: $transport)
                                .frame(width: 170)
                        }
                        FormDivider()
                        row(L.accountSRTP) {
                            Picker("", selection: $srtp) {
                                Text(L.srtpDisabled).tag(SRTPMode.disabled)
                                Text(L.srtpOptional).tag(SRTPMode.optional)
                                Text(L.srtpMandatory).tag(SRTPMode.mandatory)
                            }
                            .labelsHidden().frame(width: 130)
                        }
                        FormDivider()
                        row(L.accountExpiry) {
                            HStack(spacing: 6) {
                                NumberStepperField(value: $expiry, width: 56, isValid: { (60...3600).contains($0) },
                                                   step: { min(3600, max(60, $0 + $1 * 30)) })
                                Text(L.unitSeconds).font(.system(size: 12)).foregroundStyle(Theme.label2)
                            }
                        }
                        if transport == .tls {
                            FormDivider()
                            row(L.accountVerifyCertificate, help: L.accountVerifyCertificateHelp) {
                                Toggle("", isOn: $verifyTLS).labelsHidden().toggleStyle(.switch)
                            }
                        }
                    }
                    FormGroup {
                        row(L.accountEnabled, help: L.accountEnabledHelp) {
                            Toggle("", isOn: $enabled).labelsHidden().toggleStyle(.switch)
                        }
                        FormDivider()
                        row(L.accountRegister, help: L.accountRegisterHelp) {
                            Toggle("", isOn: $register).labelsHidden().toggleStyle(.switch)
                        }
                        FormDivider()
                        row(L.accountDefaultOutgoing) {
                            Toggle("", isOn: $isDefault).labelsHidden().toggleStyle(.switch)
                        }
                        FormDivider()
                        row(L.accountPublishPresence, help: L.accountPublishPresenceHelp) {
                            Toggle("", isOn: $publishPresence).labelsHidden().toggleStyle(.switch)
                        }
                    }
                }
                .padding(.horizontal, 22).padding(.bottom, 8)
            }
            Divider()
            testMessage
            buttonRow
        }
        .frame(width: 500, height: compact ? 470 : 640)
        .background(Theme.groupBackground)
        .onAppear(perform: load)
        .alert(L.accountDeleteTitle(existing?.displayName ?? name), isPresented: $confirmDelete) {
            Button(L.commonCancel, role: .cancel) {}
            Button(L.commonDelete, role: .destructive) {
                if let id = accountID { Task { await model.deleteAccount(id); dismiss() } }
            }
        } message: { Text(L.accountDeleteBody) }
    }

    private func row<C: View>(_ label: String, help: String? = nil, @ViewBuilder control: () -> C) -> some View {
        FormRow(label: label, help: help, control: control)
    }

    // MARK: buttons and test result

    @ViewBuilder
    private var testMessage: some View {
        if testing {
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text(L.accountTesting).font(.system(size: 12)) }
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 22).padding(.top, 8)
        } else if let result = testResult {
            HStack(alignment: .top, spacing: 8) {
                switch result {
                case let .success(ms):
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.green)
                    Text(L.accountTestSuccess(ms)).font(.system(size: 12, weight: .semibold))
                case let .failed(code, reason):
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.orange)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(L.accountTestFailed(code > 0 ? "\(code) \(reason)" : reason)).font(.system(size: 12, weight: .bold))
                        Text(L.accountTestFailedHint).font(.system(size: 11.5)).foregroundStyle(Theme.label2)
                    }
                case .timeout:
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.orange)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(L.accountTestFailed(L.accountTestTimeout)).font(.system(size: 12, weight: .bold))
                        Text(L.accountTestTimeoutHint).font(.system(size: 11.5)).foregroundStyle(Theme.label2)
                    }
                case let .error(text):
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.orange)
                    Text(L.accountTestFailed(text)).font(.system(size: 12, weight: .bold))
                }
                Spacer()
                if case .success = result {} else {
                    Button(L.accountTestAgain) { runTest() }.controlSize(.small)
                }
            }
            .padding(.horizontal, 22).padding(.top, 8)
            .accessibilityElement(children: .combine)
        }
    }

    private var buttonRow: some View {
        HStack(spacing: 8) {
            if existing != nil {
                Button(L.accountDelete, role: .destructive) { confirmDelete = true }
                    .foregroundStyle(Theme.red).fixedSize()
            }
            Button(L.accountTest) { runTest() }.disabled(!canTest || testing).fixedSize()
            statusText
            Spacer()
            Button(L.commonCancel) { dismiss() }.keyboardShortcut(.cancelAction).fixedSize()
            Button(L.commonSave) { save() }.keyboardShortcut(.defaultAction).disabled(!canSave).fixedSize()
        }
        .padding(.horizontal, 22).padding(.vertical, 12)
    }

    @ViewBuilder
    private var statusText: some View {
        HStack(spacing: 5) {
            if let acct = existing {
                StatusDot(kind: model.dot(for: acct), size: 7)
                Text(statusLabel(acct)).foregroundStyle(model.dot(for: acct) == .failed ? Theme.red : Theme.label2)
            } else {
                StatusDot(kind: .off, size: 7)
                Text(L.accountUnsaved).foregroundStyle(Theme.label2)
            }
        }
        .font(.system(size: 11.5)).lineLimit(1)
    }

    private func statusLabel(_ acct: AccountConfig) -> String {
        guard acct.enabled else { return L.accountsDisabled }
        guard acct.registerWithServer else { return L.accountsOutgoingOnly }
        switch model.registration[acct.id] ?? .unregistered {
        case .registered: return L.accountsRegistered
        case .failed: return model.registration[acct.id]?.shortReason ?? ""
        default: return L.statusRegistering
        }
    }

    // MARK: logic

    private func load() {
        guard !loaded else { return }
        loaded = true
        if let a = existing {
            name = a.displayName
            displayName = model.callerName(for: a.id)
            server = a.registrar ?? a.domain
            domain = a.registrar != nil ? a.domain : ""
            username = a.username
            authUsername = a.authID ?? ""
            password = model.vault.password(for: a.id) ?? ""
            proxy = a.outboundProxy ?? ""
            transport = a.transport
            srtp = a.srtp
            expiry = a.registrationInterval
            enabled = a.enabled
            register = a.registerWithServer
            isDefault = a.isDefaultOutgoing
            publishPresence = a.publishPresence
            verifyTLS = a.verifyTLSCertificate
        } else {
            isDefault = model.accounts.isEmpty          // the first account is the default
        }
        serverTouched = false
    }

    private func makeConfig() -> AccountConfig {
        var cfg = existing ?? AccountConfig(displayName: "", username: "", domain: "")
        let srv = server.trimmingCharacters(in: .whitespaces)
        let dom = domain.trimmingCharacters(in: .whitespaces)
        cfg.displayName = name.trimmingCharacters(in: .whitespaces)
        cfg.username = username.trimmingCharacters(in: .whitespaces)
        if dom.isEmpty { cfg.domain = srv; cfg.registrar = nil }
        else { cfg.domain = dom; cfg.registrar = dom == srv ? nil : srv }
        let px = proxy.trimmingCharacters(in: .whitespaces)
        cfg.outboundProxy = px.isEmpty ? nil : px
        let au = authUsername.trimmingCharacters(in: .whitespaces)
        cfg.authID = au.isEmpty ? nil : au
        cfg.transport = transport
        cfg.srtp = srtp
        cfg.enabled = enabled
        cfg.registerWithServer = register
        cfg.isDefaultOutgoing = isDefault
        cfg.registrationInterval = expiry
        cfg.publishPresence = publishPresence
        cfg.verifyTLSCertificate = verifyTLS
        return cfg
    }

    private func runTest() {
        guard canTest else { return }
        testing = true
        testResult = nil
        let cfg = makeConfig()
        let pw = password
        Task {
            let result = await model.testAccount(cfg, password: pw)
            testing = false
            testResult = result
        }
    }

    private func save() {
        guard canSave else { return }
        saving = true
        let cfg = makeConfig()
        let pw = password
        let caller = displayName.trimmingCharacters(in: .whitespaces)
        Task {
            do {
                try await model.saveAccount(cfg, password: pw, callerName: caller)
                dismiss()
            } catch {
                model.report(error)
                saving = false
            }
        }
    }

    /// Host name like pbx.example.com (optional :port), IPv4, or [IPv6].
    static func isValidHost(_ s: String) -> Bool {
        guard !s.isEmpty, s.count <= 255 else { return false }
        var host = s
        if s.hasPrefix("[") {
            guard let close = s.firstIndex(of: "]") else { return false }
            let inner = s[s.index(after: s.startIndex)..<close]
            return inner.contains(":") && inner.allSatisfy { $0.isHexDigit || $0 == ":" || $0 == "." }
        }
        if let colon = host.lastIndex(of: ":") {
            let port = host[host.index(after: colon)...]
            guard let p = Int(port), (1...65535).contains(p) else { return false }
            host = String(host[..<colon])
        }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard !labels.isEmpty else { return false }
        return labels.allSatisfy { l in
            !l.isEmpty && l.count <= 63 && !l.hasPrefix("-") && !l.hasSuffix("-")
                && l.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        }
    }
}
