import AVFoundation
import SwiftUI

struct MeetingSettingsView: View {
    @State private var audioSource = SettingsStorage.shared.meetingAudioSource

    // Test capture state
    @State private var isTestCapturing = false
    @State private var isTestPlaying = false
    @State private var testCaptureURL: URL?
    @State private var testAudioPlayer: AVAudioPlayer?
    @State private var testStatusMessage = ""
    @State private var captureService: SystemAudioCaptureService?

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Audio Source")
                        .font(.headline)

                    ForEach(MeetingAudioSource.allCases, id: \.self) { source in
                        HStack {
                            Image(systemName: audioSource == source ? "circle.inset.filled" : "circle")
                                .foregroundColor(audioSource == source ? .accentColor : .secondary)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(source.displayName)
                                Text(source.description)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }

                            Spacer()
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            audioSource = source
                            SettingsStorage.shared.meetingAudioSource = source
                        }
                    }
                }
            } header: {
                Text("Meeting Recording")
            } footer: {
                Text(
                    "Meeting recording captures system audio for transcribing calls and meetings. Requires Screen Recording permission."
                )
                .font(.caption)
                .foregroundColor(.secondary)
            }

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Hotkey: ⌘⇧M")
                        .font(.subheadline)

                    Text("Or use Menu → Record Meeting")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } header: {
                Text("How to Use")
            }

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Supports recordings up to 1+ hour", systemImage: "clock")
                    Label("Transcription starts after you stop", systemImage: "text.bubble")
                    Label("Result copied to clipboard", systemImage: "doc.on.clipboard")
                }
                .font(.subheadline)
                .foregroundColor(.secondary)
            } header: {
                Text("Features")
            }

            // Test System Audio Capture Section
            if #available(macOS 13.0, *) {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Button {
                                if isTestCapturing {
                                    Task { await stopTestCapture() }
                                } else {
                                    Task { await startTestCapture() }
                                }
                            } label: {
                                HStack {
                                    Image(systemName: isTestCapturing ? "stop.circle.fill" : "waveform.circle.fill")
                                        .foregroundColor(isTestCapturing ? .red : .accentColor)
                                    Text(isTestCapturing ? "Stop Capture" : "Test System Audio")
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(isTestCapturing ? .red : .accentColor)
                            .disabled(isTestPlaying)

                            if testCaptureURL != nil, !isTestCapturing {
                                Button {
                                    if isTestPlaying {
                                        stopTestPlayback()
                                    } else {
                                        playTestCapture()
                                    }
                                } label: {
                                    HStack {
                                        Image(systemName: isTestPlaying ? "stop.fill" : "play.fill")
                                        Text(isTestPlaying ? "Stop" : "Play")
                                    }
                                }
                                .buttonStyle(.bordered)
                            }
                        }

                        if isTestCapturing {
                            HStack {
                                ProgressView()
                                    .scaleEffect(0.8)
                                Text("Capturing system audio...")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }

                        if !testStatusMessage.isEmpty {
                            Text(testStatusMessage)
                                .font(.caption)
                                .foregroundColor(testStatusMessage.contains("Error") || testStatusMessage
                                    .contains("permission") ? .red : .secondary)
                        }
                    }
                } header: {
                    Text("Test System Audio Capture")
                } footer: {
                    Text(
                        "Play audio on your Mac (music, video, etc.) while capturing to test. Requires Screen Recording permission."
                    )
                    .font(.caption)
                    .foregroundColor(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onDisappear {
            cleanupTestCapture()
        }
    }

    // MARK: - Test Capture Methods

    @available(macOS 13.0, *)
    private func startTestCapture() async {
        // Check permission first
        let hasPermission = await SystemAudioCaptureService.checkPermission()
        if !hasPermission {
            await MainActor.run {
                testStatusMessage = "Screen Recording permission required. Please enable in System Settings > Privacy & Security."
            }
            return
        }

        // Create temp file
        let tempDir = FileManager.default.temporaryDirectory
        let fileName = "test_system_audio_\(UUID().uuidString).wav"
        let url = tempDir.appendingPathComponent(fileName)

        await MainActor.run {
            testCaptureURL = url
            captureService = SystemAudioCaptureService()
            captureService?.onError = { error in
                DispatchQueue.main.async {
                    testStatusMessage = "Error: \(error.localizedDescription)"
                    isTestCapturing = false
                }
            }
        }

        do {
            try await captureService?.startCapture(to: url)
            await MainActor.run {
                isTestCapturing = true
                testStatusMessage = "Capturing... Play some audio on your Mac, then press Stop."
            }
        } catch {
            await MainActor.run {
                testStatusMessage = "Error starting capture: \(error.localizedDescription)"
            }
        }
    }

    @available(macOS 13.0, *)
    private func stopTestCapture() async {
        do {
            _ = try await captureService?.stopCapture()
            await MainActor.run {
                isTestCapturing = false
                testStatusMessage = "Capture saved. Press Play to listen."
            }
        } catch {
            await MainActor.run {
                isTestCapturing = false
                testStatusMessage = "Error stopping capture: \(error.localizedDescription)"
            }
        }
    }

    private func playTestCapture() {
        guard let url = testCaptureURL else {
            testStatusMessage = "No capture available"
            return
        }

        do {
            testAudioPlayer = try AVAudioPlayer(contentsOf: url)
            testAudioPlayer?.delegate = SystemAudioPlayerDelegate.shared
            SystemAudioPlayerDelegate.shared.onFinish = {
                DispatchQueue.main.async {
                    isTestPlaying = false
                    testStatusMessage = "Playback finished"
                }
            }
            testAudioPlayer?.play()
            isTestPlaying = true
            testStatusMessage = "Playing captured audio..."
        } catch {
            testStatusMessage = "Playback error: \(error.localizedDescription)"
        }
    }

    private func stopTestPlayback() {
        testAudioPlayer?.stop()
        testAudioPlayer = nil
        isTestPlaying = false
        testStatusMessage = ""
    }

    private func cleanupTestCapture() {
        if #available(macOS 13.0, *) {
            if isTestCapturing {
                Task {
                    _ = try? await captureService?.stopCapture()
                }
            }
        }

        testAudioPlayer?.stop()
        testAudioPlayer = nil
        captureService = nil

        if let url = testCaptureURL {
            try? FileManager.default.removeItem(at: url)
            testCaptureURL = nil
        }
    }
}

// MARK: - System Audio Player Delegate

class SystemAudioPlayerDelegate: NSObject, AVAudioPlayerDelegate {
    static let shared = SystemAudioPlayerDelegate()
    var onFinish: (() -> Void)?

    func audioPlayerDidFinishPlaying(_: AVAudioPlayer, successfully _: Bool) {
        onFinish?()
    }
}

#Preview {
    MeetingSettingsView()
        .frame(width: 450, height: 550)
}
