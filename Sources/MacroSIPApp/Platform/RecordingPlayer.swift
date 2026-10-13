import Foundation
import AVFoundation
import Observation

/// Plays one recording at a time for the call log's inline player (SCREENS.md 3, "Recording playback").
/// AVAudioPlayer with a 0.25 s timer for the position; opening another file replaces the current one.
@MainActor @Observable
final class RecordingPlayer {
    private(set) var url: URL?
    private(set) var isPlaying = false
    private(set) var position: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    private(set) var failed = false

    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var timer: Timer?

    /// Loads `url` (and starts it when `play`). A file that cannot be opened sets `failed`.
    func open(_ url: URL, play: Bool = true) {
        if self.url == url, player != nil {
            if play, !isPlaying { toggle() }
            return
        }
        close()
        self.url = url
        do {
            let p = try AVAudioPlayer(contentsOf: url)
            p.prepareToPlay()
            player = p
            duration = p.duration
            failed = false
            if play { toggle() }
        } catch {
            failed = true
            AppLog.recording.error("cannot play \(url.lastPathComponent): \(describe(error))")
        }
    }

    func toggle() {
        guard let player else { return }
        if isPlaying {
            player.pause()
            stopTimer()
            isPlaying = false
        } else {
            if player.currentTime >= player.duration - 0.05 { player.currentTime = 0 }     // played to the end: again from the start
            guard player.play() else { failed = true; return }
            isPlaying = true
            startTimer()
        }
        position = player.currentTime
    }

    func seek(to time: TimeInterval) {
        guard let player else { return }
        player.currentTime = min(max(0, time), max(0, player.duration))
        position = player.currentTime
    }

    func close() {
        player?.stop()
        player = nil
        stopTimer()
        url = nil
        isPlaying = false
        position = 0
        duration = 0
        failed = false
    }

    private func startTimer() {
        stopTimer()
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopTimer() { timer?.invalidate(); timer = nil }

    private func tick() {
        guard let player else { return }
        position = player.currentTime
        if !player.isPlaying {          // reached the end
            isPlaying = false
            stopTimer()
            position = player.duration
        }
    }
}
