import CoreAudio
internal import CPJSUA
import Foundation

/// Watches the CoreAudio device list and the system default input and output devices and
/// calls `onChange` (on a private queue) when any of them changes. PJSIP 2.17 has no
/// device-change observer of its own.
final class AudioDeviceWatcher {
    private let queue = DispatchQueue(label: "macrosip.audio-devices")
    private var addresses: [AudioObjectPropertyAddress] = [
        kAudioHardwarePropertyDevices,
        kAudioHardwarePropertyDefaultInputDevice,
        kAudioHardwarePropertyDefaultOutputDevice,
    ].map {
        AudioObjectPropertyAddress(mSelector: $0, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }
    private let block: AudioObjectPropertyListenerBlock
    private var installed: [Bool] = []

    init(onChange: @escaping @Sendable () -> Void) {
        block = { _, _ in onChange() }
        installed = addresses.indices.map { i in
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addresses[i], queue, block) == noErr
        }
    }

    func invalidate() {
        for i in addresses.indices where installed[i] {
            _ = AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addresses[i], queue, block)
            installed[i] = false
        }
    }

    deinit { invalidate() }
}

/// Names of the system default input and output devices, as PJSIP's CoreAudio backend
/// names devices (`kAudioDevicePropertyDeviceName`, cut to `pjmedia_aud_dev_info.name`).
enum SystemAudioDefaults {
    static func deviceName(input: Bool) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown else { return nil }
        var nameAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceName,
                                                     mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)
        let capacity = MemoryLayout.size(ofValue: pjmedia_aud_dev_info().name)
        var buffer = [CChar](repeating: 0, count: capacity)
        var nameSize = UInt32(capacity)
        guard AudioObjectGetPropertyData(device, &nameAddress, 0, nil, &nameSize, &buffer) == noErr else { return nil }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        let name = String(decoding: bytes, as: UTF8.self)
        return name.isEmpty ? nil : name
    }
}
