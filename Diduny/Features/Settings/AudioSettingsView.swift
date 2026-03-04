import AVFoundation
import SwiftUI

struct AudioSettingsView: View {
    @Environment(AppState.self) var appState
    @State private var deviceManager = AudioDeviceManager()
    @StateObject private var testRecorderService = AudioRecorderService()

    // Test recording state
    @State private var isTestPlaying = false
    @State private var testRecordingURL: URL?
    @State private var testAudioPlayer: AVAudioPlayer?
    @State private var testStatusMessage = ""

    var body: some View {
        Form {
            Section {
                // Device list
                ForEach(deviceManager.availableDevices) { device in
                    HStack {
                        RadioButton(isSelected: appState.selectedDeviceID == device.id) {
                            appState.selectedDeviceID = device.id
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            Text(device.name)
                                .foregroundColor(appState.selectedDeviceID == device.id ? .primary : .secondary)

                            if device.isDefault {
                                Text("System Default")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }

                        Spacer()

                        if appState.selectedDeviceID == device.id {
                            Image(systemName: "checkmark")
                                .foregroundColor(.accentColor)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        appState.selectedDeviceID = device.id
                    }
                }
            } header: {
                Text("Input Device")
            }

            // Test Recording Section
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Button {
                            if isTestRecording {
                                stopTestRecording()
                            } else {
                                startTestRecording()
                            }
                        } label: {
                            HStack {
                                Image(systemName: isTestRecording ? "stop.circle.fill" : "mic.circle.fill")
                                    .foregroundColor(isTestRecording ? .red : .accentColor)
                                Text(isTestRecording ? "Stop Recording" : "Test Microphone")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(isTestRecording ? .red : .accentColor)
                        .disabled(isTestPlaying)

                        if testRecordingURL != nil, !isTestRecording {
                            Button {
                                if isTestPlaying {
                                    stopTestPlayback()
                                } else {
                                    playTestRecording()
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

                    // Audio level indicator
                    if isTestRecording {
                        HStack {
                            Text("Level:")
                                .foregroundColor(.secondary)
                            GeometryReader { geometry in
                                ZStack(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(Color.gray.opacity(0.3))
                                        .frame(height: 8)
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(levelColor)
                                        .frame(width: geometry.size.width * CGFloat(testRecorderService.audioLevel), height: 8)
                                }
                            }
                            .frame(height: 8)
                        }
                    }

                    if !testStatusMessage.isEmpty {
                        Text(testStatusMessage)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            } header: {
                Text("Test Recording")
            } footer: {
                Text("Record a short clip to test your microphone. The recording will play back through your speakers.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .onDisappear {
            cleanupTestRecording()
        }
    }

    // MARK: - Level Color

    private var levelColor: Color {
        if testRecorderService.audioLevel > 0.8 {
            .red
        } else if testRecorderService.audioLevel > 0.5 {
            .yellow
        } else {
            .green
        }
    }

    private var isTestRecording: Bool {
        testRecorderService.isRecording
    }

    // MARK: - Test Recording Methods

    private func startTestRecording() {
        let device: AudioDevice? = if let selectedID = appState.selectedDeviceID {
            deviceManager.availableDevices.first { $0.id == selectedID }
        } else {
            deviceManager.defaultDevice
        }

        testStatusMessage = "Starting test recording..."

        Task { @MainActor in
            do {
                try await testRecorderService.startRecording(device: device)
                testStatusMessage = "Recording... speak into your microphone"
            } catch {
                testStatusMessage = "Error: \(error.localizedDescription)"
            }
        }
    }

    private func stopTestRecording() {
        testStatusMessage = "Stopping test recording..."

        Task { @MainActor in
            do {
                let audioData = try await testRecorderService.stopRecording()
                let tempDir = FileManager.default.temporaryDirectory
                let fileName = "test_recording_\(UUID().uuidString).wav"
                let newURL = tempDir.appendingPathComponent(fileName)

                try audioData.write(to: newURL, options: .atomic)

                if let previousURL = testRecordingURL, previousURL != newURL {
                    try? FileManager.default.removeItem(at: previousURL)
                }

                testRecordingURL = newURL
                testStatusMessage = "Recording saved. Press Play to listen."
            } catch {
                testStatusMessage = "Error: \(error.localizedDescription)"
            }
        }
    }

    private func playTestRecording() {
        guard let url = testRecordingURL else {
            testStatusMessage = "No recording available"
            return
        }

        do {
            testAudioPlayer = try AVAudioPlayer(contentsOf: url)
            testAudioPlayer?.delegate = AudioPlayerDelegate.shared
            AudioPlayerDelegate.shared.onFinish = { [self] in
                DispatchQueue.main.async {
                    isTestPlaying = false
                    testStatusMessage = "Playback finished"
                }
            }
            testAudioPlayer?.play()
            isTestPlaying = true
            testStatusMessage = "Playing recording..."
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

    private func cleanupTestRecording() {
        testRecorderService.cancelRecording()

        testAudioPlayer?.stop()
        testAudioPlayer = nil

        if let url = testRecordingURL {
            try? FileManager.default.removeItem(at: url)
            testRecordingURL = nil
        }
    }
}

// MARK: - Radio Button

struct RadioButton: View {
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Circle()
                .strokeBorder(isSelected ? Color.accentColor : Color.secondary, lineWidth: 2)
                .background(
                    Circle()
                        .fill(isSelected ? Color.accentColor : Color.clear)
                        .padding(3)
                )
                .frame(width: 18, height: 18)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Audio Player Delegate

class AudioPlayerDelegate: NSObject, AVAudioPlayerDelegate {
    static let shared = AudioPlayerDelegate()
    var onFinish: (() -> Void)?

    func audioPlayerDidFinishPlaying(_: AVAudioPlayer, successfully _: Bool) {
        onFinish?()
    }
}

#Preview {
    AudioSettingsView()
        .environment(AppState())
        .frame(width: 450, height: 450)
}
