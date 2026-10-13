import Foundation
import CoreAudio

/// How a sound device is connected, from CoreAudio's `kAudioDevicePropertyTransportType`.
enum AudioTransport: Equatable, Sendable {
    case usb, bluetooth, builtIn, virtual, aggregate, other, unknown

    /// A headset the user plugs in or pairs: USB, Bluetooth, Bluetooth LE. Never virtual or aggregate devices
    /// (Loopback, Audio Hijack, meeting-app drivers, aggregates) and never the Mac's own or display audio.
    var isPhysicalHeadsetLink: Bool { self == .usb || self == .bluetooth }

    /// Looks the device up by the name the engine reports. `unknown` when CoreAudio has no such device.
    static func lookup(deviceNamed name: String) -> AudioTransport {
        var size: UInt32 = 0
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return .unknown }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return .unknown }
        for id in ids where deviceName(id) == name {
            var transport: UInt32 = 0
            var tsize = UInt32(MemoryLayout<UInt32>.size)
            var taddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType,
                                                   mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            guard AudioObjectGetPropertyData(id, &taddr, 0, nil, &tsize, &transport) == noErr else { continue }
            return from(transport)
        }
        return .unknown
    }

    static func from(_ raw: UInt32) -> AudioTransport {
        switch raw {
        case kAudioDeviceTransportTypeUSB: return .usb
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return .bluetooth
        case kAudioDeviceTransportTypeBuiltIn: return .builtIn
        case kAudioDeviceTransportTypeVirtual: return .virtual
        case kAudioDeviceTransportTypeAggregate: return .aggregate
        default: return .other
        }
    }

    private static func deviceName(_ id: AudioDeviceID) -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &name) == noErr, let name else { return nil }
        return name.takeRetainedValue() as String
    }
}
