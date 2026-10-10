import SwiftUI

/// Screen 1: keypad, Call button and Delete.
struct DialpadView: View {
    @Environment(AppModel.self) private var model

    private let keys: [[Character]] = [["1", "2", "3"], ["4", "5", "6"], ["7", "8", "9"], ["*", "0", "#"]]

    var body: some View {
        VStack(spacing: 12) {
            Spacer(minLength: 0)
            VStack(spacing: 9) {
                ForEach(keys, id: \.self) { row in
                    HStack(spacing: 9) {
                        ForEach(row, id: \.self) { key in
                            DialKey(key: key, letters: L.keyLetters(key), height: 50) { text in
                                model.dialText.append(text)
                            }
                        }
                    }
                }
            }
            HStack {
                Color.clear.frame(maxWidth: .infinity)
                Button { model.placeCallFromField() } label: {
                    Image(systemName: "phone.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(.white)
                        .frame(width: 58, height: 58)
                        .background(Circle().fill(Theme.green))
                        .shadow(color: Theme.green.opacity(0.35), radius: 4, y: 2)
                }
                .buttonStyle(.plain)
                .disabled(model.dialText.trimmingCharacters(in: .whitespaces).isEmpty && model.lastDialedNumber == nil)
                .opacity(model.dialText.trimmingCharacters(in: .whitespaces).isEmpty && model.lastDialedNumber == nil ? 0.4 : 1)
                .help(L.dialpadCallHelp)
                .accessibilityLabel(L.dialpadCallHelp)
                Button { if !model.dialText.isEmpty { model.dialText.removeLast() } } label: {
                    Image(systemName: "delete.left")
                        .font(.system(size: 18))
                        .foregroundStyle(Theme.label2)
                        .frame(width: 36, height: 36)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(model.dialText.isEmpty)
                .opacity(model.dialText.isEmpty ? 0.4 : 1)
                .frame(maxWidth: .infinity)
                .help(L.dialpadDeleteHelp)
                .accessibilityLabel(L.dialpadDeleteHelp)
            }
            Text(L.dialpadHint)
                .font(.system(size: 11))
                .foregroundStyle(Theme.label2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
    }
}

/// One keypad key. Long-press on 0 inserts "+" instead of "0".
struct DialKey: View {
    let key: Character
    let letters: String
    let height: CGFloat
    let send: (String) -> Void
    @Local private var longPressed = false

    var body: some View {
        Button {
            if longPressed { longPressed = false; return }
            send(String(key))
        } label: {
            VStack(spacing: 2) {
                Text(String(key)).font(.system(size: 22)).frame(height: 24)
                Text(letters).font(.system(size: 8.5)).kerning(1.2).foregroundStyle(Theme.label2).frame(height: 10)
            }
            .frame(maxWidth: .infinity, minHeight: height, maxHeight: height)
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(KeyStyle(cornerRadius: 12))
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.5).onEnded { _ in
                guard key == "0" else { return }
                longPressed = true
                send("+")
            })
        .accessibilityLabel(String(key) + (letters.isEmpty ? "" : " " + letters))
    }
}

struct KeyStyle: ButtonStyle {
    var cornerRadius: CGFloat
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(RoundedRectangle(cornerRadius: cornerRadius).fill(configuration.isPressed ? Theme.fill3 : Theme.fill))
            .foregroundStyle(.primary)
    }
}
