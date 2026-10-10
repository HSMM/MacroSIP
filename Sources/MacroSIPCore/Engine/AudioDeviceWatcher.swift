import CoreAudio
import Foundation

/// Watches the CoreAudio device list and calls `onChange` (on a private queue) when
/// devices appear or disappear. PJSIP 2.17 has no device-change observer of its own.
final class AudioDeviceWatcher {
    private let queue = DispatchQueue(label: "macrosip.audio-devices")
    private var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    private let block: AudioObjectPropertyListenerBlock
    private var installed = false

    init(onChange: @escaping @Sendable () -> Void) {
        block = { _, _ in onChange() }
        installed = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, queue, block) == noErr
    }

    func invalidate() {
        guard installed else { return }
        _ = AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, queue, block)
        installed = false
    }

    deinit { invalidate() }
}
