import AVFoundation
import Foundation

@Observable
@MainActor
final class AudioPlaybackService: NSObject {
    static let shared = AudioPlaybackService()

    var playingRecordingId: UUID?
    var isPlaying: Bool = false
    var currentTime: TimeInterval = 0
    var duration: TimeInterval = 0
    var isSeeking: Bool = false

    private var player: AVAudioPlayer?
    private var timer: Timer?

    override private init() {
        super.init()
    }

    func togglePlayback(recordingId: UUID, fileURL: URL) {
        // If tapping a different recording, stop current first
        if let currentId = playingRecordingId, currentId != recordingId {
            stop()
        }

        // If already playing this recording, pause
        if isPlaying, playingRecordingId == recordingId {
            pause()
            return
        }

        // If paused on this recording, resume
        if !isPlaying, playingRecordingId == recordingId, player != nil {
            resume()
            return
        }

        // Start fresh playback
        do {
            let audioPlayer = try AVAudioPlayer(contentsOf: fileURL)
            audioPlayer.delegate = self
            audioPlayer.prepareToPlay()
            audioPlayer.play()

            player = audioPlayer
            playingRecordingId = recordingId
            isPlaying = true
            duration = audioPlayer.duration
            currentTime = 0
            startTimer()

            Log.playback.info("Started playback for recording \(recordingId)")
        } catch {
            Log.playback.error("Failed to start playback: \(error.localizedDescription)")
        }
    }

    func stop() {
        player?.stop()
        player = nil
        stopTimer()
        playingRecordingId = nil
        isPlaying = false
        currentTime = 0
        duration = 0
    }

    func seek(to time: TimeInterval) {
        player?.currentTime = time
        currentTime = time
    }

    // MARK: - Private

    private func pause() {
        player?.pause()
        isPlaying = false
        stopTimer()
    }

    private func resume() {
        player?.play()
        isPlaying = true
        startTimer()
    }

    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.isSeeking else { return }
                self.currentTime = self.player?.currentTime ?? 0
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}

// MARK: - AVAudioPlayerDelegate

extension AudioPlaybackService: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_: AVAudioPlayer, successfully _: Bool) {
        Task { @MainActor in
            stopTimer()
            isPlaying = false
            player?.currentTime = 0
            currentTime = 0
        }
    }
}
