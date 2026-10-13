import SwiftUI

/// Screen 10: empty state while no account exists.
struct FirstLaunchView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 10) {
            Spacer()
            AppIconView(size: 64)
            Text(L.firstRunTitle)
                .font(.system(size: 17, weight: .bold))
                .multilineTextAlignment(.center)
            Text(L.firstRunBody)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.label2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 250)
                .fixedSize(horizontal: false, vertical: true)
            Button(L.firstRunAdd) { model.mainEditor = AccountEditorRequest(accountID: nil) }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .padding(.top, 4)
            Text(L.firstRunFootnote)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.label2)
                .padding(.top, 6)
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
