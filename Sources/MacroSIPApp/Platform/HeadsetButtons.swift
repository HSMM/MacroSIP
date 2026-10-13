import Foundation
import IOKit
import IOKit.hid

/// What a headset button means once the HID report has been decoded (see `HeadsetReportDecoder`).
enum HeadsetEvent: Equatable, Sendable {
    case offHook        // hook switch went off-hook (level-type devices)
    case onHook         // hook switch went on-hook (level-type devices)
    case hookPress      // the hook button was pressed (momentary-type devices): answer or hang up
    case flash          // hook flash: answer the waiting call, else swap the held one in
    case hold
    case drop
    case mute
    case redial
}

/// What the headset shows: the LED usages Off-Hook, Ring and Mute, written as output reports.
struct HeadsetIndicators: Equatable, Sendable {
    var offHook = false
    var ring = false
    var mute = false
}

/// Turns HID input values of the Telephony usage page into `HeadsetEvent`s. Pure: no IOKit, so the
/// self-test exercises it directly.
///
/// Hook Switch (0x0B/0x20) comes in two flavours. A switch reports a level (1 while off-hook, 0 when
/// the user hangs up); the report descriptor marks it "no preferred state". A button reports a
/// momentary 1 for a press (the descriptor says "preferred state") and expects the host to keep
/// the hook state and show it through the Off-Hook LED. A device that claims to be a switch but
/// releases within `pressWindow` is treated as a button from then on; so is one whose release
/// arrives within `answerWindow` of the call its off-hook answered (`noteAnswered`), so a long
/// first press cannot answer and hang up in one go. The other usages (Flash, Hold, Redial, Drop,
/// Phone Mute) count on their rising edge.
struct HeadsetReportDecoder: Equatable {
    enum HookStyle: Equatable { case level, momentary }

    static let telephonyPage: UInt32 = 0x0B
    static let hookSwitch: UInt32 = 0x20
    static let flash: UInt32 = 0x21
    static let hold: UInt32 = 0x23
    static let redial: UInt32 = 0x24
    static let drop: UInt32 = 0x26
    static let phoneMute: UInt32 = 0x2F
    static let pressWindow: TimeInterval = 0.3
    /// A release this soon after the answer the press caused is the end of a long press, not a hang-up.
    static let answerWindow: TimeInterval = 1.0

    private(set) var hookStyle: HookStyle
    private var offHookAt: TimeInterval?
    private var answeredAt: TimeInterval?

    init(hookHasPreferredState: Bool) {
        hookStyle = hookHasPreferredState ? .momentary : .level
    }

    /// The off-hook reported last answered a call at `now` (only matters while the hook is held down).
    mutating func noteAnswered(at now: TimeInterval) {
        if offHookAt != nil { answeredAt = now }
    }

    mutating func decode(page: UInt32, usage: UInt32, value: Int, at now: TimeInterval) -> HeadsetEvent? {
        guard page == Self.telephonyPage else { return nil }
        let on = value != 0
        switch usage {
        case Self.hookSwitch: return decodeHook(on, at: now)
        case Self.flash: return on ? .flash : nil
        case Self.hold: return on ? .hold : nil
        case Self.redial: return on ? .redial : nil
        case Self.drop: return on ? .drop : nil
        case Self.phoneMute: return on ? .mute : nil
        default: return nil
        }
    }

    private mutating func decodeHook(_ on: Bool, at now: TimeInterval) -> HeadsetEvent? {
        switch hookStyle {
        case .momentary:
            return on ? .hookPress : nil
        case .level:
            if on { offHookAt = now; answeredAt = nil; return .offHook }
            defer { offHookAt = nil; answeredAt = nil }
            if let t = offHookAt, now - t < Self.pressWindow {
                // Released within the window: a button, not a switch. The 1 has already been handled as
                // off-hook (the same thing a press does); the release is not a hang-up.
                hookStyle = .momentary
                return nil
            }
            if let a = answeredAt, now - a < Self.answerWindow {
                // The press answered a call and was let go within a second: a long button press, not a
                // handset put back. A button from now on, and the call stays up.
                hookStyle = .momentary
                return nil
            }
            return .onHook
        }
    }
}

/// Call-control buttons of USB (and other HID) headsets: answer, hang up, mute, redial through
/// IOHIDManager, and the Off-Hook / Ring / Mute LEDs written back so the headset shows the call state.
///
/// Devices: every HID device whose top-level collection is on the Telephony page (Headset 0x05,
/// Telephony 0x01, Handset 0x04, ...) and Consumer Control devices (0x0C/0x01) that carry Telephony
/// elements; a Consumer Control collection without them (a keyboard's media keys, the 3.5 mm jack's
/// "Headset") is ignored. The manager only enumerates; each telephony device is opened on its own.
/// A Telephony-page collection opens without a prompt; a device that exposes its telephony controls
/// only inside a Consumer Control collection may be refused by macOS (Input Monitoring): the failure
/// is logged and the device ignored. The latter has not been tested on real hardware.
/// Everything IOKit does happens on `queue`; events reach the main actor through `handler`.
/// Bluetooth headsets whose buttons speak HFP (AT commands) do not appear as HID telephony devices.
final class HeadsetButtons: @unchecked Sendable {
    typealias Handler = @MainActor @Sendable (HeadsetEvent) -> Void
    typealias DeviceHandler = @MainActor @Sendable (String?) -> Void

    static let ledPage: UInt32 = 0x08
    static let ledMute: UInt32 = 0x09
    static let ledOffHook: UInt32 = 0x17
    static let ledRing: UInt32 = 0x18
    static let consumerPage: UInt32 = 0x0C

    private struct Device {
        let ref: IOHIDDevice
        let name: String
        var decoder: HeadsetReportDecoder
        let leds: [UInt32: IOHIDElement]        // LED usage -> output element
        var written: HeadsetIndicators?
        var writeFailed = false
    }

    private let queue = DispatchQueue(label: "com.hsmm.macrosip.headset-buttons")
    private let handler: Handler
    private let deviceHandler: DeviceHandler
    // Queue-confined state.
    private var manager: IOHIDManager?
    private var devices: [UInt: Device] = [:]
    private var order: [UInt] = []
    private var desired = HeadsetIndicators()

    init(handler: @escaping Handler, deviceChanged: @escaping DeviceHandler) {
        self.handler = handler
        self.deviceHandler = deviceChanged
    }

    // MARK: - Lifecycle

    /// Starts matching. Devices already plugged in arrive through the matching callback right away.
    func start() {
        queue.async { [self] in
            guard manager == nil else { return }
            let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
            let matching: [[String: Any]] = [
                [kIOHIDDeviceUsagePageKey: Int(HeadsetReportDecoder.telephonyPage)],
                [kIOHIDDeviceUsagePageKey: Int(Self.consumerPage), kIOHIDDeviceUsageKey: 0x01],
            ]
            IOHIDManagerSetDeviceMatchingMultiple(m, matching as CFArray)
            let context = Unmanaged.passUnretained(self).toOpaque()
            IOHIDManagerRegisterDeviceMatchingCallback(m, { context, _, _, device in
                guard let context else { return }
                Unmanaged<HeadsetButtons>.fromOpaque(context).takeUnretainedValue().deviceMatched(device)
            }, context)
            IOHIDManagerRegisterDeviceRemovalCallback(m, { context, _, _, device in
                guard let context else { return }
                Unmanaged<HeadsetButtons>.fromOpaque(context).takeUnretainedValue().deviceRemoved(device)
            }, context)
            IOHIDManagerSetDispatchQueue(m, queue)          // devices it finds are scheduled on the same queue
            IOHIDManagerSetCancelHandler(m) { _ = m }       // after stop(): the manager lives until its last callback is done
            manager = m
            IOHIDManagerActivate(m)
            AppLog.app.info("headset buttons: listening for HID telephony devices")
        }
    }

    /// Switches the LEDs off, forgets the devices and stops matching. `start()` may be called again later.
    func stop() {
        queue.async { [self] in
            guard let m = manager else { return }
            manager = nil
            for key in order { write(HeadsetIndicators(), to: key); release(key) }
            let hadDevices = !devices.isEmpty
            devices.removeAll()
            order.removeAll()
            IOHIDManagerRegisterDeviceMatchingCallback(m, nil, nil)
            IOHIDManagerRegisterDeviceRemovalCallback(m, nil, nil)
            IOHIDManagerCancel(m)
            if hadDevices { publishDevice() }
            AppLog.app.info("headset buttons: stopped")
        }
    }

    /// The call state the headset should show; written to every device whose LEDs differ.
    func setIndicators(_ indicators: HeadsetIndicators) {
        queue.async { [self] in
            guard desired != indicators else { return }
            desired = indicators
            for key in order { write(indicators, to: key) }
        }
    }

    /// What the controller would show right now (self-test).
    func currentIndicators() -> HeadsetIndicators {
        queue.sync { desired }
    }

    /// The off-hook the headset reported answered a call: a release within the next second is the end of a
    /// long press, not a hang-up (`HeadsetReportDecoder.noteAnswered`).
    func callAnswered() {
        queue.async { [self] in
            let now = ProcessInfo.processInfo.systemUptime
            for key in order { devices[key]?.decoder.noteAnswered(at: now) }
        }
    }

    #if DEBUG
    /// Feeds an event as if a headset had sent it (demo self-test). Takes the same path as a real report.
    func simulate(_ event: HeadsetEvent) {
        queue.async { [self] in deliver(event) }
    }
    #endif

    // MARK: - Devices (queue)

    private func key(of device: IOHIDDevice) -> UInt {
        UInt(bitPattern: Unmanaged.passUnretained(device).toOpaque())
    }

    private func deviceMatched(_ device: IOHIDDevice) {
        let k = key(of: device)
        guard devices[k] == nil else { return }
        let name = (IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let telephony = elements(of: device, page: HeadsetReportDecoder.telephonyPage)
        let inputs = telephony.filter { IOHIDElementGetType($0) == kIOHIDElementTypeInput_Button || IOHIDElementGetType($0) == kIOHIDElementTypeInput_Misc }
        guard !inputs.isEmpty else {
            AppLog.app.debug("headset buttons: \(name ?? "HID device") has no telephony controls, ignored")
            return
        }
        let hook = inputs.first { IOHIDElementGetUsage($0) == HeadsetReportDecoder.hookSwitch }
        let momentary = hook.map { IOHIDElementHasPreferredState($0) } ?? true
        var leds: [UInt32: IOHIDElement] = [:]
        for e in elements(of: device, page: Self.ledPage) where IOHIDElementGetType(e) == kIOHIDElementTypeOutput {
            let usage = IOHIDElementGetUsage(e)
            if [Self.ledOffHook, Self.ledRing, Self.ledMute].contains(usage), leds[usage] == nil { leds[usage] = e }
        }
        let usages = inputs.map { "0x" + String(IOHIDElementGetUsage($0), radix: 16) }.joined(separator: " ")
        let shown = name?.isEmpty == false ? name! : "HID telephony device"
        let status = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard status == kIOReturnSuccess else {
            AppLog.app.error("headset buttons: cannot open \(shown) (0x\(String(UInt32(bitPattern: status), radix: 16)))")
            return
        }
        IOHIDDeviceSetInputValueMatching(device, [kIOHIDElementUsagePageKey: Int(HeadsetReportDecoder.telephonyPage)] as CFDictionary)
        IOHIDDeviceRegisterInputValueCallback(device, { context, _, _, value in
            guard let context else { return }
            Unmanaged<HeadsetButtons>.fromOpaque(context).takeUnretainedValue().inputValue(value)
        }, Unmanaged.passUnretained(self).toOpaque())
        devices[k] = Device(ref: device, name: shown, decoder: HeadsetReportDecoder(hookHasPreferredState: momentary), leds: leds)
        order.append(k)
        AppLog.app.info("headset buttons: \(shown) connected, hook \(momentary ? "button" : "switch"), controls \(usages), LEDs \(leds.keys.sorted().map { "0x" + String($0, radix: 16) }.joined(separator: " "))")
        write(desired, to: k)
        publishDevice()
    }

    private func deviceRemoved(_ device: IOHIDDevice) {
        let k = key(of: device)
        guard let d = devices[k] else { return }
        release(k)
        devices[k] = nil
        order.removeAll { $0 == k }
        AppLog.app.info("headset buttons: \(d.name) disconnected")
        publishDevice()
    }

    /// Stops the callbacks of a device and closes it (removal, stop).
    private func release(_ key: UInt) {
        guard let d = devices[key] else { return }
        IOHIDDeviceRegisterInputValueCallback(d.ref, nil, nil)
        IOHIDDeviceClose(d.ref, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    private func elements(of device: IOHIDDevice, page: UInt32) -> [IOHIDElement] {
        guard let array = IOHIDDeviceCopyMatchingElements(device, [kIOHIDElementUsagePageKey: Int(page)] as CFDictionary, IOOptionBits(kIOHIDOptionsTypeNone)) else { return [] }
        return (0..<CFArrayGetCount(array)).map { unsafeBitCast(CFArrayGetValueAtIndex(array, $0), to: IOHIDElement.self) }
    }

    private func publishDevice() {
        let name = order.first.flatMap { devices[$0]?.name }
        let deviceHandler = deviceHandler
        DispatchQueue.main.async { MainActor.assumeIsolated { deviceHandler(name) } }
    }

    // MARK: - Reports (queue)

    private func inputValue(_ value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        let k = key(of: IOHIDElementGetDevice(element))
        guard var d = devices[k] else { return }
        let page = IOHIDElementGetUsagePage(element)
        let usage = IOHIDElementGetUsage(element)
        let raw = IOHIDValueGetIntegerValue(value)
        let event = d.decoder.decode(page: page, usage: usage, value: raw, at: ProcessInfo.processInfo.systemUptime)
        devices[k] = d
        AppLog.app.debug("headset buttons: \(d.name) 0x\(String(page, radix: 16))/0x\(String(usage, radix: 16)) = \(raw)\(event.map { " -> \($0)" } ?? "")")
        if let event { deliver(event) }
    }

    private func deliver(_ event: HeadsetEvent) {
        let handler = handler
        DispatchQueue.main.async { MainActor.assumeIsolated { handler(event) } }
    }

    private func write(_ indicators: HeadsetIndicators, to key: UInt) {
        guard var d = devices[key], !d.leds.isEmpty, d.written != indicators else { return }
        let pairs: [(UInt32, Bool)] = [(Self.ledOffHook, indicators.offHook), (Self.ledRing, indicators.ring), (Self.ledMute, indicators.mute)]
        var failed = false
        for (usage, on) in pairs {
            guard let element = d.leds[usage] else { continue }
            if d.written.map({ ledState($0, usage) == on }) == true { continue }
            let value = IOHIDValueCreateWithIntegerValue(kCFAllocatorDefault, element, mach_absolute_time(), on ? 1 : 0)
            let status = IOHIDDeviceSetValue(d.ref, element, value)
            if status != kIOReturnSuccess { failed = true }
        }
        if failed, !d.writeFailed {
            d.writeFailed = true
            AppLog.app.error("headset buttons: \(d.name) refused an LED report")
        }
        d.written = indicators
        devices[key] = d
    }

    private func ledState(_ indicators: HeadsetIndicators, _ usage: UInt32) -> Bool {
        switch usage {
        case Self.ledOffHook: return indicators.offHook
        case Self.ledRing: return indicators.ring
        case Self.ledMute: return indicators.mute
        default: return false
        }
    }
}
