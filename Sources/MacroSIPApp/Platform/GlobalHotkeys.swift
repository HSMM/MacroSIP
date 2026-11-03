import AppKit
import Carbon.HIToolbox
import MacroSIPCore

/// Global hotkeys through Carbon's `RegisterEventHotKey`: they work while another app is frontmost and
/// need no permission (no event tap, no Accessibility prompt). The app asks the system for a combination; if the
/// system refuses it, only that action is without a key. macOS does not report another app's use of the same keys:
/// a second process's registration of a held combination succeeds, and both can receive the press.
///
/// Lifetime: the Carbon handler gets an unretained pointer to `Box`, which this object owns. `stop()` removes
/// the handler before the box can go away, and clears the box's callback, so a press that is already on its
/// way finds nothing to call. Owners must call `stop()` (the app does at quit); the object does not clean up
/// by itself because a main-actor class cannot touch Carbon state from `deinit`.
/// The Carbon callback runs on the main thread, but is a C function and not main-actor isolated; it hands the
/// hotkey id to a `Task` on the main actor. While an `NSMenu` is tracking, Carbon holds the event back until the menu
/// closes; a press that old is dropped (`HotkeyPressFilter.isStale`), the calls it was meant for may be gone.
@MainActor
final class GlobalHotkeys {
    enum Failure: Equatable {
        /// The system answered that the combination is taken (`eventHotKeyExistsErr`).
        case inUse
        /// Any other Carbon error.
        case system(Int)
    }

    typealias Handler = @MainActor (HotkeyAction) -> Void

    /// 'MSIP': tells our hotkey events from others.
    nonisolated static let signature: OSType = 0x4D534950

    private let handler: Handler
    private let box = Box()
    private var eventHandler: EventHandlerRef?
    private var registered: [HotkeyAction: (ref: EventHotKeyRef, combo: HotkeyCombo)] = [:]

    init(handler: @escaping Handler) {
        self.handler = handler
        box.deliver = { [weak self] id, age in
            Task { @MainActor in self?.press(id: id, age: age) }
        }
    }

    /// What is registered with the system right now.
    var activeCombos: [HotkeyAction: HotkeyCombo] { registered.mapValues(\.combo) }

    /// Makes the registered set equal to `wanted`: unchanged combinations stay, others are released and
    /// registered anew. Returns the actions the system refused; the rest work.
    @discardableResult
    func apply(_ wanted: [HotkeyAction: HotkeyCombo]) -> [HotkeyAction: Failure] {
        for (action, entry) in registered where wanted[action] != entry.combo {
            UnregisterEventHotKey(entry.ref)
            registered[action] = nil
        }
        guard !wanted.isEmpty else { return [:] }
        guard installHandler() else { return Dictionary(uniqueKeysWithValues: wanted.keys.map { ($0, Failure.system(-1)) }) }
        var failures: [HotkeyAction: Failure] = [:]
        for action in HotkeyAction.allCases {
            guard let combo = wanted[action], registered[action] == nil else { continue }
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: Self.signature, id: Self.id(of: action))
            let status = RegisterEventHotKey(UInt32(combo.keyCode), Self.carbonModifiers(combo.modifiers), id,
                                             GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref {
                registered[action] = (ref, combo)
            } else {
                failures[action] = status == OSStatus(eventHotKeyExistsErr) ? .inUse : .system(Int(status))
                AppLog.app.error("global hotkey \(action.rawValue) \(combo.display): RegisterEventHotKey failed (\(status))")
            }
        }
        return failures
    }

    /// Releases every hotkey and the Carbon handler. Safe to call twice.
    func stop() {
        for (_, entry) in registered { UnregisterEventHotKey(entry.ref) }
        registered = [:]
        if let eventHandler { RemoveEventHandler(eventHandler) }
        eventHandler = nil
        box.deliver = nil
    }

    #if DEBUG
    /// Runs the path a real key press takes after Carbon (id lookup, hop to the main actor, handler); only for
    /// actions that are registered, like the real thing. `age`: how long the event had been waiting.
    func simulatePress(_ action: HotkeyAction, age: TimeInterval = 0) {
        guard registered[action] != nil else { return }
        box.deliver?(Self.id(of: action), age)
    }
    #endif

    // MARK: Carbon plumbing

    private func installHandler() -> Bool {
        if eventHandler != nil { return true }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        var ref: EventHandlerRef?
        let status = InstallEventHandler(GetApplicationEventTarget(), globalHotkeyCallback, 1, &spec,
                                         Unmanaged.passUnretained(box).toOpaque(), &ref)
        guard status == noErr, let ref else {
            AppLog.app.error("global hotkeys: InstallEventHandler failed (\(status))")
            return false
        }
        eventHandler = ref
        return true
    }

    private func press(id: UInt32, age: TimeInterval) {
        guard let action = HotkeyAction.allCases.first(where: { Self.id(of: $0) == id }), registered[action] != nil else { return }
        if HotkeyPressFilter.isStale(age: age) {
            AppLog.app.info("global hotkey \(action.rawValue): dropped a press \(String(format: "%.1f", age)) s old")
            return
        }
        handler(action)
    }

    nonisolated static func id(of action: HotkeyAction) -> UInt32 {
        switch action {
        case .answer: return 1
        case .hangUp: return 2
        case .mute: return 3
        }
    }

    nonisolated static func carbonModifiers(_ m: HotkeyModifiers) -> UInt32 {
        var out = 0
        if m.contains(.command) { out |= cmdKey }
        if m.contains(.control) { out |= controlKey }
        if m.contains(.option) { out |= optionKey }
        if m.contains(.shift) { out |= shiftKey }
        return UInt32(out)
    }

    /// The Cocoa modifier flags of a key event as the app's own modifier set.
    nonisolated static func modifiers(from flags: NSEvent.ModifierFlags) -> HotkeyModifiers {
        var m: HotkeyModifiers = []
        if flags.contains(.command) { m.insert(.command) }
        if flags.contains(.control) { m.insert(.control) }
        if flags.contains(.option) { m.insert(.option) }
        if flags.contains(.shift) { m.insert(.shift) }
        return m
    }

    /// What the C callback may touch from any thread.
    final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var callback: (@Sendable (UInt32, TimeInterval) -> Void)?
        /// Hotkey id, and how long ago the key was pressed.
        var deliver: (@Sendable (UInt32, TimeInterval) -> Void)? {
            get { lock.withLock { callback } }
            set { lock.withLock { callback = newValue } }
        }
    }
}

private let globalHotkeyCallback: EventHandlerUPP = { _, event, userData in
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    var id = EventHotKeyID()
    let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                   nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
    guard status == noErr, id.signature == GlobalHotkeys.signature else { return OSStatus(eventNotHandledErr) }
    let age = GetCurrentEventTime() - GetEventTime(event)
    Unmanaged<GlobalHotkeys.Box>.fromOpaque(userData).takeUnretainedValue().deliver?(id.id, age)
    return noErr
}
