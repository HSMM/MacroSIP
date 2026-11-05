import SwiftUI
import AppKit

/// The text of the message composer (SCREENS.md 14.2): a multi-line text view that grows to five lines, then scrolls.
/// Return sends, Shift-Return and Option-Return start a new line, Escape goes back. While an input method has marked
/// text, Return belongs to it and does not send.
struct ComposerTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    @Binding var isFocused: Bool
    var placeholder: String
    var enabled: Bool
    /// Changes whenever the cursor should go into the field.
    var focusTrigger: Int
    var autoFocus: Bool
    var onSend: () -> Void
    var onEscape: () -> Void

    static let font = NSFont.systemFont(ofSize: 13)
    /// One line of the field's text.
    static var lineHeight: CGFloat { ceil(NSLayoutManager().defaultLineHeight(for: font)) }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> ComposerScrollView {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 270, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)

        let view = ComposerNSTextView(frame: NSRect(x: 0, y: 0, width: 270, height: Self.lineHeight), textContainer: container)
        view.delegate = context.coordinator
        view.focusRingType = .none
        view.isRichText = false
        view.importsGraphics = false
        view.allowsUndo = true
        view.font = Self.font
        view.textColor = .labelColor
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.typingAttributes = [.font: Self.font, .foregroundColor: NSColor.labelColor]
        view.string = text
        view.onReturn = { [weak coordinator = context.coordinator] in coordinator?.parent.onSend() }
        view.onEscape = { [weak coordinator = context.coordinator] in coordinator?.parent.onEscape() }
        view.onFocusChange = { [weak coordinator = context.coordinator] focused in coordinator?.setFocused(focused) }
        view.focusWhenShown = autoFocus && enabled

        let scroll = ComposerScrollView(frame: NSRect(x: 0, y: 0, width: 270, height: Self.lineHeight))
        scroll.focusRingType = .none
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = view
        context.coordinator.textView = view
        context.coordinator.measure()
        return scroll
    }

    func updateNSView(_ scroll: ComposerScrollView, context: Context) {
        let c = context.coordinator
        c.parent = self
        guard let view = c.textView else { return }
        if view.string != text {
            view.string = text
            c.measure()
        }
        view.placeholder = placeholder
        view.isEditable = enabled
        view.isSelectable = enabled
        view.alphaValue = enabled ? 1 : 0.55
        if focusTrigger != c.lastFocusTrigger {
            c.lastFocusTrigger = focusTrigger
            if enabled { DispatchQueue.main.async { view.window?.makeFirstResponder(view) } }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerTextView
        weak var textView: ComposerNSTextView?
        var lastFocusTrigger: Int

        init(_ parent: ComposerTextView) {
            self.parent = parent
            lastFocusTrigger = parent.focusTrigger
        }

        func textDidChange(_ notification: Notification) {
            guard let view = textView else { return }
            if parent.text != view.string { parent.text = view.string }
            measure()
        }

        func setFocused(_ focused: Bool) {
            DispatchQueue.main.async { [self] in if parent.isFocused != focused { parent.isFocused = focused } }
        }

        /// The height of the text, reported to SwiftUI after the current layout pass.
        func measure() {
            guard let view = textView, let layout = view.layoutManager, let container = view.textContainer else { return }
            layout.ensureLayout(for: container)
            let h = max(ceil(layout.usedRect(for: container).height), ComposerTextView.lineHeight)
            DispatchQueue.main.async { [self] in if abs(parent.height - h) > 0.5 { parent.height = h } }
        }
    }
}

/// The text never scrolls sideways (it wraps), whatever the first layout passes did to the clip view.
final class ComposerScrollView: NSScrollView {
    override var focusRingType: NSFocusRingType { get { .none } set {} }
    override var focusRingMaskBounds: NSRect { .zero }
    override func drawFocusRingMask() {}

    override func layout() {
        super.layout()
        if contentView.bounds.origin.x != 0 {
            contentView.scroll(to: NSPoint(x: 0, y: contentView.bounds.origin.y))
            reflectScrolledClipView(contentView)
        }
    }
}

final class ComposerNSTextView: NSTextView {
    var onReturn: (() -> Void)?
    var onEscape: (() -> Void)?
    var onFocusChange: ((Bool) -> Void)?
    var focusWhenShown = false
    var placeholder = "" { didSet { if oldValue != placeholder { needsDisplay = true } } }

    // The field draws its own focus ring (the pill); the system one would be cut at the scroll view's edges.
    override var focusRingType: NSFocusRingType { get { .none } set {} }
    override var focusRingMaskBounds: NSRect { .zero }
    override func drawFocusRingMask() {}

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard focusWhenShown, let window else { return }
        focusWhenShown = false
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window, self.isEditable else { return }
            window.makeFirstResponder(self)
        }
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { onFocusChange?(true) }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok { onFocusChange?(false) }
        return ok
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        if isReturn, !hasMarkedText() {
            if flags.contains(.shift) || flags.contains(.option) { insertNewlineIgnoringFieldEditor(nil); return }
            if flags.isDisjoint(with: [.command, .control]) { onReturn?(); return }
        }
        if event.keyCode == 53, !hasMarkedText() { onEscape?(); return }       // Escape
        super.keyDown(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty, !hasMarkedText() else { return }
        let attrs: [NSAttributedString.Key: Any] = [.font: ComposerTextView.font, .foregroundColor: NSColor.tertiaryLabelColor]
        NSAttributedString(string: placeholder, attributes: attrs)
            .draw(at: NSPoint(x: textContainerInset.width + (textContainer?.lineFragmentPadding ?? 0), y: textContainerInset.height))
    }
}

/// The bottom of 14.2 and 14.3: top hairline, the red "Too long to send" line, the field and the Send button.
struct MessageComposerBar: View {
    @Binding var text: String
    var placeholder: String
    var enabled: Bool
    var canSend: Bool
    var tooLong: Bool
    var focusTrigger: Int
    var autoFocus: Bool
    var onSend: () -> Void
    var onEscape: () -> Void
    @Local private var contentHeight: CGFloat = ComposerTextView.lineHeight
    @Local private var focused = false

    /// The text view in its frame: a pill for one line, a 15 pt rounded rectangle once the field has grown, with the
    /// accent border and tint ring while it has the focus.
    @ViewBuilder
    private var field: some View {
        let text = ComposerTextView(text: $text, height: $contentHeight, isFocused: $focused, placeholder: placeholder, enabled: enabled,
                                    focusTrigger: focusTrigger, autoFocus: autoFocus, onSend: send, onEscape: onEscape)
            .focusEffectDisabled()
            .frame(height: fieldHeight)
            .padding(.horizontal, 11).padding(.vertical, 7)
        if fieldHeight + 14 <= 31 { framed(text, Capsule()) } else { framed(text, RoundedRectangle(cornerRadius: 15)) }
    }

    private func framed<S: InsettableShape>(_ content: some View, _ shape: S) -> some View {
        let on = focused && enabled
        return content
            .background(shape.fill(Theme.control))
            .overlay(shape.strokeBorder(on ? Theme.blue : Theme.controlBorder, lineWidth: on ? 1 : 0.5))
            .overlay(shape.strokeBorder(Theme.blue.opacity(on ? 0.28 : 0), lineWidth: 3).padding(-1.5))
            .opacity(enabled ? 1 : 0.6)
    }

    private var fieldHeight: CGFloat {
        let line = ComposerTextView.lineHeight
        return min(max(contentHeight, line), line * 5)
    }

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            if tooLong {
                Text(L.messagesComposerTooLong)
                    .font(.system(size: 11)).foregroundStyle(Theme.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14).padding(.top, 6)
            }
            HStack(alignment: .bottom, spacing: 7) {
                field
                Button(action: send) {
                    Image(systemName: "arrow.up").font(.system(size: 12, weight: .bold))
                        .foregroundStyle(canSend ? Color.white : Theme.content)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(canSend ? Theme.blue : Theme.fill3))
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .padding(.bottom, 2)
                .help(L.messagesSendHelp)
                .accessibilityLabel(L.messagesSendHelp)
            }
            .padding(.horizontal, 10).padding(.top, 7).padding(.bottom, 8)
        }
        .background(Theme.content)
    }

    private func send() { if canSend && enabled { onSend() } }
}
