import SwiftUI
import MacroSIPCore

/// Settings › Calls › Incoming calls (SCREENS.md 8.7): the engine turns away calls from the chosen callers with
/// 603 Decline before they ring; the call log notes them as "Rejected: rule". "Numbers not in Contacts" compares
/// with `CallOptions.knownNumbers`, which `AppModel.syncKnownNumbers` keeps equal to the numbers of all contacts.
struct DenyIncomingGroup: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        FormGroup(header: L.denyHeader) {
            FormRow(label: L.denyLabel, help: L.denyHelp) {
                Picker("", selection: model.binding(\.callOptions.denyIncoming)) {
                    Text(L.denyNobody).tag(DenyIncoming.nobody)
                    Text(L.denyEveryone).tag(DenyIncoming.everyone)
                    Text(L.denyNotInContacts).tag(DenyIncoming.notInContacts)
                    Text(L.denyAnonymous).tag(DenyIncoming.anonymous)
                }
                .labelsHidden().frame(width: 220)
            }
        }
    }
}
