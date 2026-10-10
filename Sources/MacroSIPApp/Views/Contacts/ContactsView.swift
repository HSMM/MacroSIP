import SwiftUI
import MacroSIPCore

struct ContactEditorRequest: Identifiable {
    let id = UUID()
    var contact: Contact?
    var prefillName = ""
    var prefillNumber = ""
}

/// Screen 2: search, grouped list, bottom bar, context menu, inline delete confirmation.
struct ContactsView: View {
    @Environment(AppModel.self) private var model
    @Local private var query = ""
    @Local private var selection: UUID?
    @Local private var pendingDelete: UUID?
    @Local private var editor: ContactEditorRequest?
    @Local private var hovered: UUID?
    @FocusState private var searchFocused: Bool
    @FocusState private var listFocused: Bool

    private var filtered: [Contact] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return model.contacts }
        let nq = Contact.normalize(q)
        return model.contacts.filter {
            $0.name.lowercased().contains(q) || $0.number.lowercased().contains(q)
                || (!nq.isEmpty && $0.normalizedNumber.contains(nq))
        }
    }

    private var sections: [(String, [Contact])] {
        let groups = Dictionary(grouping: filtered) { c -> String in
            guard let ch = c.name.first, ch.isLetter else { return "#" }
            return String(ch).uppercased()
        }
        return groups.keys.sorted { a, b in
            if a == "#" { return false }
            if b == "#" { return true }
            return a.localizedStandardCompare(b) == .orderedAscending
        }.map { ($0, groups[$0]!.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }) }
    }

    private var selectedContact: Contact? { selection.flatMap { id in model.contacts.first { $0.id == id } } }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(Theme.label2)
                TextField(L.contactsSearch, text: $query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onKeyPress(.escape) {
                        if query.isEmpty { listFocused = true; return .handled }
                        query = ""; return .handled
                    }
                    .onKeyPress(.upArrow) { move(-1); return .handled }
                    .onKeyPress(.downArrow) { move(1); return .handled }
                    .onSubmit { if let c = selectedContact { model.placeCall(to: c) } }
            }
            .padding(.horizontal, 8).frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.fill))
            .padding(8)
            Divider()
            listBody
            Divider()
            bottomBar
        }
        .sheet(item: $editor) { request in ContactSheet(request: request) }
        .onChange(of: model.focusContactsSearch) { _, _ in searchFocused = true }
        .onChange(of: query) { _, _ in
            if let s = selection, !filtered.contains(where: { $0.id == s }) { selection = nil }
        }
    }

    @ViewBuilder
    private var listBody: some View {
        if filtered.isEmpty {
            VStack(spacing: 4) {
                Spacer()
                Text(model.contacts.isEmpty ? L.contactsEmptyTitle : L.contactsNoResults)
                    .font(.system(size: 13, weight: .semibold))
                if model.contacts.isEmpty {
                    Text(L.contactsEmptyBody).font(.system(size: 12)).foregroundStyle(Theme.label2)
                }
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: []) {
                        ForEach(sections, id: \.0) { letter, contacts in
                            Text(letter).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.label2)
                                .padding(.horizontal, 15).padding(.top, 8).padding(.bottom, 3)
                            ForEach(contacts) { c in
                                if pendingDelete == c.id { deleteStrip(c) } else { row(c) }
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
                .onChange(of: selection) { _, id in if let id { proxy.scrollTo(id) } }
            }
            .focusable()
            .focused($listFocused)
            .focusEffectDisabled()
            .onKeyPress(.return) {
                guard let c = selectedContact else { return .ignored }
                model.placeCall(to: c); return .handled
            }
            .onKeyPress(.upArrow) { move(-1); return .handled }
            .onKeyPress(.downArrow) { move(1); return .handled }
            .onKeyPress(characters: CharacterSet(charactersIn: "ec"), phases: .down) { press in
                guard press.modifiers == .command, let c = selectedContact else { return .ignored }
                if press.characters == "e" { editor = ContactEditorRequest(contact: c) }
                else { copy(c) }
                return .handled
            }
            .onKeyPress(.delete, phases: .down) { press in
                guard press.modifiers.contains(.command), let c = selectedContact else { return .ignored }
                pendingDelete = c.id; return .handled
            }
        }
    }

    private func row(_ c: Contact) -> some View {
        let selected = selection == c.id
        return HStack(spacing: 9) {
            AvatarView(name: c.name, size: 32)
            VStack(alignment: .leading, spacing: 0) {
                Text(c.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text(c.number).font(.system(size: 11.5))
                    .foregroundStyle(selected ? Color.white.opacity(0.8) : Theme.label2).lineLimit(1)
            }
            Spacer(minLength: 4)
            if selected || hovered == c.id {
                Button { model.placeCall(to: c) } label: {
                    Image(systemName: "phone.fill").font(.system(size: 11))
                        .foregroundStyle(Theme.green)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(selected ? Color.white : Theme.fill))
                }
                .buttonStyle(.plain)
                .help(L.contactsMenuCall)
                .accessibilityLabel(L.contactsMenuCall)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .frame(minHeight: 44)
        .foregroundStyle(selected ? Color.white : Color.primary)
        .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Theme.blue : (hovered == c.id ? Theme.fill : .clear)))
        .padding(.horizontal, 5)
        .contentShape(Rectangle())
        .onHover { inside in hovered = inside ? c.id : (hovered == c.id ? nil : hovered) }
        .onTapGesture(count: 2) { model.placeCall(to: c) }
        .onTapGesture { selection = c.id; listFocused = true }
        .contextMenu {
            Button(L.contactsMenuCall) { model.placeCall(to: c) }
            Menu(L.contactsMenuCallFrom) {
                ForEach(model.enabledAccounts) { a in
                    Button(a.displayName) { model.placeCall(to: c, account: a.id) }
                }
            }
            Button(L.contactsMenuCopy) { copy(c) }.keyboardShortcut("c", modifiers: .command)
            Divider()
            Button(L.contactsMenuEdit) { editor = ContactEditorRequest(contact: c) }.keyboardShortcut("e", modifiers: .command)
            Divider()
            Button(L.contactsMenuDelete, role: .destructive) { pendingDelete = c.id }
                .keyboardShortcut(.delete, modifiers: .command)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(c.name), \(c.number)")
        .id(c.id)
    }

    private func deleteStrip(_ c: Contact) -> some View {
        HStack(spacing: 8) {
            Text(L.contactsDeleteConfirm(c.name)).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
            Spacer()
            Button(L.commonCancel) { pendingDelete = nil }
                .controlSize(.small)
                .keyboardShortcut(.cancelAction)
            Button(L.commonDelete) {
                model.deleteContact(c.id)
                if selection == c.id { selection = nil }
                pendingDelete = nil
            }
            .controlSize(.small)
            .tint(Theme.red)
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 10).frame(minHeight: 44)
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.red.opacity(0.12)))
        .padding(.horizontal, 5)
        .id(c.id)
    }

    private var bottomBar: some View {
        HStack(spacing: 0) {
            IconButton(systemName: "plus", help: L.contactsAddHelp) { editor = ContactEditorRequest(contact: nil) }
            Divider().frame(height: 14)
            IconButton(systemName: "minus", help: L.contactsDeleteHelp) { pendingDelete = selection }
                .disabled(selection == nil).opacity(selection == nil ? 0.4 : 1)
            Divider().frame(height: 14)
            IconButton(systemName: "pencil", help: L.contactsEditHelp) {
                if let c = selectedContact { editor = ContactEditorRequest(contact: c) }
            }
            .disabled(selection == nil).opacity(selection == nil ? 0.4 : 1)
            Spacer()
            Text(L.contactsCount(model.contacts.count)).font(.system(size: 11)).foregroundStyle(Theme.label2)
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
    }

    private func move(_ delta: Int) {
        let flat = sections.flatMap(\.1)
        guard !flat.isEmpty else { return }
        guard let current = selection, let i = flat.firstIndex(where: { $0.id == current }) else {
            selection = (delta > 0 ? flat.first : flat.last)?.id; return
        }
        selection = flat[max(0, min(flat.count - 1, i + delta))].id
    }

    private func copy(_ c: Contact) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(c.number, forType: .string)
    }
}

/// Edit / New Contact sheet, 320 pt wide.
struct ContactSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: ContactEditorRequest
    @Local private var name = ""
    @Local private var number = ""
    @Local private var accountID: AccountID?
    @FocusState private var focus: Field?
    private enum Field { case name, number }

    private var valid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && !number.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(request.contact == nil ? L.contactNewTitle : L.contactEditTitle).font(.system(size: 13, weight: .bold))
            VStack(spacing: 8) {
                labeled(L.contactName) {
                    TextField("", text: $name).textFieldStyle(.roundedBorder).focused($focus, equals: .name)
                }
                labeled(L.contactNumber) {
                    TextField("", text: $number).textFieldStyle(.roundedBorder).focused($focus, equals: .number)
                }
                labeled(L.contactAccount) {
                    Picker("", selection: $accountID) {
                        Text(L.contactAccountAny).tag(AccountID?.none)
                        ForEach(model.enabledAccounts) { a in Text(a.displayName).tag(AccountID?.some(a.id)) }
                    }
                    .labelsHidden()
                }
            }
            HStack {
                Spacer()
                Button(L.commonCancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L.commonSave) { save() }.keyboardShortcut(.defaultAction).disabled(!valid)
            }
        }
        .padding(16)
        .frame(width: 320)
        .onAppear {
            if let c = request.contact {
                name = c.name; number = c.number; accountID = c.preferredAccountID
            } else {
                name = request.prefillName; number = request.prefillNumber
            }
            focus = .name
        }
    }

    private func labeled<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        HStack {
            Text(title).font(.system(size: 12)).foregroundStyle(Theme.label2).frame(width: 60, alignment: .trailing)
            content()
        }
    }

    private func save() {
        var c = request.contact ?? Contact(name: "", number: "")
        c.name = name.trimmingCharacters(in: .whitespaces)
        c.number = number.trimmingCharacters(in: .whitespaces)
        c.preferredAccountID = accountID
        model.saveContact(c)
        dismiss()
    }
}
