import AVFoundation
import Foundation

/// Owns the audio player for a saved meeting recording so the player bar and the
/// synced transcript share one playback clock.
///
/// `currentTime` is the transcript view's only redraw trigger, so the clock runs
/// on a 50 ms timer that exists only while audio is actually playing, and it
/// republishes only when the position moved by at least `publishThreshold`.
@MainActor
final class MeetingPlaybackModel: ObservableObject {
    /// Seconds into the recording.
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var isLoaded = false
    @Published private(set) var loadFailed = false

    /// Smallest clock move worth republishing: everything else is a redraw of
    /// every transcript bubble for no visible change.
    private static let publishThreshold: TimeInterval = 0.02
    private static let tickInterval: TimeInterval = 0.05
    /// `AVAudioPlayer.currentTime` sits this close to `duration` when a play
    /// request should restart from the top instead.
    private static let endTolerance: TimeInterval = 0.1

    private var player: AVAudioPlayer?
    private var timer: Timer?
    private var lastPublishedTime: TimeInterval = 0
    private var loadingURL: URL?

    deinit {
        timer?.invalidate()
    }

    /// Prepares the recording and parks the clock at 0. `async` so callers can
    /// open a recording from `.task` without blocking the first paint.
    func load(url: URL) async {
        stop()
        loadingURL = url
        loadFailed = false
        isLoaded = false
        duration = 0
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.prepareToPlay()
            // A newer load may have started while this one was opening.
            guard loadingURL == url else { return }
            self.player = player
            duration = player.duration
            isLoaded = true
        } catch {
            guard loadingURL == url else { return }
            player = nil
            loadFailed = true
        }
    }

    func togglePlayback() {
        guard let player else { return }
        guard !player.isPlaying else {
            pause()
            return
        }
        if player.currentTime >= max(player.duration - Self.endTolerance, 0) {
            player.currentTime = 0
            publish(0)
        }
        player.play()
        isPlaying = true
        startTimer()
    }

    func seek(to seconds: TimeInterval) {
        guard let player else { return }
        let clamped = min(max(seconds, 0), player.duration)
        player.currentTime = clamped
        publish(clamped)
    }

    /// Stops audio and parks the clock at the start of the recording.
    func stop() {
        stopTimer()
        player?.stop()
        player?.currentTime = 0
        isPlaying = false
        publish(0)
    }

    private func pause() {
        player?.pause()
        stopTimer()
        isPlaying = false
        publish(player?.currentTime ?? 0)
    }

    private func tick() {
        guard let player else {
            stopTimer()
            return
        }
        guard player.isPlaying else {
            finishPlayback()
            return
        }
        guard abs(player.currentTime - lastPublishedTime) >= Self.publishThreshold else { return }
        publish(player.currentTime)
    }

    /// End of file (or the system stopped the player under us): park the clock
    /// at the start, matching the shipped player bar.
    private func finishPlayback() {
        stopTimer()
        player?.currentTime = 0
        isPlaying = false
        publish(0)
    }

    private func startTimer() {
        stopTimer()
        let timer = Timer(timeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func publish(_ time: TimeInterval) {
        guard time != currentTime else { return }
        lastPublishedTime = time
        currentTime = time
    }
}
