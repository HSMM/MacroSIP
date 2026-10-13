import SwiftUI
import AppKit
import MacroSIPCore

/// The dropdown under the number field (screen 1 Q1.1 and screen 13 A): local contacts, then a
/// "Directory" section with the results of each source, then the "Searching <source>…" rows or the count.
struct SuggestionList: View {
    @Environment(AppModel.self) private var model
    let local: [Contact]
    let sections: [DirectorySection]
    let pending: [DirectorySource]
    let highlighted: String?
    let query: String
    let fill: (SuggestionRow) -> Void
    let call: (SuggestionRow) -> Void

    private static let rowHeight: CGFloat = 27
    private static let maxHeight: CGFloat = 340

    private var entryCount: Int { sections.reduce(0) { $0 + $1.entries.count } }
    private var hasDirectory: Bool { !sections.isEmpty || !pending.isEmpty }

    private var estimatedHeight: CGFloat {
        let rows = CGFloat(local.count + entryCount)
        let headers: CGFloat = hasDirectory ? (local.isEmpty ? 1 : 2) * 20 : 0
        let footer: CGFloat = hasDirectory ? CGFloat(max(pending.count, 1)) * 22 : 0
        return rows * Self.rowHeight + headers + footer + 6
    }

    var body: some View {
        let content = rowsView
        Group {
            if estimatedHeight > Self.maxHeight {
                ScrollViewReader { proxy in
                    ScrollView { content }
                        .frame(height: Self.maxHeight)
                        .onChange(of: highlighted) { _, id in if let id { proxy.scrollTo(id) } }
                }
            } else {
                content
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.separator))
        .shadow(color: .black.opacity(0.2), radius: 8, y: 3)
    }

    private var rowsView: some View {
        VStack(spacing: 0) {
            if hasDirectory && !local.isEmpty { header(L.directorySectionContacts) }
            ForEach(local) { c in
                let row = SuggestionRow.contact(c)
                SuggestionRowView(row: row, query: query, isHighlighted: highlighted == row.id, badge: nil,
                                  fill: fill, call: call)
                    .id(row.id)
            }
            if hasDirectory && (!sections.isEmpty || !local.isEmpty) && !sections.isEmpty { header(L.directorySectionDirectory) }
            ForEach(sections) { section in
                ForEach(section.entries) { e in
                    let row = SuggestionRow.entry(e)
                    SuggestionRowView(row: row, query: query, isHighlighted: highlighted == row.id,
                                      badge: DirectoryBadge.title(for: section.sourceKind), fill: fill, call: call)
                        .id(row.id)
                }
            }
            footer
        }
        .padding(3)
    }

    private func header(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Theme.label2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8).padding(.top, 4).padding(.bottom, 1)
    }

    @ViewBuilder
    private var footer: some View {
        if !pending.isEmpty {
            ForEach(pending) { source in
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 14, height: 14)
                    Text(L.directorySearching(source.shownName)).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .font(.system(size: 11.5)).foregroundStyle(Theme.label2)
                .padding(.horizontal, 8).frame(height: 22)
                .accessibilityElement(children: .combine)
            }
        } else if !sections.isEmpty {
            Text("\(L.directoryResultsCount(entryCount)) \(L.directoryResultsSources(sections.count))")
                .font(.system(size: 11.5)).foregroundStyle(Theme.label2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8).frame(height: 22)
        }
    }
}

/// Short source tag shown on a result (LDAP, URL, Google, Contacts).
enum DirectoryBadge {
    static func title(for kind: DirectorySourceKind) -> String {
        switch kind {
        case .ldap: return L.directoryBadgeLDAP
        case .url: return L.directoryBadgeURL
        case .google: return L.directoryBadgeGoogle
        case .macContacts: return L.directoryBadgeContacts
        }
    }
}

private struct SuggestionRowView: View {
    @Environment(AppModel.self) private var model
    let row: SuggestionRow
    let query: String
    let isHighlighted: Bool
    let badge: String?
    let fill: (SuggestionRow) -> Void
    let call: (SuggestionRow) -> Void

    var body: some View {
        Button { fill(row) } label: {
            HStack(spacing: 8) {
                avatar
                Text(SuggestionHighlight.attributed(name, matching: query))
                    .font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                Spacer(minLength: 4)
                Text(numberText).font(.system(size: 11.5)).foregroundStyle(Theme.label2).lineLimit(1).layoutPriority(1)
                if let badge {
                    Text(badge)
                        .font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.label2)
                        .padding(.horizontal, 4).frame(height: 14).fixedSize()
                        .background(RoundedRectangle(cornerRadius: 3.5).fill(Theme.fill2))
                } else if isHighlighted {
                    Text("↩").font(.system(size: 11)).foregroundStyle(Theme.label2)
                }
            }
            .padding(.horizontal, 8).frame(height: 27)
            .background(RoundedRectangle(cornerRadius: 5).fill(isHighlighted ? Theme.blueTint : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(L.directoryMenuCall) { call(row) }
            Button(L.directoryMenuCopy) { if let n = row.number { model.copyToPasteboard(n) } }
            if case let .entry(e) = row { Button(L.directoryMenuAdd) { model.addToContacts(e) } }
        }
        .accessibilityLabel("\(name), \(numberText)")
    }

    private var name: String {
        switch row {
        case let .contact(c): return c.displayName
        case let .entry(e): return e.displayName
        }
    }

    private var numberText: String {
        switch row {
        case let .contact(c): return c.defaultNumber?.value ?? ""
        case let .entry(e):
            return e.defaultNumber?.value ?? ""
        }
    }

    @ViewBuilder
    private var avatar: some View {
        switch row {
        case let .contact(c): AvatarView(name: c.displayName, size: 22, contact: c)
        case let .entry(e): DirectoryAvatar(entry: e, size: 22)
        }
    }
}

/// Bold letters where the typed text matches the name.
enum SuggestionHighlight {
    static func attributed(_ name: String, matching query: String) -> AttributedString {
        var out = AttributedString(name)
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 1, q.contains(where: \.isLetter),
              let range = name.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]),
              let lower = AttributedString.Index(range.lowerBound, within: out),
              let upper = AttributedString.Index(range.upperBound, within: out) else { return out }
        out[lower..<upper].font = .system(size: 12.5, weight: .bold)
        return out
    }
}

/// Photo of a directory result (macOS Contacts has them), else initials.
struct DirectoryAvatar: View {
    let entry: DirectoryEntry
    var size: CGFloat = 22

    var body: some View {
        if let data = entry.photo, let image = DirectoryPhotoCache.image(key: "\(entry.sourceID.uuidString)/\(entry.id)", data: data) {
            Image(nsImage: image)
                .resizable().scaledToFill()
                .frame(width: size, height: size)
                .clipShape(Circle())
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
                .accessibilityHidden(true)
        } else {
            AvatarView(name: entry.displayName, size: size)
        }
    }
}

@MainActor
enum DirectoryPhotoCache {
    private final class Entry {
        let data: Data
        let image: NSImage
        init(data: Data, image: NSImage) { self.data = data; self.image = image }
    }
    private static let cache = NSCache<NSString, Entry>()

    static func image(key: String, data: Data) -> NSImage? {
        if let hit = cache.object(forKey: key as NSString), hit.data == data { return hit.image }
        guard let image = NSImage(data: data) else { return nil }
        cache.setObject(Entry(data: data, image: image), forKey: key as NSString)
        return image
    }
}
