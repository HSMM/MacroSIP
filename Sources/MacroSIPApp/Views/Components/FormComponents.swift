import SwiftUI

/// Grouped-form pattern of the Settings panes (SCREENS.md section 8): header, rounded box, footer.
struct FormGroup<Content: View>: View {
    var header: String?
    var footer: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let header {
                Text(header).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Theme.label2).padding(.horizontal, 10)
            }
            VStack(spacing: 0) { content }
                .background(RoundedRectangle(cornerRadius: 9).fill(Theme.groupBox))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.separator, lineWidth: 0.5))
            if let footer {
                Text(footer).font(.system(size: 11.5)).foregroundStyle(Theme.label2).padding(.horizontal, 10)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct FormRow<Control: View>: View {
    let label: String
    var help: String?
    @ViewBuilder var control: Control

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(.system(size: 13))
                if let help {
                    Text(help).font(.system(size: 11.5)).foregroundStyle(Theme.label2).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            control
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .frame(minHeight: 40)
    }
}

struct FormDivider: View {
    var body: some View { Divider().padding(.leading, 12).opacity(0.7) }
}

/// Pane body: grey background, 18 pt top and 22 pt side padding.
struct PaneContainer<Content: View>: View {
    var minHeight: CGFloat = 380
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 18) { content }
            .padding(.top, 18).padding(.bottom, 22).padding(.horizontal, 22)
            .frame(width: 620, alignment: .topLeading)
            .frame(minHeight: minHeight, alignment: .top)
            .fixedSize(horizontal: false, vertical: true)
            .background(Theme.groupBackground)
    }
}

/// Number field with up/down buttons. `step` maps a direction to the next valid value.
struct NumberStepperField: View {
    @Binding var value: Int
    var width: CGFloat = 70
    var isValid: (Int) -> Bool
    var step: (Int, Int) -> Int          // (current, direction) -> new
    @Local private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        let parsed = Int(text.trimmingCharacters(in: .whitespaces))
        let invalid = parsed.map { !isValid($0) } ?? true
        HStack(spacing: 4) {
            TextField("", text: $text)
                .textFieldStyle(.plain)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .focused($focused)
                .padding(.horizontal, 6)
                .frame(width: width, height: 22)
                .fieldBackground(focused: focused, invalid: invalid && focused)
                .onSubmit { commit() }
                .onChange(of: focused) { _, f in if !f { commit() } }
            VStack(spacing: 0) {
                Button { value = step(value, 1); text = "\(value)" } label: { Image(systemName: "chevron.up").font(.system(size: 7, weight: .bold)).frame(width: 13, height: 11) }
                Divider()
                Button { value = step(value, -1); text = "\(value)" } label: { Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold)).frame(width: 13, height: 10) }
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.label2)
            .background(RoundedRectangle(cornerRadius: 5).fill(Theme.control))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.controlBorder, lineWidth: 0.5))
            .frame(width: 13, height: 22)
            .clipShape(RoundedRectangle(cornerRadius: 5))
        }
        .onAppear { text = "\(value)" }
        .onChange(of: value) { _, v in if !focused { text = "\(v)" } }
    }

    private func commit() {
        if let v = Int(text.trimmingCharacters(in: .whitespaces)), isValid(v) { value = v }
        text = "\(value)"          // invalid input reverts on blur
    }
}

struct MeterView: View {
    let level: Float
    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<8, id: \.self) { i in
                let on = Float(i) < level * 8
                RoundedRectangle(cornerRadius: 1)
                    .fill(on ? (i == 7 ? Color(nsColor: .systemYellow) : Theme.green) : Theme.fill3)
                    .frame(width: 5, height: 9)
            }
        }
        .accessibilityHidden(true)
    }
}
