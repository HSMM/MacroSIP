import SwiftUI
import AppKit
import UniformTypeIdentifiers
import MacroSIPCore

/// 8.3 Audio: devices with a live level meter, ringtone, echo cancellation.
struct AudioPane: View {
    @Environment(AppModel.self) private var model
    @Local private var level: Float = 0
    @Local private var preview: NSSound?

    // The engine has one built-in ringtone today; the choice and the volume are stored for it.
    private var builtIn: String { model.prefs.string(forKey: "ringtoneSound") ?? "classic" }
    private var volume: Double { model.prefs.object(forKey: "ringtoneVolume") as? Double ?? 0.8 }

    private func deviceBinding(_ keyPath: WritableKeyPath<AudioSettings, String?>) -> Binding<String> {
        Binding(
            get: { MainActor.assumeIsolated { model.settings.audio[keyPath: keyPath] ?? "" } },
            set: { v in MainActor.assumeIsolated { model.updateSettings { $0.audio[keyPath: keyPath] = v.isEmpty ? nil : v } } })
    }

    private var inputs: [AudioDevice] { model.devices.filter { $0.inputChannels > 0 } }
    private var outputs: [AudioDevice] { model.devices.filter { $0.outputChannels > 0 } }

    var body: some View {
        PaneContainer {
            FormGroup(header: L.audioDevicesHeader, footer: L.audioDevicesFooter) {
                FormRow(label: L.audioMicrophone) {
                    HStack(spacing: 10) {
                        MeterView(level: level)
                        devicePicker(deviceBinding(\.inputDeviceName), devices: inputs)
                    }
                }
                FormDivider()
                FormRow(label: L.audioSpeaker) {
                    HStack(spacing: 10) {
                        Button(L.audioTest) { NSSound(named: "Ping")?.play() }.controlSize(.small)
                        devicePicker(deviceBinding(\.outputDeviceName), devices: outputs)
                    }
                }
                FormDivider()
                FormRow(label: L.audioRingtoneDevice, help: L.audioRingtoneDeviceHelp) {
                    devicePicker(deviceBinding(\.ringtoneDeviceName), devices: outputs)
                }
            }
            FormGroup(header: L.audioRingtoneHeader, footer: L.audioRingtoneFooter) {
                FormRow(label: L.audioSound) {
                    HStack(spacing: 10) {
                        Button { play() } label: { Label(L.audioPlay, systemImage: "play.fill") }.controlSize(.small)
                        Picker("", selection: soundSelection) {
                            Text(L.ringtoneClassic).tag("classic")
                            Text(L.ringtoneDigital).tag("digital")
                            Text(L.ringtoneSoft).tag("soft")
                            Divider()
                            if case let .file(url) = model.settings.audio.ringtone {
                                Text(L.ringtoneCustomName(url.lastPathComponent)).tag("custom")
                            }
                            Text(L.ringtoneCustom).tag("choose")
                        }
                        .labelsHidden().frame(width: 190)
                    }
                }
                FormDivider()
                FormRow(label: L.audioVolume) {
                    HStack(spacing: 6) {
                        Image(systemName: "speaker.fill").font(.system(size: 10)).foregroundStyle(Theme.label2)
                        Slider(value: Binding(get: { volume }, set: { model.prefs.set($0, forKey: "ringtoneVolume") }), in: 0...1)
                            .frame(width: 200)
                    }
                }
            }
            FormGroup(header: L.audioProcessingHeader) {
                FormRow(label: L.audioEcho, help: L.audioEchoHelp) {
                    Toggle("", isOn: model.binding(\.network.echoCancellation)).labelsHidden().toggleStyle(.switch)
                }
            }
        }
        .task {
            await model.refreshDevices()
            while !Task.isCancelled {
                level = await model.engine.inputLevel()
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private func devicePicker(_ selection: Binding<String>, devices: [AudioDevice]) -> some View {
        Picker("", selection: selection) {
            Text(L.audioSystemDefault).tag("")
            if !selection.wrappedValue.isEmpty, !devices.contains(where: { $0.name == selection.wrappedValue }) {
                Text(selection.wrappedValue).tag(selection.wrappedValue)       // unplugged: shown until it returns
            }
            ForEach(devices) { d in Text(d.name).tag(d.name) }
        }
        .labelsHidden().frame(width: 200)
    }

    private var soundSelection: Binding<String> {
        Binding(
            get: {
                if case .file = model.settings.audio.ringtone { return "custom" }
                return builtIn
            },
            set: { v in
                MainActor.assumeIsolated {
                    switch v {
                    case "choose": chooseFile()
                    case "custom": break
                    default:
                        model.prefs.set(v, forKey: "ringtoneSound")
                        model.updateSettings { $0.audio.ringtone = .builtIn }
                    }
                }
            })
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.wav, .aiff, .mpeg4Audio, .mp3]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            model.updateSettings { $0.audio.ringtone = .file(url) }
        }
    }

    private func play() {
        preview?.stop()
        if case let .file(url) = model.settings.audio.ringtone {
            preview = NSSound(contentsOf: url, byReference: true)
        } else {
            preview = NSSound(named: ["classic": "Glass", "digital": "Ping", "soft": "Submarine"][builtIn] ?? "Glass")
        }
        preview?.volume = Float(volume)
        preview?.play()
    }
}
