import SwiftUI
import MacroSIPCore

/// Settings › Directory › Contacts (SCREENS.md 8.1 and 13): sort order of the contact list. Included at the top of
/// `DirectoryPane`.
struct ContactsSortGroup: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        FormGroup(header: L.settingsContactsHeader, footer: L.settingsContactSortFooter) {
            FormRow(label: L.settingsContactSort) {
                Picker("", selection: model.binding(\.general.contactSort)) {
                    Text(L.settingsContactSortFirst).tag(ContactSortOrder.firstName)
                    Text(L.settingsContactSortLast).tag(ContactSortOrder.lastName)
                }
                .labelsHidden().pickerStyle(.segmented).frame(width: 190)
            }
        }
    }
}
