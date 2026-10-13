import SwiftUI
import MacroSIPCore

/// Screen 2: search, grouped list, bottom bar, context menu, inline delete confirmation.
struct ContactsView: View {
    @Environment(AppModel.self) private var model
    @Local private var query = ""
    @Local private var selection: RowKey?
    @Local private var pendingDelete: UUID?
    @Local private var cache = SectionCache()
    @FocusState private var searchFocused: Bool
    @FocusState private var listFocused: Bool

    /// A contact can show twice (Favorites and its letter), so a row is told apart by section too.
    struct RowKey: Hashable {
        var id: UUID
        var favorite = false
    }

    fileprivate struct Section: Identifiable {
        let id: String
        let title: String
        let favorites: Bool
        let contacts: [Contact]
    }

    /// The filtered, sorted and grouped list, rebuilt only when the contacts, the search text or the sort order change.
    @MainActor
    fileprivate final class SectionCache {
        struct Key: Equatable { var revision: Int; var query: String; var sort: ContactSortOrder }
        var key: Key?
        var sections: [Section] = []
        var matchCount = 0
    }

    private var sort: ContactSortOrder { model.settings.general.contactSort }

    private var sections: [Section] {
        let key = SectionCache.Key(revision: model.contactsRevision, query: query, sort: sort)
        if cache.key == key { return cache.sections }
        let sorted = Contact.sorted(Contact.search(model.contacts, query: query), by: sort)
        var result: [Section] = []
        let favorites = sorted.filter(\.isFavorite)
        if !favorites.isEmpty {
            result.append(Section(id: "*favorites", title: L.contactsSectionFavorites, favorites: true, contacts: favorites))
        }
        let groups = Dictionary(grouping: sorted) { $0.sectionLetter(sort) }
        let letters = groups.keys.sorted { a, b in
            if a == "#" { return false }
            if b == "#" { return true }
            return a.localizedStandardCompare(b) == .orderedAscending
        }
        for letter in letters { result.append(Section(id: letter, title: letter, favorites: false, contacts: groups[letter]!)) }
        cache.key = key
        cache.sections = result
        cache.matchCount = sorted.count
        return result
    }

    /// Number of contacts that match the search.
    private var matchCount: Int { _ = sections; return cache.matchCount }

    private var selectedContact: Contact? { selection.flatMap { key in model.contacts.first { $0.id == key.id } } }

    private func openCard(_ contact: Contact?) {
        ContactCardController.shared.show(ContactEditorRequest(contact: contact), model: model)
    }

    private func toggleFavorite(_ c: Contact) {
        var copy = c
        copy.isFavorite.toggle()
        model.saveContact(copy)
    }

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
        .onChange(of: model.focusContactsSearch) { _, _ in searchFocused = true }
        .onChange(of: query) { _, _ in
            if let s = selection, !sections.contains(where: { $0.contacts.contains { $0.id == s.id } }) { selection = nil }
        }
    }

    @ViewBuilder
    private var listBody: some View {
        if matchCount == 0 {
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
                        ForEach(sections) { section in
                            sectionHeader(section)
                            ForEach(section.contacts) { c in
                                if pendingDelete == c.id { deleteStrip(c, favorite: section.favorites) }
                                else { row(c, favorite: section.favorites) }
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
                .onChange(of: selection) { _, key in if let key { proxy.scrollTo(key.favorite ? AnyHashable(key) : AnyHashable(key.id)) } }
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
                if press.characters == "e" { openCard(c) } else { copy(c) }
                return .handled
            }
            .onKeyPress(.delete, phases: .down) { press in
                guard press.modifiers.contains(.command), let c = selectedContact else { return .ignored }
                pendingDelete = c.id; return .handled
            }
        }
    }

    private func sectionHeader(_ section: Section) -> some View {
        HStack(spacing: 4) {
            if section.favorites { Image(systemName: "star.fill").font(.system(size: 9)).foregroundStyle(Theme.yellow) }
            Text(section.title).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.label2)
        }
        .padding(.horizontal, 15).padding(.top, 8).padding(.bottom, 3)
        .accessibilityAddTraits(.isHeader)
    }

    private func row(_ c: Contact, favorite: Bool) -> some View {
        let key = RowKey(id: c.id, favorite: favorite)
        return ContactRow(
            contact: c, selected: selection == key,
            onSelect: { selection = key; listFocused = true },
            onEdit: { openCard(c) },
            onToggleFavorite: { toggleFavorite(c) },
            onCopy: { copy(c) },
            onDelete: { pendingDelete = c.id })
        .id(favorite ? AnyHashable(key) : AnyHashable(c.id))
    }

    private func deleteStrip(_ c: Contact, favorite: Bool) -> some View {
        HStack(spacing: 8) {
            Text(L.contactsDeleteConfirm(c.displayName)).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
            Spacer()
            Button(L.commonCancel) { pendingDelete = nil }
                .controlSize(.small)
                .keyboardShortcut(.cancelAction)
            Button(L.commonDelete) {
                model.deleteContact(c.id)
                if selection?.id == c.id { selection = nil }
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
        .id(favorite ? AnyHashable(RowKey(id: c.id, favorite: true)) : AnyHashable(c.id))
    }

    private var countText: String {
        let favorites = model.contacts.filter(\.isFavorite).count
        let base = L.contactsCount(model.contacts.count)
        return favorites > 0 ? "\(base) · \(L.contactsFavoritesCount(favorites))" : base
    }

    private var bottomBar: some View {
        HStack(spacing: 0) {
            IconButton(systemName: "plus", help: L.contactsAddHelp) { openCard(nil) }
            Divider().frame(height: 14)
            IconButton(systemName: "minus", help: L.contactsDeleteHelp) { pendingDelete = selection?.id }
                .disabled(selection == nil).opacity(selection == nil ? 0.4 : 1)
            Divider().frame(height: 14)
            IconButton(systemName: "pencil", help: L.contactsEditHelp) { openCard(selectedContact) }
                .disabled(selection == nil).opacity(selection == nil ? 0.4 : 1)
            Spacer()
            Text(countText).font(.system(size: 11)).foregroundStyle(Theme.label2)
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
    }

    private func move(_ delta: Int) {
        let flat = sections.flatMap { s in s.contacts.map { RowKey(id: $0.id, favorite: s.favorites) } }
        guard !flat.isEmpty else { return }
        guard let current = selection, let i = flat.firstIndex(of: current) else {
            selection = delta > 0 ? flat.first : flat.last; return
        }
        selection = flat[max(0, min(flat.count - 1, i + delta))]
    }

    private func copy(_ c: Contact) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(c.defaultNumber?.value ?? "", forType: .string)
    }
}

/// 11 pt status dot on the avatar: green available, yellow away, red busy or DND, grey offline or unknown.
struct PresenceDot: View {
    let status: PresenceStatus?
    var ring: Color = Theme.content

    var body: some View {
        Circle()
            .fill(Self.color(status))
            .frame(width: 11, height: 11)
            .overlay(Circle().strokeBorder(ring, lineWidth: 2))
            .accessibilityHidden(true)
    }

    static func color(_ status: PresenceStatus?) -> Color {
        switch status {
        case .available: return Theme.green
        case .away: return Color(nsColor: .systemYellow)
        case .dnd: return Theme.red
        case .ringing: return Color(nsColor: .systemOrange)
        case .offline, nil: return Color(nsColor: .systemGray)
        }
    }

    /// nil while there is no answer yet.
    static func text(_ status: PresenceStatus) -> String? {
        switch status {
        case .available: return L.presenceAvailable
        case .away: return L.presenceAway
        case .dnd: return L.presenceDND
        case .ringing: return L.callRingingIn
        case .offline: return L.presenceOffline
        }
    }
}
