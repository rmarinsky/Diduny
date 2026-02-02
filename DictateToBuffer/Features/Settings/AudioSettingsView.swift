import AVFoundation
import CoreAudio
import SwiftUI

struct AudioSettingsView: View {
    @Environment(AppState.self) var appState
    @StateObject private var deviceManager = AudioDeviceManager()
    @State private var audioQuality = SettingsStorage.shared.audioQuality

    // Test recording state
    @State private var isTestRecording = false
    @State private var isTestPlaying = false
    @State private var testAudioLevel: Float = 0
    @State private var testRecordingURL: URL?
    @State private var testAudioPlayer: AVAudioPlayer?
    @State private var testRecorder: AVAudioRecorder?
    @State private var levelTimer: Timer?
    @State private var testStatusMessage = ""

    var body: some View {
        Form {
            Section {
                Picker("Quality", selection: $audioQuality) {
                    ForEach(AudioQuality.allCases, id: \.self) { quality in
                        Text(quality.displayName).tag(quality)
                    }
                }
                .onChange(of: audioQuality) { _, newValue in
                    SettingsStorage.shared.audioQuality = newValue
                }
            } header: {
                Text("Audio Quality")
            }

            Section {
                // Auto-detect option
                HStack {
                    RadioButton(isSelected: appState.useAutoDetect) {
                        appState.useAutoDetect = true
                        appState.selectedDeviceID = nil
                    }
                    Text("Auto-detect best device")
                        .foregroundColor(appState.useAutoDetect ? .primary : .secondary)
                    Spacer()
                    if appState.useAutoDetect {
                        Image(systemName: "checkmark")
                            .foregroundColor(.accentColor)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    appState.useAutoDetect = true
                    appState.selectedDeviceID = nil
                }

                Divider()

                // Device list
                ForEach(deviceManager.availableDevices) { device in
                    HStack {
                        RadioButton(isSelected: !appState.useAutoDetect && appState.selectedDeviceID == device.id) {
                            appState.useAutoDetect = false
                            appState.selectedDeviceID = device.id
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            Text(device.name)
                                .foregroundColor(!appState.useAutoDetect && appState.selectedDeviceID == device
                                    .id ? .primary : .secondary)

                            if device.isDefault {
                                Text("System Default")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }

                        Spacer()

                        if !appState.useAutoDetect, appState.selectedDeviceID == device.id {
                            Image(systemName: "checkmark")
                                .foregroundColor(.accentColor)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        appState.useAutoDetect = false
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
                                    Rectangle()
                                        .fill(Color.gray.opacity(0.3))
                                        .frame(height: 8)
                                        .cornerRadius(4)
                                    Rectangle()
                                        .fill(levelColor)
                                        .frame(width: geometry.size.width * CGFloat(testAudioLevel), height: 8)
                                        .cornerRadius(4)
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
        if testAudioLevel > 0.8 {
            .red
        } else if testAudioLevel > 0.5 {
            .yellow
        } else {
            .green
        }
    }

    // MARK: - Test Recording Methods

    private func startTestRecording() {
        // Get the selected device
        let device: AudioDevice? = if appState.useAutoDetect {
            deviceManager.defaultDevice
        } else if let selectedID = appState.selectedDeviceID {
            deviceManager.availableDevices.first { $0.id == selectedID }
        } else {
            deviceManager.defaultDevice
        }

        // Set input device if specified
        if let device {
            setInputDevice(device.id)
        }

        // Create temp file
        let tempDir = FileManager.default.temporaryDirectory
        let fileName = "test_recording_\(UUID().uuidString).wav"
        testRecordingURL = tempDir.appendingPathComponent(fileName)

        guard let url = testRecordingURL else {
            testStatusMessage = "Failed to create recording file"
            return
        }

        // Configure audio settings
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: audioQuality.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]

        do {
            testRecorder = try AVAudioRecorder(url: url, settings: settings)
            testRecorder?.isMeteringEnabled = true
            testRecorder?.prepareToRecord()

            guard testRecorder?.record() == true else {
                testStatusMessage = "Failed to start recording"
                return
            }

            isTestRecording = true
            testStatusMessage = "Recording... speak into your microphone"
            startLevelMonitoring()
        } catch {
            testStatusMessage = "Error: \(error.localizedDescription)"
        }
    }

    private func stopTestRecording() {
        stopLevelMonitoring()
        testRecorder?.stop()
        testRecorder = nil
        isTestRecording = false
        testAudioLevel = 0
        testStatusMessage = "Recording saved. Press Play to listen."
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
        stopLevelMonitoring()
        testRecorder?.stop()
        testRecorder = nil
        testAudioPlayer?.stop()
        testAudioPlayer = nil

        if let url = testRecordingURL {
            try? FileManager.default.removeItem(at: url)
            testRecordingURL = nil
        }
    }

    private func startLevelMonitoring() {
        levelTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            updateAudioLevel()
        }
    }

    private func stopLevelMonitoring() {
        levelTimer?.invalidate()
        levelTimer = nil
    }

    private func updateAudioLevel() {
        testRecorder?.updateMeters()
        let level = testRecorder?.averagePower(forChannel: 0) ?? -160

        // Convert dB to linear scale (0-1)
        let minDb: Float = -60
        let normalizedLevel = max(0, (level - minDb) / -minDb)
        testAudioLevel = normalizedLevel
    }

    private func setInputDevice(_ deviceID: AudioDeviceID) {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var mutableDeviceID = deviceID
        let dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)

        AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            dataSize,
            &mutableDeviceID
        )
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
