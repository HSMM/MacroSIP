import SwiftUI
import AppKit

// Tokens taken from docs/design/mockups.html (macOS mock tokens), expressed with adaptive colours.
extension Color {
    init(light: Color, dark: Color) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(dark) : NSColor(light)
        })
    }
}

enum Theme {
    static let fill = Color.primary.opacity(0.06)
    static let fill2 = Color.primary.opacity(0.10)
    static let fill3 = Color.primary.opacity(0.15)
    static let separator = Color.primary.opacity(0.10)
    static let label2 = Color.primary.opacity(0.56)
    static let label3 = Color.primary.opacity(0.30)
    static let blue = Color(nsColor: .controlAccentColor)
    static let blueTint = Color(nsColor: .controlAccentColor).opacity(0.14)
    static let green = Color(nsColor: .systemGreen)
    static let red = Color(nsColor: .systemRed)
    static let orange = Color(nsColor: .systemOrange)
    static let control = Color(light: .white, dark: Color(white: 0.23))
    static let controlBorder = Color.primary.opacity(0.14)
    static let segSelected = Color(light: .white, dark: Color(white: 0.36))
    static let content = Color(nsColor: .textBackgroundColor)
    static let groupBackground = Color(light: Color(white: 0.925), dark: Color(white: 0.12))
    static let groupBox = Color(light: .white, dark: Color(white: 0.17))
}

/// Number and avatar helpers shared by the views.
enum Avatar {
    static let palette: [(Color, Color)] = [
        (Color(red: 0.44, green: 0.64, blue: 0.97), Color(red: 0.24, green: 0.45, blue: 0.85)),
        (Color(red: 0.44, green: 0.83, blue: 0.61), Color(red: 0.18, green: 0.64, blue: 0.41)),
        (Color(red: 0.97, green: 0.70, blue: 0.42), Color(red: 0.88, green: 0.48, blue: 0.18)),
        (Color(red: 0.79, green: 0.61, blue: 0.94), Color(red: 0.60, green: 0.38, blue: 0.84)),
        (Color(red: 0.96, green: 0.55, blue: 0.55), Color(red: 0.85, green: 0.33, blue: 0.31)),
        (Color(red: 0.64, green: 0.66, blue: 0.71), Color(red: 0.50, green: 0.53, blue: 0.58)),
    ]

    static func initials(_ name: String) -> String {
        let words = name.split(whereSeparator: { $0 == " " || $0 == "-" }).filter { $0.first?.isLetter == true }
        if words.count >= 2 { return String(words[0].prefix(1) + words[1].prefix(1)).uppercased() }
        if let w = words.first { return String(w.prefix(2)).uppercased() }
        return "#"
    }

    /// Stable colour per name (hash of unicode scalars, not `hashValue`, which changes per launch).
    static func colors(for name: String) -> (Color, Color) {
        let sum = name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return palette[sum % palette.count]
    }
}

struct AvatarView: View {
    let name: String
    var size: CGFloat = 32

    var body: some View {
        let (a, b) = Avatar.colors(for: name)
        Text(Avatar.initials(name))
            .font(.system(size: size * 0.38, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(LinearGradient(colors: [a, b], startPoint: .top, endPoint: .bottom), in: Circle())
            .accessibilityHidden(true)
    }
}

/// Fallback app icon (the project has no .icns yet): gradient squircle with a handset.
struct AppIconView: View {
    var size: CGFloat = 64
    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
            .fill(LinearGradient(colors: [Color(red: 0.17, green: 0.42, blue: 0.93), Color(red: 0.08, green: 0.64, blue: 0.63)],
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: size, height: size)
            .overlay(Image(systemName: "phone.fill").font(.system(size: size * 0.46)).foregroundStyle(.white))
            .shadow(color: .black.opacity(0.18), radius: size * 0.04, y: size * 0.02)
    }
}

enum RegistrationDot {
    case registered, registering, failed, off
}

struct StatusDot: View {
    let kind: RegistrationDot
    var size: CGFloat = 8

    var body: some View {
        Group {
            switch kind {
            case .registered: Circle().fill(Theme.green)
            case .registering: Circle().fill(Theme.orange)
            case .failed: Circle().fill(Theme.red)
            case .off: Circle().strokeBorder(Color.secondary, lineWidth: 1.5)
            }
        }
        .frame(width: size, height: size)
    }
}

/// Segmented control look from the mockups, with an optional badge on a segment.
struct SegmentedTabs<Value: Hashable>: View {
    struct Item { let value: Value; let title: String; var badge: Int = 0 }
    let items: [Item]
    @Binding var selection: Value
    var height: CGFloat = 24

    var body: some View {
        HStack(spacing: 0) {
            ForEach(items, id: \.value) { item in
                let selected = item.value == selection
                Button { selection = item.value } label: {
                    HStack(spacing: 5) {
                        Text(item.title).font(.system(size: 12.5))
                        if item.badge > 0 { CountPill(count: item.badge) }
                    }
                    .frame(maxWidth: .infinity, minHeight: height - 4)
                    .background {
                        if selected {
                            RoundedRectangle(cornerRadius: 5).fill(Theme.segSelected)
                                .shadow(color: .black.opacity(0.18), radius: 1, y: 1)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.07)))
    }
}

struct CountPill: View {
    let count: Int
    var body: some View {
        Text("\(count)")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .frame(minWidth: 16, minHeight: 15)
            .background(Capsule().fill(Theme.red))
    }
}

/// Light rounded text-input background with the mockup's focus ring (3 pt tint plus 1 pt accent).
struct FieldBackground: ViewModifier {
    var focused: Bool
    var invalid = false
    var cornerRadius: CGFloat = 6

    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: cornerRadius).fill(Theme.control))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(invalid ? Theme.red : (focused ? Theme.blue : Theme.controlBorder),
                                  lineWidth: invalid || focused ? 1 : 0.5)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius + 1.5)
                    .strokeBorder(Theme.blue.opacity(focused ? 0.28 : 0), lineWidth: 3)
                    .padding(-1.5)
            )
    }
}

extension View {
    func fieldBackground(focused: Bool = false, invalid: Bool = false, cornerRadius: CGFloat = 6) -> some View {
        modifier(FieldBackground(focused: focused, invalid: invalid, cornerRadius: cornerRadius))
    }
}

struct IconButton: View {
    let systemName: String
    let help: String
    var size: CGFloat = 13
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName).font(.system(size: size, weight: .medium))
                .frame(width: 26, height: 22).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.label2)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Red round hang-up button used in call rows and summary bar.
struct MiniEndButton: View {
    var size: CGFloat = 22
    let help: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "phone.down.fill").font(.system(size: size * 0.5)).foregroundStyle(.white)
                .frame(width: size, height: size).background(Circle().fill(Theme.red))
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

func formatDuration(_ seconds: TimeInterval) -> String {
    let s = max(0, Int(seconds))
    let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%02d:%02d", m, sec)
}

/// Re-renders every second; the closure computes the text from `Date()`.
struct TickingText: View {
    let text: (Date) -> String
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in Text(text(ctx.date)).monospacedDigit() }
    }
}
