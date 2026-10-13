import SwiftUI
import AppKit
import UniformTypeIdentifiers
import MacroSIPCore

/// 8.3 Audio: devices with a live level meter, ringtone, hold music, sound events, audio test, echo cancellation.
struct AudioPane: View {
    @Environment(AppModel.self) private var model
    @Local private var level: Float = 0
    @Local private var preview: NSSound?
    @Local private var draftVolume: Double?        // while the slider is dragged; saved when the drag ends
    @Local private var dragging = false

    // The engine has one built-in ringtone today; the choice is stored for it.
    private var builtIn: String { model.prefs.string(forKey: "ringtoneSound") ?? "classic" }
    private var volume: Float { model.settings.audio.ringtoneVolume }

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
                    devicePicker(deviceBinding(\.outputDeviceName), devices: outputs)
                }
                FormDivider()
                FormRow(label: L.audioRingtoneDevice, help: L.audioRingtoneDeviceHelp) {
                    devicePicker(deviceBinding(\.ringtoneDeviceName), devices: outputs)
                }
                FormDivider()
                FormRow(label: L.audioFollowDevices, help: L.audioFollowDevicesHelp) {
                    Toggle("", isOn: Binding(
                        get: { MainActor.assumeIsolated { model.settings.audio.followNewDevices } },
                        set: { v in MainActor.assumeIsolated { model.updateSettings { $0.audio.followNewDevices = v } } }))
                        .labelsHidden().toggleStyle(.switch)
                }
                FormDivider()
                FormRow(label: L.audioHeadsetButtons,
                        help: model.headsetButtonsDevice.map(L.audioHeadsetConnected) ?? L.audioHeadsetNone) {
                    Toggle("", isOn: model.binding(\.audio.headsetButtons)).labelsHidden().toggleStyle(.switch)
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
                        Slider(value: Binding(get: { draftVolume ?? Double(volume) },
                                              set: { v in MainActor.assumeIsolated {
                                                  draftVolume = v
                                                  if !dragging { commitVolume() }       // keyboard steps
                                              } }),
                               in: 0...1, step: 0.05, onEditingChanged: { editing in
                                   dragging = editing
                                   if !editing { commitVolume() }
                               })
                            .frame(width: 160)
                            .accessibilityLabel(L.audioVolume)
                        Text(L.unitPercent(L.number(((draftVolume ?? Double(volume)) * 100).rounded())))
                            .font(.system(size: 12)).monospacedDigit().foregroundStyle(Theme.label2)
                            .frame(width: 44, alignment: .trailing)
                    }
                }
            }
            FormGroup(header: L.audioHoldMusicHeader, footer: model.holdMusicError.map(L.audioHoldMusicError) ?? L.audioHoldMusicFooter) {
                FormRow(label: L.audioHoldMusicSource) {
                    Picker("", selection: holdMusicSelection) {
                        Text(L.audioHoldMusicBuiltIn).tag("builtIn")
                        if case let .file(url) = model.settings.audio.holdMusic {
                            Text(L.ringtoneCustomName(url.lastPathComponent)).tag("custom")
                        }
                        Text(L.ringtoneCustom).tag("choose")
                        Divider()
                        Text(L.audioHoldMusicOff).tag("off")
                    }
                    .labelsHidden().frame(width: 190)
                }
            }
            FormGroup(header: L.audioSoundEventsHeader, footer: L.audioSoundEventsFooter) {
                soundToggle(L.audioSoundCallEvents, \.callEvents)
                FormDivider()
                soundToggle(L.audioSoundKeyPress, \.keyPress)
                FormDivider()
                soundToggle(L.audioSoundVoicemail, \.voicemail)
                FormDivider()
                soundToggle(L.audioSoundError, \.error)
            }
            FormGroup(header: L.audioTestHeader) {
                FormRow(label: L.audioTestRow, help: L.audioTestHelp) {
                    HStack(spacing: 10) {
                        MeterView(level: level)
                        Button(L.audioTest) { model.playTestTone() }.controlSize(.small)
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
            await model.devicesChanged()
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

    private func soundToggle(_ label: String, _ keyPath: WritableKeyPath<SoundEventSettings, Bool>) -> some View {
        FormRow(label: label) {
            Toggle("", isOn: Binding(
                get: { MainActor.assumeIsolated { model.settings.audio.soundEvents[keyPath: keyPath] } },
                set: { v in MainActor.assumeIsolated { model.updateSettings { $0.audio.soundEvents[keyPath: keyPath] = v } } }))
                .labelsHidden().toggleStyle(.switch)
        }
    }

    /// Built-in / Custom file… / Off; the file is picked in an open panel and converted by the engine.
    private var holdMusicSelection: Binding<String> {
        Binding(
            get: {
                switch model.settings.audio.holdMusic {
                case .builtIn: return "builtIn"
                case .file: return "custom"
                case .off: return "off"
                }
            },
            set: { v in
                MainActor.assumeIsolated {
                    switch v {
                    case "choose": chooseHoldMusicFile()
                    case "custom": break
                    case "off": model.updateSettings { $0.audio.holdMusic = .off }
                    default: model.updateSettings { $0.audio.holdMusic = .builtIn }
                    }
                }
            })
    }

    private func chooseHoldMusicFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.wav, .aiff, .mpeg4Audio, .mp3, .audio]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            model.updateSettings { $0.audio.holdMusic = .file(url) }
        }
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

    private func commitVolume() {
        guard let v = draftVolume else { return }
        draftVolume = nil
        model.updateSettings { $0.audio.ringtoneVolume = Float(v) }
    }

    private func play() {
        preview?.stop()
        if case let .file(url) = model.settings.audio.ringtone {
            preview = NSSound(contentsOf: url, byReference: true)
        } else {
            preview = NSSound(named: ["classic": "Glass", "digital": "Ping", "soft": "Submarine"][builtIn] ?? "Glass")
        }
        preview?.volume = Float(draftVolume ?? Double(volume))
        preview?.play()
    }
}
