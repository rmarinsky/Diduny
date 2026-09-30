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
    private var activeRange: AudioTrimRange?
    private var activeURL: URL?
    private var sourceStart: TimeInterval = 0
    private var sourceEnd: TimeInterval = 0
    private var timer: Timer?

    override private init() {
        super.init()
    }

    func togglePlayback(recordingId: UUID, fileURL: URL, trimRange: AudioTrimRange? = nil) {
        if playingRecordingId == recordingId, activeRange != trimRange || activeURL != fileURL { stop() }
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
            guard trimRange == nil || trimRange!.isValid(for: audioPlayer.duration) else { return }
            sourceStart = trimRange?.startSeconds ?? 0
            sourceEnd = trimRange?.endSeconds ?? audioPlayer.duration
            audioPlayer.currentTime = sourceStart
            audioPlayer.prepareToPlay()
            audioPlayer.play()
            activeRange = trimRange
            activeURL = fileURL

            player = audioPlayer
            playingRecordingId = recordingId
            isPlaying = true
            duration = sourceEnd - sourceStart
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
        activeRange = nil
        activeURL = nil
        sourceStart = 0
        sourceEnd = 0
        stopTimer()
        playingRecordingId = nil
        isPlaying = false
        currentTime = 0
        duration = 0
    }

    func seek(to time: TimeInterval) {
        guard time.isFinite, player != nil else { return }
        let relative = min(duration, max(0, time))
        player?.currentTime = sourceStart + relative
        currentTime = relative
    }

    // MARK: - Private

    private func pause() {
        player?.pause()
        isPlaying = false
        stopTimer()
    }

    private func resume() {
        if currentTime >= duration { player?.currentTime = sourceStart; currentTime = 0 }
        player?.play()
        isPlaying = true
        startTimer()
    }

    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.isSeeking else { return }
                guard let player = self.player else { return }
                if player.currentTime >= self.sourceEnd {
                    self.pause()
                    player.currentTime = self.sourceStart
                    self.currentTime = 0
                } else {
                    self.currentTime = max(0, player.currentTime - self.sourceStart)
                }
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
            player?.currentTime = sourceStart
            currentTime = 0
        }
    }
}
