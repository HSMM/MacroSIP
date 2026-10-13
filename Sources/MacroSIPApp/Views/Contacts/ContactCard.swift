import SwiftUI
import AppKit
import UniformTypeIdentifiers
import MacroSIPCore

struct ContactEditorRequest: Identifiable {
    let id = UUID()
    var contact: Contact?
    var prefillName = ""
    var prefillNumber = ""
}

/// Panel window of the contact card (SCREENS.md 12). The card is 500 pt wide, wider than the main
/// window, so it is a window of its own and not a sheet. One card at a time; asking for another
/// brings the open one forward.
final class ContactCardPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { close() }
}

@MainActor
final class ContactCardController: NSObject, NSWindowDelegate {
    static let shared = ContactCardController()

    private(set) var panel: ContactCardPanel?

    var isOpen: Bool { panel?.isVisible ?? false }

    func show(_ request: ContactEditorRequest, model: AppModel) {
        if let panel, panel.isVisible {
            panel.makeKeyAndOrderFront(nil)
            return
        }
        let host = NSHostingController(rootView: ContactCardView(request: request, close: { [weak self] in self?.close() })
            .environment(model))
        let panel = ContactCardPanel(
            contentRect: NSRect(x: 0, y: 0, width: ContactCardView.width, height: 560),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered, defer: false)
        panel.contentViewController = host
        panel.title = request.contact == nil ? L.contactNewTitle : L.contactEditTitle
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = false
        panel.delegate = self
        panel.collectionBehavior = [.fullScreenAuxiliary]
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }
        host.view.layoutSubtreeIfNeeded()
        panel.setContentSize(NSSize(width: ContactCardView.width, height: host.view.fittingSize.height))
        center(panel, over: model.mainWindow)
        self.panel = panel
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        panel?.orderOut(nil)
        panel = nil
    }

    func windowWillClose(_ notification: Notification) { panel = nil }

    private func center(_ panel: NSPanel, over main: NSWindow?) {
        guard let main, main.isVisible else { panel.center(); return }
        var frame = panel.frame
        frame.origin.x = main.frame.midX - frame.width / 2
        frame.origin.y = main.frame.maxY - frame.height - 40
        if let visible = main.screen?.visibleFrame {
            frame.origin.x = min(max(frame.origin.x, visible.minX + 8), visible.maxX - frame.width - 8)
            frame.origin.y = max(frame.origin.y, visible.minY + 8)
        }
        panel.setFrame(frame, display: false)
    }
}

/// Edit / New Contact card.
struct ContactCardView: View {
    static let width: CGFloat = 500

    @Environment(AppModel.self) private var model
    let request: ContactEditorRequest
    let close: () -> Void

    private struct NumberDraft: Identifiable {
        let id = UUID()
        var label: PhoneLabel
        var value: String
        var isDefault: Bool
    }

    @Local private var firstName = ""
    @Local private var lastName = ""
    @Local private var organization = ""
    @Local private var rows: [NumberDraft] = []
    @Local private var email = ""
    @Local private var notes = ""
    @Local private var favorite = false
    @Local private var photo: Data?
    @Local private var accountID: AccountID?
    @Local private var watch = false
    @Local private var loaded = false
    /// Id of the contact this card creates (also the key of its photo in the avatar cache).
    @Local private var newID = UUID()
    @FocusState private var focus: Field?
    private enum Field: Hashable { case first, row(UUID) }

    private func filled(_ s: String) -> Bool { !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private var valid: Bool {
        filled(firstName) || filled(lastName) || filled(organization) || rows.contains { filled($0.value) }
    }

    private var draft: Contact {
        Contact(firstName: firstName, lastName: lastName, organization: organization,
                numbers: rows.map { PhoneNumber(label: $0.label, value: $0.value, isDefault: $0.isDefault) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            titleRow
            identity
            phoneNumbers
            details
            notesField
            HStack {
                Spacer()
                Button(L.commonCancel) { close() }.keyboardShortcut(.cancelAction)
                Button(L.commonSave) { save() }.keyboardShortcut(.defaultAction).disabled(!valid)
            }
        }
        .padding(.horizontal, 20).padding(.top, 6).padding(.bottom, 16)
        .frame(width: Self.width)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear(perform: load)
    }

    // MARK: Sections

    private var titleRow: some View {
        HStack(spacing: 6) {
            Text(request.contact == nil ? L.contactNewTitle : L.contactEditTitle).font(.system(size: 13, weight: .bold))
            Spacer()
            Button { favorite.toggle() } label: {
                HStack(spacing: 4) {
                    Image(systemName: favorite ? "star.fill" : "star")
                        .font(.system(size: 14))
                        .foregroundStyle(favorite ? Theme.yellow : Theme.label2)
                    Text(L.contactFavorite).font(.system(size: 12)).foregroundStyle(Theme.label2)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L.contactFavorite)
            .accessibilityLabel(L.contactFavorite)
            .accessibilityValue(favorite ? "1" : "0")
        }
    }

    private var identity: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(spacing: 8) {
                AvatarView(name: draft.displayName, size: 64, photo: photo, photoID: request.contact?.id ?? newID)
                    .contextMenu {
                        if photo != nil { Button(L.contactPhotoRemove) { photo = nil } }
                    }
                Button(L.contactPhotoChoose) { choosePhoto() }.controlSize(.small)
            }
            .frame(width: 76)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    labeled(L.contactFirstName) {
                        TextField("", text: $firstName).textFieldStyle(.roundedBorder).focused($focus, equals: .first)
                    }
                    labeled(L.contactLastName) { TextField("", text: $lastName).textFieldStyle(.roundedBorder) }
                }
                labeled(L.contactOrganization) { TextField("", text: $organization).textFieldStyle(.roundedBorder) }
            }
        }
    }

    private var phoneNumbers: some View {
        FormGroup(header: L.contactNumbersHeader, content: {
            VStack(spacing: 6) {
                ForEach($rows) { $row in numberRow($row) }
                HStack {
                    Button { addRow() } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "plus.circle.fill").foregroundStyle(Theme.blue)
                            Text(L.contactNumbersAdd)
                        }
                        .font(.system(size: 12.5))
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
                .padding(.top, 2)
            }
            .padding(10)
        }, footerView: { Text(L.contactNumbersHint).fixedSize(horizontal: false, vertical: true) })
    }

    private func numberRow(_ row: Binding<NumberDraft>) -> some View {
        HStack(spacing: 8) {
            Picker("", selection: row.label) {
                ForEach(PhoneLabel.allCases, id: \.self) { Text(L.phoneLabel($0)).tag($0) }
            }
            .labelsHidden().frame(width: 120)
            TextField("", text: row.value)
                .textFieldStyle(.roundedBorder)
                .monospacedDigit()
                .focused($focus, equals: .row(row.wrappedValue.id))
            Button { setDefault(row.wrappedValue.id) } label: {
                HStack(spacing: 4) {
                    Image(systemName: row.wrappedValue.isDefault ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(row.wrappedValue.isDefault ? Theme.blue : Theme.label2)
                    Text(L.contactNumbersDefault).font(.system(size: 12))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L.contactNumbersDefault)
            .accessibilityValue(row.wrappedValue.isDefault ? "1" : "0")
            Button { removeRow(row.wrappedValue.id) } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.label3)
            }
            .buttonStyle(.plain)
            .disabled(rows.count <= 1)
            .opacity(rows.count <= 1 ? 0.35 : 1)
            .help(L.contactNumbersRemove)
            .accessibilityLabel(L.contactNumbersRemove)
        }
    }

    private var details: some View {
        FormGroup {
            FormRow(label: L.contactEmail) {
                TextField("", text: $email).textFieldStyle(.roundedBorder).frame(width: 260)
            }
            FormDivider()
            FormRow(label: L.contactAccount,
                    help: filled(draft.displayName) ? L.contactAccountSub(draft.displayName) : L.contactAccountSubNoName) {
                Picker("", selection: $accountID) {
                    Text(L.contactAccountAny).tag(AccountID?.none)
                    ForEach(model.enabledAccounts) { a in Text(a.displayName).tag(AccountID?.some(a.id)) }
                }
                .labelsHidden().frame(width: 190)
            }
            FormDivider()
            FormRow(label: L.contactWatchPresence, help: L.contactPresenceSub) {
                Toggle("", isOn: $watch).labelsHidden().toggleStyle(.checkbox)
            }
        }
    }

    private var notesField: some View {
        FormGroup(header: L.contactNotes) {
            TextEditor(text: $notes)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 6).padding(.vertical, 4)
                .frame(height: CGFloat(notesLines) * 16 + 12)
        }
    }

    /// 3 lines, growing to 6.
    private var notesLines: Int {
        let lines = notes.split(separator: "\n", omittingEmptySubsequences: false)
            .reduce(0) { $0 + max(1, ($1.count + 63) / 64) }
        return min(6, max(3, lines))
    }

    private func labeled<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 11.5)).foregroundStyle(Theme.label2)
            content()
        }
    }

    // MARK: Actions

    private func load() {
        guard !loaded else { return }
        loaded = true
        if let c = request.contact {
            firstName = c.firstName; lastName = c.lastName; organization = c.organization
            rows = c.numbers.map { NumberDraft(label: $0.label, value: $0.value, isDefault: $0.isDefault) }
            email = c.email; notes = c.notes; favorite = c.isFavorite; photo = c.photo
            accountID = c.preferredAccountID; watch = c.subscribePresence
        } else {
            (firstName, lastName) = Contact.splitName(request.prefillName)
            let n = request.prefillNumber.trimmingCharacters(in: .whitespaces)
            rows = [NumberDraft(label: n.lowercased().hasPrefix("sip:") ? .sip : .work, value: n, isDefault: true)]
        }
        if rows.isEmpty { rows = [NumberDraft(label: .work, value: "", isDefault: true)] }
        if !rows.contains(where: \.isDefault) { rows[0].isDefault = true }
        focus = .first
    }

    private func addRow() {
        let used = Set(rows.map(\.label))
        let label = PhoneLabel.allCases.first { !used.contains($0) } ?? .work
        let row = NumberDraft(label: label, value: "", isDefault: rows.isEmpty)
        rows.append(row)
        focus = .row(row.id)
    }

    private func removeRow(_ id: UUID) {
        guard rows.count > 1, let i = rows.firstIndex(where: { $0.id == id }) else { return }
        let wasDefault = rows[i].isDefault
        rows.remove(at: i)
        if wasDefault { rows[0].isDefault = true }
    }

    private func setDefault(_ id: UUID) {
        for i in rows.indices { rows[i].isDefault = rows[i].id == id }
    }

    private func choosePhoto() {
        let open = NSOpenPanel()
        open.allowedContentTypes = [.image]
        open.allowsMultipleSelection = false
        open.canChooseDirectories = false
        open.begin { response in
            guard response == .OK, let url = open.url else { return }
            // Reading and scaling a large picture must not block the card.
            Task { @MainActor in
                let jpeg = await Task.detached(priority: .userInitiated) { () -> Data? in
                    guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
                    return ContactPhoto.jpeg(from: data)
                }.value
                if let jpeg { photo = jpeg }
            }
        }
    }

    /// Saves onto the contact as stored now: only what this card changed is applied, so a change made elsewhere
    /// while the card was open (a favourite toggled in the list, say) is kept. A contact deleted meanwhile is created again.
    private func save() {
        guard valid else { return }
        var numbers = rows
            .map { NumberDraft(label: $0.label, value: $0.value.trimmingCharacters(in: .whitespacesAndNewlines), isDefault: $0.isDefault) }
            .filter { !$0.value.isEmpty }
        if !numbers.isEmpty, !numbers.contains(where: \.isDefault) { numbers[0].isDefault = true }
        let trim: (String) -> String = { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let edited = Contact(
            id: request.contact?.id ?? newID,
            firstName: trim(firstName), lastName: trim(lastName), organization: trim(organization),
            numbers: numbers.map { PhoneNumber(label: $0.label, value: $0.value, isDefault: $0.isDefault) },
            email: trim(email), notes: notes, isFavorite: favorite, photo: photo,
            preferredAccountID: accountID, subscribePresence: watch && !numbers.isEmpty)
        let opened = request.contact
        var c = opened.flatMap { o in model.contacts.first { $0.id == o.id } } ?? opened ?? edited
        func apply<T: Equatable>(_ path: WritableKeyPath<Contact, T>) {
            if opened == nil || edited[keyPath: path] != opened![keyPath: path] { c[keyPath: path] = edited[keyPath: path] }
        }
        apply(\.firstName); apply(\.lastName); apply(\.organization); apply(\.numbers); apply(\.email)
        apply(\.notes); apply(\.isFavorite); apply(\.photo); apply(\.preferredAccountID); apply(\.subscribePresence)
        if opened == nil { c.id = newID }
        model.saveContact(c)
        close()
    }
}
