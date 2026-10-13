import Foundation
import MacroSIPCore

/// Merges contacts imported from a directory source into the address book: matched by number, never
/// duplicated (SCREENS.md 13, "Import into Contacts").
enum DirectoryMerge {
    struct Result {
        /// Contacts that are new or changed, ready to be saved.
        var changed: [Contact] = []
        var added = 0
        var updated = 0
        var imported: Int { added + updated }
    }

    /// For each imported contact: the existing contact that has one of its numbers is updated, else a new card
    /// is added (owned by `source`). Two imported contacts that share a number end up in one card. A card the
    /// source created earlier (`importedFrom == source`) follows the directory: name, organization, e-mail and
    /// photo are replaced, numbers it lacks are added. Any other card belongs to the user: it only receives what
    /// it lacks (an empty name, organization or e-mail, a missing photo, new numbers). Notes, favourite and the
    /// preferred account are never touched.
    static func merge(_ imported: [Contact], into existing: [Contact], source: UUID) -> Result {
        var result = Result()
        var all = existing
        var byNumber: [String: Int] = [:]                    // normalized number -> index in `all`
        for (i, c) in all.enumerated() { for key in Set(c.allNormalizedNumbers) where byNumber[key] == nil { byNumber[key] = i } }
        var touched: [Int: Bool] = [:]                       // index -> was already in the address book
        let existingCount = existing.count

        for incoming in imported {
            let keys = incoming.allNormalizedNumbers
            guard !keys.isEmpty else { continue }            // no number, nothing to call
            if let i = keys.compactMap({ byNumber[$0] }).first {
                var card = all[i]
                if apply(incoming, to: &card, owned: card.importedFrom == source) {
                    all[i] = card
                    touched[i] = i < existingCount
                }
                for key in keys where byNumber[key] == nil { byNumber[key] = i }
            } else {
                var card = incoming
                card.id = UUID()
                card.importedFrom = source
                all.append(card)
                let i = all.count - 1
                touched[i] = false
                for key in keys where byNumber[key] == nil { byNumber[key] = i }
            }
        }
        for (i, wasThere) in touched.sorted(by: { $0.key < $1.key }) {
            result.changed.append(all[i])
            if wasThere { result.updated += 1 } else { result.added += 1 }
        }
        return result
    }

    /// Copies what the source knows onto `card`: everything when the card is `owned` by the source, only the
    /// blanks otherwise. True when something changed.
    private static func apply(_ incoming: Contact, to card: inout Contact, owned: Bool) -> Bool {
        var changed = false
        let first = incoming.firstName.trimmingCharacters(in: .whitespaces)
        let last = incoming.lastName.trimmingCharacters(in: .whitespaces)
        let nameBlank = card.firstName.trimmingCharacters(in: .whitespaces).isEmpty && card.lastName.trimmingCharacters(in: .whitespaces).isEmpty
        if (!first.isEmpty || !last.isEmpty), owned || nameBlank, card.firstName != first || card.lastName != last {
            card.firstName = first
            card.lastName = last
            changed = true
        }
        let org = incoming.organization.trimmingCharacters(in: .whitespaces)
        if !org.isEmpty, owned || card.organization.trimmingCharacters(in: .whitespaces).isEmpty, card.organization != org {
            card.organization = org; changed = true
        }
        let email = incoming.email.trimmingCharacters(in: .whitespaces)
        if !email.isEmpty, owned || card.email.trimmingCharacters(in: .whitespaces).isEmpty, card.email != email {
            card.email = email; changed = true
        }
        if let photo = incoming.photo, owned || card.photo == nil, card.photo != photo { card.photo = photo; changed = true }
        let have = Set(card.allNormalizedNumbers)
        for n in incoming.numbers where !have.contains(Contact.normalize(n.value)) && !Contact.normalize(n.value).isEmpty {
            card.numbers.append(PhoneNumber(label: n.label, value: n.value, isDefault: card.numbers.isEmpty))
            changed = true
        }
        return changed
    }
}
