import SwiftUI
import MacroSIPCore

@main
struct MacroSIPApp: App {
    var body: some Scene {
        WindowGroup(Edition.current.productName) {
            PlaceholderView()
                .frame(minWidth: 340, minHeight: 520)
        }
        .windowResizability(.contentSize)
    }
}

/// Temporary content for milestone 1. Replaced by the real main window in milestone 3.
struct PlaceholderView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "phone.fill")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text(Edition.current.productName)
                .font(.title2.weight(.semibold))
            Text("Milestone 1 skeleton")
                .foregroundStyle(.secondary)
        }
        .padding(32)
    }
}
