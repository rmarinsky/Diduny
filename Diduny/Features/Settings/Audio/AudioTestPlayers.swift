import AVFoundation
import Foundation

/// Plays back a test clip from Settings > Audio and reports when it ends.
@Observable
@MainActor
final class AudioTestPlayback: NSObject, AVAudioPlayerDelegate {
    private(set) var isPlaying = false
    private var player: AVAudioPlayer?
    var onFinish: (() -> Void)?

    func play(_ url: URL) throws {
        let player = try AVAudioPlayer(contentsOf: url)
        player.delegate = self
        player.play()
        self.player = player
        isPlaying = true
    }

    func stop() {
        player?.stop()
        player = nil
        isPlaying = false
    }

    nonisolated func audioPlayerDidFinishPlaying(_: AVAudioPlayer, successfully _: Bool) {
        Task { @MainActor in
            self.player = nil
            self.isPlaying = false
            self.onFinish?()
        }
    }
}

/// "Test system audio": capture a short clip of what the Mac plays, then play it back.
/// The meeting audio test flow (moved here from the removed `MeetingAudioSettingsView`).
@Observable
@MainActor
final class SystemAudioTester {
    private(set) var isCapturing = false
    private(set) var clipURL: URL?
    private(set) var status = ""
    let playback = AudioTestPlayback()
    private var service: SystemAudioCaptureService?

    init() {
        playback.onFinish = { [weak self] in self?.status = String(localized: "Playback finished") }
    }

    func toggleCapture() async {
        if isCapturing { await stop() } else { await start() }
    }

    func togglePlayback() {
        if playback.isPlaying {
            playback.stop()
            status = ""
            return
        }
        guard let clipURL else { status = String(localized: "No capture available"); return }
        do {
            try playback.play(clipURL)
            status = String(localized: "Playing captured audio...")
        } catch {
            status = String(localized: "Playback error: \(error.localizedDescription)")
        }
    }

    func cleanUp() {
        if isCapturing, let service { Task { _ = try? await service.stopCapture() } }
        isCapturing = false
        playback.stop()
        service = nil
        if let clipURL { try? FileManager.default.removeItem(at: clipURL) }
        clipURL = nil
    }

    private func start() async {
        #if TEST_BUILD
            // Fake system audio (test-plan 2.2): a silent clip, no Screen Recording permission.
            if UITestHarness.usesFakeAudio {
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("test_system_audio_\(UUID().uuidString).wav")
                try? UITestHarness.silentWAV().write(to: url)
                clipURL = url
                isCapturing = true
                status = String(localized: "Capturing... Play some audio on your Mac, then press Stop.")
                return
            }
        #endif
        guard await SystemAudioCaptureService.checkPermission() else {
            status = String(localized: "Screen Recording permission required. Please enable in System Settings > Privacy & Security.")
            return
        }
        if let clipURL { try? FileManager.default.removeItem(at: clipURL) }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("test_system_audio_\(UUID().uuidString).wav")
        clipURL = url
        let service = SystemAudioCaptureService()
        service.onError = { [weak self] error in
            DispatchQueue.main.async {
                self?.status = String(localized: "Error: \(error.localizedDescription)")
                self?.isCapturing = false
            }
        }
        self.service = service
        do {
            try await service.startCapture(to: url)
            isCapturing = true
            status = String(localized: "Capturing... Play some audio on your Mac, then press Stop.")
        } catch {
            status = String(localized: "Error starting capture: \(error.localizedDescription)")
        }
    }

    private func stop() async {
        do {
            _ = try await service?.stopCapture()
            status = String(localized: "Capture saved. Press Play to listen.")
        } catch {
            status = String(localized: "Error stopping capture: \(error.localizedDescription)")
        }
        isCapturing = false
    }
}
