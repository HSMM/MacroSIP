import SwiftUI
import MacroSIPCore

/// Settings › Accounts › Import from MicroSIP… (SCREENS.md 8.2): a preview of what the files hold, then a report.
/// Nothing is written until Import is pressed; Cancel changes nothing.
struct MicroSIPImportSheet: View {
    @Environment(AppModel.self) private var model
    /// Rows shown per list: a file may hold thousands, the sheet builds no more than this.
    private static let rowLimit = 50

    var body: some View {
        VStack(spacing: 0) {
            if let session = model.microSIPImport {
                Text(session.report == nil ? L.importTitle : L.importDoneTitle)
                    .font(.system(size: 13, weight: .bold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 22).padding(.top, 16).padding(.bottom, 8)
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        fileRow(session)
                        if let saveError = session.saveError { warningLine(saveError) }
                        if let report = session.report {
                            reportBody(report)
                        } else {
                            switch session.outcome {
                            case .loading: loadingBody
                            case let .failed(error): errorBody(error)
                            case let .preview(merge): previewBody(merge, session: session)
                            }
                        }
                    }
                    .padding(.horizontal, 22).padding(.bottom, 8)
                }
                Divider()
                buttons(session)
            }
        }
        .frame(width: 520, height: 560)
        .background(Theme.groupBackground)
    }

    // MARK: Parts

    private func fileRow(_ session: MicroSIPImportSession) -> some View {
        FormGroup {
            FormRow(label: session.iniURL.lastPathComponent, help: (session.iniURL.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath) { EmptyView() }
            if session.report == nil, case .preview = session.outcome {
                FormDivider()
                FormRow(label: L.importContactsFile, help: session.contactsURL?.lastPathComponent ?? L.importContactsNone) {
                    HStack(spacing: 6) {
                        Button(L.importContactsChoose) { model.chooseMicroSIPContactsFile() }.controlSize(.small)
                        Button(L.importContactsNoFile) { model.setMicroSIPContacts(nil) }
                            .controlSize(.small).disabled(session.contactsURL == nil)
                    }
                }
            }
        }
    }

    private var loadingBody: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(L.importLoading).font(.system(size: 12.5)).foregroundStyle(Theme.label2)
        }
        .padding(.horizontal, 4)
    }

    private func errorBody(_ error: MicroSIPImport.ReadError) -> some View {
        warningLine(Self.text(for: error))
    }

    private func warningLine(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.orange)
            Text(text).font(.system(size: 12.5)).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 4)
    }

    /// The last row of a list cut at `rowLimit`.
    @ViewBuilder
    private func moreRow(total: Int) -> some View {
        if total > Self.rowLimit {
            FormDivider()
            FormRow(label: L.importAndMore(total - Self.rowLimit)) { EmptyView() }
        }
    }

    @ViewBuilder
    private func previewBody(_ merge: MicroSIPImport.Merge, session: MicroSIPImportSession) -> some View {
        FormGroup(header: "\(L.importAccountsHeader) · \(merge.accounts.count)") {
            if merge.accounts.isEmpty {
                FormRow(label: L.importNoNewAccounts) { EmptyView() }
            }
            ForEach(Array(merge.accounts.prefix(Self.rowLimit).enumerated()), id: \.offset) { index, account in
                if index > 0 { FormDivider() }
                FormRow(label: account.config.displayName,
                        help: "\(account.config.username)@\(account.config.domain) · \(account.config.transport.rawValue.uppercased())") {
                    if MicroSIPImport.needsPassword(account.config) {
                        Text(L.accountsNeedsPassword).font(.system(size: 11.5)).foregroundStyle(Theme.orange)
                    }
                }
            }
            moreRow(total: merge.accounts.count)
        }
        FormGroup {
            FormRow(label: L.importCountContacts(merge.contacts.count)) { EmptyView() }
        }
        let warnings = merge.warnings.prefix(Self.rowLimit).map(Self.text(for:))
        if !warnings.isEmpty {
            FormGroup(header: L.importWarningsHeader) {
                ForEach(Array(warnings.enumerated()), id: \.offset) { index, text in
                    if index > 0 { FormDivider() }
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.orange).font(.system(size: 11))
                        Text(text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 7)
                }
                moreRow(total: merge.warnings.count)
            }
        }
        let skippedTotal = merge.skippedAccounts.count + merge.skippedContacts.count
        if skippedTotal > 0 {
            FormGroup(header: "\(L.importSkippedHeader) · \(skippedTotal)") {
                ForEach(Array(skippedLines(merge).enumerated()), id: \.offset) { index, line in
                    if index > 0 { FormDivider() }
                    FormRow(label: line.0, help: line.1) { EmptyView() }
                }
                moreRow(total: skippedTotal)
            }
        }
        if merge.isEmpty {
            Text(L.importNothing).font(.system(size: 12)).foregroundStyle(Theme.label2).padding(.horizontal, 4)
        } else if merge.accounts.contains(where: { MicroSIPImport.needsPassword($0.config) }) {
            Text(L.importFooter).font(.system(size: 11.5)).foregroundStyle(Theme.label2)
                .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 4)
        }
    }

    private func skippedLines(_ merge: MicroSIPImport.Merge) -> [(String, String)] {
        func why(_ reason: MicroSIPImport.AccountSkipReason) -> String {
            reason == .duplicateOfExisting ? L.importAlready : L.importTwice
        }
        func whyContact(_ reason: MicroSIPImport.ContactSkipReason) -> String {
            reason == .duplicateOfExisting ? L.importAlready : L.importTwice
        }
        let accounts = merge.skippedAccounts.prefix(Self.rowLimit)
        let contacts = merge.skippedContacts.prefix(Self.rowLimit - accounts.count)
        return accounts.map { ("\($0.account.config.username)@\($0.account.config.domain)", why($0.reason)) }
            + contacts.map { ($0.contact.displayName, whyContact($0.reason)) }
    }

    private func reportBody(_ report: MicroSIPImportSession.Report) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.green)
                Text(L.importDoneBanner(accounts: report.accounts.count, contacts: report.contacts))
                    .font(.system(size: 12.5, weight: .semibold))
            }
            if !report.accounts.isEmpty {
                FormGroup(header: L.importCountAccounts(report.accounts.count)) {
                    ForEach(Array(report.accounts.prefix(Self.rowLimit).enumerated()), id: \.offset) { index, account in
                        if index > 0 { FormDivider() }
                        FormRow(label: account.name) {
                            if account.needsPassword {
                                Text(L.accountsNeedsPassword).font(.system(size: 11.5)).foregroundStyle(Theme.orange)
                            }
                        }
                    }
                    moreRow(total: report.accounts.count)
                }
                if report.firstAccount != nil {
                    Text(L.importNextSteps).font(.system(size: 11.5)).foregroundStyle(Theme.label2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, 4)
    }

    private func buttons(_ session: MicroSIPImportSession) -> some View {
        HStack(spacing: 8) {
            Spacer()
            if let report = session.report {
                if report.firstAccount != nil {
                    Button(L.importDone) { model.finishMicroSIPImport(openEditor: false) }.fixedSize()
                    Button(L.importEnterPassword) { model.finishMicroSIPImport(openEditor: true) }
                        .keyboardShortcut(.defaultAction).fixedSize()
                } else {
                    Button(L.importDone) { model.finishMicroSIPImport(openEditor: false) }
                        .keyboardShortcut(.defaultAction).fixedSize()
                }
            } else {
                Button(L.commonCancel) { model.cancelMicroSIPImport() }.keyboardShortcut(.cancelAction).fixedSize()
                switch session.outcome {
                case .loading:
                    Button(L.importButton) {}.disabled(true).fixedSize()
                case .failed:
                    Button(L.importChooseAnother) {
                        model.cancelMicroSIPImport()
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(450))
                            model.chooseMicroSIPFile()
                        }
                    }
                    .keyboardShortcut(.defaultAction).fixedSize()
                case let .preview(merge):
                    Button(L.importButton) { model.applyMicroSIPImport() }
                        .keyboardShortcut(.defaultAction).disabled(merge.isEmpty).fixedSize()
                }
            }
        }
        .padding(.horizontal, 22).padding(.vertical, 12)
    }

    // MARK: Texts

    static func text(for error: MicroSIPImport.ReadError) -> String {
        switch error {
        case .iniNotFound: return L.importErrorNotFound
        case .iniUnreadable: return L.importErrorUnreadable
        case let .iniTooLarge(bytes): return L.importErrorTooLarge(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))
        case .noAccountSections: return L.importErrorNoAccounts
        }
    }

    static func text(for warning: MicroSIPImport.Warning) -> String {
        switch warning {
        case let .accountSkippedMissingUsername(section): return L.importWarnNoUsername(section)
        case let .accountSkippedMissingDomain(section): return L.importWarnNoDomain(section)
        case let .unknownTransport(section, value): return L.importWarnTransport(section, value)
        case let .unknownSRTP(section, value): return L.importWarnSRTP(section, value)
        case let .dialRulesNotImported(section): return L.importWarnDialRules(section)
        case .contactsFileNotFound: return L.importWarnContactsNotFound
        case .contactsFileUnreadable: return L.importWarnContactsUnreadable
        case .contactsFileTooLarge: return L.importWarnContactsTooLarge
        case .contactsFileMalformed: return L.importWarnContactsMalformed
        case let .contactsSkippedWithoutNumber(count): return L.importWarnNoNumber(count)
        case let .contactsSkippedFromDirectory(count): return L.importWarnDirectory(count)
        case let .tooManyAccounts(limit): return L.importWarnTooManyAccounts(limit)
        case let .tooManyContacts(limit): return L.importWarnTooManyContacts(limit)
        }
    }
}
