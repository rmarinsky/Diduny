import AVFoundation
import SwiftUI

struct MeetingSettingsView: View {
    var body: some View {
        Form {
            CalendarSettingsSection()
            Section {
                Button("Meeting audio and transcription…") {
                    MainWindowController.shared.showsMeetingAudioSettings = true
                    MainWindowController.shared.showWindow(section: .audioDictation)
                }
            } footer: {
                Text("Choose the provider, audio sources and recording levels in Audio & Dictation.")
            }
        }.formStyle(.grouped)
    }
}

struct MeetingAudioSettingsView: View {
    @State private var meetingSuggestionsEnabled = SettingsStorage.shared.meetingSuggestionsEnabled
    @State private var meetingCloudModeEnabled: Bool = SettingsStorage.shared.meetingRealtimeTranscriptionEnabled
    @State private var localLivePreviewEnabled = SettingsStorage.shared.meetingLocalLivePreviewEnabled
    @State private var silenceAutoStopEnabled = SettingsStorage.shared.meetingSilenceAutoStopEnabled
    @State private var silenceAutoStopSeconds = SettingsStorage.shared.meetingSilenceAutoStopSeconds
    @State private var audioSource = SettingsStorage.shared.meetingAudioSource
    @State private var micGain = SettingsStorage.shared.meetingMicGain
    @State private var systemGain = SettingsStorage.shared.meetingSystemGain

    // Test capture state
    @State private var isTestCapturing = false
    @State private var isTestPlaying = false
    @State private var testCaptureURL: URL?
    @State private var testAudioPlayer: AVAudioPlayer?
    @State private var testStatusMessage = String(localized: "")
    @State private var captureService: SystemAudioCaptureService?

    var body: some View {
        Form {
            Section {
                Toggle("Suggest recording when a meeting starts", isOn: $meetingSuggestionsEnabled)
                    .onChange(of: meetingSuggestionsEnabled) { _, newValue in
                        SettingsStorage.shared.meetingSuggestionsEnabled = newValue
                    }
            } header: {
                Text("Meeting Suggestions")
            } footer: {
                Text(
                    "Diduny checks meeting app activity locally. Recording starts only after you choose to start it."
                )
                .font(.caption)
                .foregroundColor(.secondary)
            }

            Section("Meeting Provider") {
                Picker("Provider", selection: $meetingCloudModeEnabled) {
                    Text("Cloud").tag(true)
                    Text("Local").tag(false)
                }
                .pickerStyle(.segmented)
                .onChange(of: meetingCloudModeEnabled) { _, newValue in
                    SettingsStorage.shared.meetingRealtimeTranscriptionEnabled = newValue
                }

                if meetingCloudModeEnabled {
                    Text(
                        "Cloud mode streams live transcription. If it is unavailable, Diduny transcribes in the cloud after stop."
                    )
                    .font(.caption)
                    .foregroundColor(.secondary)
                } else {
                    Text(
                        "Local mode transcribes on this Mac after stop when a model is ready. Without one, saved audio stays unprocessed in Recordings."
                    )
                    .font(.caption)
                    .foregroundColor(.secondary)

                    Toggle("Live preview during recording", isOn: $localLivePreviewEnabled)
                        .onChange(of: localLivePreviewEnabled) { _, newValue in
                            SettingsStorage.shared.meetingLocalLivePreviewEnabled = newValue
                        }
                    Text(
                        "Runs Whisper every few seconds while you record. Turn off to save battery; transcription still runs after stop."
                    )
                    .font(.caption)
                    .foregroundColor(.secondary)
                }
            }

            SilenceAutoStopSection(
                footer: "Stops the meeting recording when both your microphone and the meeting audio stay quiet this long, once someone has spoken. A countdown shows for the last 3 seconds.",
                range: SettingsStorage.meetingSilenceAutoStopRange,
                step: 10,
                isEnabled: $silenceAutoStopEnabled,
                seconds: $silenceAutoStopSeconds
            )
            .onChange(of: silenceAutoStopEnabled) { _, value in
                SettingsStorage.shared.meetingSilenceAutoStopEnabled = value
            }
            .onChange(of: silenceAutoStopSeconds) { _, value in
                SettingsStorage.shared.meetingSilenceAutoStopSeconds = value
            }

            Section {
                Picker("Audio Source", selection: $audioSource) {
                    ForEach(MeetingAudioSource.allCases, id: \.self) { source in
                        Text(source.displayName).tag(source)
                    }
                }
                .pickerStyle(.radioGroup)
                .onChange(of: audioSource) { _, value in
                    SettingsStorage.shared.meetingAudioSource = value
                }
                Text(audioSource.description).font(.caption).foregroundStyle(.secondary)
            } header: {
                Text("Meeting Recording")
            } footer: {
                Text(
                    "Meeting recording captures system audio for transcribing calls and meetings. Requires Screen Recording permission."
                )
                .font(.caption)
                .foregroundColor(.secondary)
            }

            SpeakerLabelsSection(audioSource: audioSource)

            if audioSource == .systemPlusMicrophone {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Microphone")
                                Spacer()
                                Text("\(Int(micGain * 100))%")
                                    .foregroundColor(.secondary)
                                    .monospacedDigit()
                            }
                            Slider(value: $micGain, in: 0 ... 2, step: 0.05) { editing in
                                if !editing {
                                    SettingsStorage.shared.meetingMicGain = micGain
                                }
                            }
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("System Audio")
                                Spacer()
                                Text("\(Int(systemGain * 100))%")
                                    .foregroundColor(.secondary)
                                    .monospacedDigit()
                            }
                            Slider(value: $systemGain, in: 0 ... 2, step: 0.05) { editing in
                                if !editing {
                                    SettingsStorage.shared.meetingSystemGain = systemGain
                                }
                            }
                        }
                    }
                } header: {
                    Text("Audio Gain")
                } footer: {
                    Text(
                        "Adjust the volume balance between your microphone and system audio. Changes apply to the next recording."
                    )
                    .font(.caption)
                    .foregroundColor(.secondary)
                }
            }

            // Test System Audio Capture Section
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
        .formStyle(.grouped)
        .onAppear {
            meetingSuggestionsEnabled = SettingsStorage.shared.meetingSuggestionsEnabled
            meetingCloudModeEnabled = SettingsStorage.shared.meetingRealtimeTranscriptionEnabled
            localLivePreviewEnabled = SettingsStorage.shared.meetingLocalLivePreviewEnabled
            audioSource = SettingsStorage.shared.meetingAudioSource
            micGain = SettingsStorage.shared.meetingMicGain
            systemGain = SettingsStorage.shared.meetingSystemGain
        }
        .onDisappear {
            cleanupTestCapture()
        }
    }

    // MARK: - Test Capture Methods

    private func startTestCapture() async {
        // Check permission first
        let hasPermission = await SystemAudioCaptureService.checkPermission()
        if !hasPermission {
            await MainActor.run {
                testStatusMessage =
                    String(
                        localized: "Screen Recording permission required. Please enable in System Settings > Privacy & Security."
                    )
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
                    testStatusMessage = String(localized: "Error: \(error.localizedDescription)")
                    isTestCapturing = false
                }
            }
        }

        do {
            try await captureService?.startCapture(to: url)
            await MainActor.run {
                isTestCapturing = true
                testStatusMessage = String(localized: "Capturing... Play some audio on your Mac, then press Stop.")
            }
        } catch {
            await MainActor.run {
                testStatusMessage = String(localized: "Error starting capture: \(error.localizedDescription)")
            }
        }
    }

    private func stopTestCapture() async {
        do {
            _ = try await captureService?.stopCapture()
            await MainActor.run {
                isTestCapturing = false
                testStatusMessage = String(localized: "Capture saved. Press Play to listen.")
            }
        } catch {
            await MainActor.run {
                isTestCapturing = false
                testStatusMessage = String(localized: "Error stopping capture: \(error.localizedDescription)")
            }
        }
    }

    private func playTestCapture() {
        guard let url = testCaptureURL else {
            testStatusMessage = String(localized: "No capture available")
            return
        }

        do {
            testAudioPlayer = try AVAudioPlayer(contentsOf: url)
            testAudioPlayer?.delegate = SystemAudioPlayerDelegate.shared
            SystemAudioPlayerDelegate.shared.onFinish = {
                DispatchQueue.main.async {
                    isTestPlaying = false
                    testStatusMessage = String(localized: "Playback finished")
                }
            }
            testAudioPlayer?.play()
            isTestPlaying = true
            testStatusMessage = String(localized: "Playing captured audio...")
        } catch {
            testStatusMessage = String(localized: "Playback error: \(error.localizedDescription)")
        }
    }

    private func stopTestPlayback() {
        testAudioPlayer?.stop()
        testAudioPlayer = nil
        isTestPlaying = false
        testStatusMessage = String(localized: "")
    }

    private func cleanupTestCapture() {
        if isTestCapturing {
            Task {
                _ = try? await captureService?.stopCapture()
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
