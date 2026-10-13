import SwiftUI
import MacroSIPCore

/// 4.1 Transfer popover: target field with suggestions, Call First (attended) and Transfer Now (blind).
struct TransferPopover: View {
    @Environment(AppModel.self) private var model
    let call: CallInfo
    let dismiss: () -> Void
    @Local private var target = ""
    @Local private var highlighted = 0
    @FocusState private var focused: Bool

    private var matches: [Contact] {
        let q = target.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        return model.suggestions(for: q, limit: 5)
    }

    private var hasLetters: Bool { target.contains(where: \.isLetter) }
    private var resolvedTarget: String { resolvedTarget(matches) }
    private func resolvedTarget(_ matches: [Contact]) -> String {
        if hasLetters, !matches.isEmpty { return matches[min(highlighted, matches.count - 1)].defaultNumber?.value ?? target }
        return target
    }
    private func targetName(_ matches: [Contact]) -> String {
        let resolved = resolvedTarget(matches)
        if let c = matches.first(where: { $0.defaultNumber?.value == resolved }) { return c.displayName }
        return target.isEmpty ? L.transferTargetFallback : target
    }
    private var canAct: Bool { !target.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        // Computed once per body, from the contacts held in memory.
        let matches = self.matches
        let targetName = self.targetName(matches)
        VStack(alignment: .leading, spacing: 9) {
            Text(L.transferTitle(model.name(for: call.remote))).font(.system(size: 13, weight: .bold))
            TextField(L.transferPlaceholder, text: $target)
                .textFieldStyle(.plain)
                .focused($focused)
                .padding(.horizontal, 7).frame(height: 26)
                .fieldBackground(focused: focused)
                .onSubmit { if canAct { transferNow() } }
                .onKeyPress(.downArrow) { highlighted = min(highlighted + 1, max(0, matches.count - 1)); return .handled }
                .onKeyPress(.upArrow) { highlighted = max(0, highlighted - 1); return .handled }
                .onChange(of: target) { _, _ in highlighted = 0 }
            if !matches.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(matches.enumerated()), id: \.element.id) { index, c in
                        Button { target = c.defaultNumber?.value ?? ""; highlighted = 0 } label: {
                            HStack(spacing: 8) {
                                AvatarView(name: c.displayName, size: 20, contact: c)
                                Text(c.displayName).font(.system(size: 12.5)).lineLimit(1)
                                Spacer(minLength: 4)
                                Text(c.defaultNumber?.value ?? "").font(.system(size: 11.5)).foregroundStyle(index == highlighted && hasLetters ? .white.opacity(0.85) : Theme.label2)
                            }
                            .padding(.horizontal, 6).frame(height: 26)
                            .foregroundStyle(index == highlighted && hasLetters ? Color.white : Color.primary)
                            .background(RoundedRectangle(cornerRadius: 5).fill(index == highlighted && hasLetters ? Theme.blue : .clear))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            HStack(spacing: 8) {
                Spacer()
                Button(L.transferCallFirst) { callFirst() }
                    .disabled(!canAct)
                    .help(L.transferCallFirstHelp(targetName))
                Button(L.transferNow) { transferNow() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canAct)
                    .help(L.transferNowHelp)
            }
            Text(L.transferExplanation(targetName))
                .font(.system(size: 11))
                .foregroundStyle(Theme.label2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(width: 270)
        .onAppear { focused = true }
        .onKeyPress(.escape) { dismiss(); return .handled }
    }

    private func transferNow() {
        model.blindTransfer(call, to: resolvedTarget)
        dismiss()
    }

    private func callFirst() {
        model.startAttendedTransfer(call, to: resolvedTarget)
        dismiss()
    }
}
