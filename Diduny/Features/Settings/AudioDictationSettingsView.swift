import AVFoundation
import SwiftUI

struct AudioDictationSettingsView: View {
    @Environment(AppState.self) var appState
    @Environment(AudioDeviceManager.self) var deviceManager
    @StateObject private var testRecorderService = AudioRecorderService()

    @State private var isTestPlaying = false
    @State private var testRecordingURL: URL?
    @State private var testAudioPlayer: AVAudioPlayer?
    @State private var testStatusMessage = ""

    @State private var transcriptionProvider: TranscriptionProvider = SettingsStorage.shared.transcriptionProvider
    @State private var translationProvider: TranscriptionProvider = SettingsStorage.shared.translationProvider
    @State private var favoriteLanguageCodes: Set<String> = Set(SettingsStorage.shared.favoriteLanguages)
    @State private var translationLanguageA: String = SettingsStorage.shared.translationLanguageA
    @State private var translationLanguageB: String = SettingsStorage.shared.translationLanguageB

    private var translationPairLabel: String {
        "\(translationLanguageA.uppercased()) ↔ \(translationLanguageB.uppercased())"
    }

    var body: some View {
        Form {
            // MARK: Input Device

            Section {
                let effectiveUID = deviceManager.effectiveDeviceUID(preferred: appState.preferredDeviceUID)
                let isSystemDefault = effectiveUID == nil
                let preferredIsStale = appState.preferredDeviceUID != nil && effectiveUID == nil

                HStack(spacing: 8) {
                    RadioButton(isSelected: isSystemDefault) { appState.preferredDeviceUID = nil }
                    VStack(alignment: .leading, spacing: 1) {
                        Text("System Default")
                            .foregroundColor(isSystemDefault ? .primary : .secondary)
                        if preferredIsStale {
                            Text("Unavailable → System Default")
                                .font(.caption).foregroundColor(.orange)
                        } else if isSystemDefault, let name = deviceManager.defaultDevice?.name {
                            Text(name).font(.caption).foregroundColor(.secondary)
                        }
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
                .onTapGesture { appState.preferredDeviceUID = nil }

                ForEach(deviceManager.availableDevices) { device in
                    let isSelected = deviceManager.effectiveDeviceUID(preferred: appState.preferredDeviceUID) == device.uid
                    HStack(spacing: 8) {
                        RadioButton(isSelected: isSelected) { appState.preferredDeviceUID = device.uid }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(device.name).foregroundColor(isSelected ? .primary : .secondary)
                            Text(deviceSubtitle(for: device)).font(.caption).foregroundColor(.secondary).lineLimit(1)
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { appState.preferredDeviceUID = device.uid }
                }
            } header: { Text("Input Device") }

            // MARK: Test Recording

            Section {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Button {
                            if isTestRecording { stopTestRecording() } else { startTestRecording() }
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
                                if isTestPlaying { stopTestPlayback() } else { playTestRecording() }
                            } label: {
                                HStack {
                                    Image(systemName: isTestPlaying ? "stop.fill" : "play.fill")
                                    Text(isTestPlaying ? "Stop" : "Play")
                                }
                            }
                            .buttonStyle(.bordered)
                        }
                    }

                    if isTestRecording {
                        HStack {
                            Text("Level:").foregroundColor(.secondary)
                            GeometryReader { geometry in
                                ZStack(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: 4).fill(Color.gray.opacity(0.3)).frame(height: 8)
                                    RoundedRectangle(cornerRadius: 4).fill(levelColor)
                                        .frame(width: geometry.size.width * CGFloat(testRecorderService.audioLevel), height: 8)
                                }
                            }
                            .frame(height: 8)
                        }
                    }

                    if !testStatusMessage.isEmpty {
                        Text(testStatusMessage).font(.caption).foregroundColor(.secondary)
                    }
                }
            } header: { Text("Test Recording") } footer: {
                Text("Record a short clip to test your microphone. The recording will play back through your speakers.")
                    .font(.caption).foregroundColor(.secondary)
            }

            // MARK: Transcription Provider

            Section("Transcription Provider") {
                Picker("Provider", selection: $transcriptionProvider) {
                    ForEach(TranscriptionProvider.allCases) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: transcriptionProvider) { _, v in SettingsStorage.shared.transcriptionProvider = v }
            }

            // MARK: Translation Provider

            Section("Translation Provider") {
                Picker("Provider", selection: $translationProvider) {
                    ForEach(TranscriptionProvider.allCases) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: translationProvider) { _, v in SettingsStorage.shared.translationProvider = v }
            }

            if translationProvider == .cloud {
                // MARK: Translation Languages

                Section("Default Translation Pair") {
                    Picker("Language A", selection: $translationLanguageA) {
                        ForEach(SupportedLanguage.cloudLanguages.filter { $0.code != translationLanguageB }) { lang in
                            Text(lang.name).tag(lang.code)
                        }
                    }
                    .onChange(of: translationLanguageA) { _, v in SettingsStorage.shared.translationLanguageA = v }

                    Picker("Language B", selection: $translationLanguageB) {
                        ForEach(SupportedLanguage.cloudLanguages.filter { $0.code != translationLanguageA }) { lang in
                            Text(lang.name).tag(lang.code)
                        }
                    }
                    .onChange(of: translationLanguageB) { _, v in SettingsStorage.shared.translationLanguageB = v }

                    Text("Pair: \(translationPairLabel)").font(.caption).foregroundColor(.secondary)
                }

                Section("Favorite Languages") {
                    ForEach(SupportedLanguage.cloudLanguages) { lang in
                        Toggle(lang.name, isOn: Binding(
                            get: { favoriteLanguageCodes.contains(lang.code) },
                            set: { isOn in
                                if isOn { favoriteLanguageCodes.insert(lang.code) }
                                else { favoriteLanguageCodes.remove(lang.code) }
                                SettingsStorage.shared.favoriteLanguages = SupportedLanguage.cloudLanguages
                                    .map(\.code).filter { favoriteLanguageCodes.contains($0) }
                            }
                        ))
                        .toggleStyle(.checkbox)
                    }
                    Text("Selected languages are hints for cloud transcription (60 languages supported).")
                        .font(.caption).foregroundColor(.secondary)
                }
            } else {
                Section("Local Whisper Translation") {
                    Label("Whisper translates any language to English only.", systemImage: "info.circle")
                        .font(.callout).foregroundColor(.secondary)
                    whisperTranslationStatus
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            transcriptionProvider = SettingsStorage.shared.transcriptionProvider
            translationProvider = SettingsStorage.shared.translationProvider
            favoriteLanguageCodes = Set(SettingsStorage.shared.favoriteLanguages)
            translationLanguageA = SettingsStorage.shared.translationLanguageA
            translationLanguageB = SettingsStorage.shared.translationLanguageB
        }
        .onDisappear { cleanupTestRecording() }
    }

    // MARK: - Whisper Translation Status

    @ViewBuilder
    private var whisperTranslationStatus: some View {
        let selected = WhisperModelManager.shared.selectedModel()
        if let model = selected {
            if model.isEnglishOnly {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Model \"\(model.displayName)\" is English-only").fontWeight(.medium)
                        Text("English-only models cannot translate. Select a multilingual model in Models.")
                            .font(.caption).foregroundColor(.secondary)
                    }
                } icon: { Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange) }
            } else {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Model \"\(model.displayName)\" supports translation").fontWeight(.medium)
                        Text("Speech in any language will be translated to English.")
                            .font(.caption).foregroundColor(.secondary)
                    }
                } icon: { Image(systemName: "checkmark.circle.fill").foregroundColor(.green) }
            }
        } else {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("No model selected").fontWeight(.medium)
                    Text("Download and select a multilingual model in the Models tab.")
                        .font(.caption).foregroundColor(.secondary)
                }
            } icon: { Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange) }
        }
    }

    // MARK: - Helpers

    private var levelColor: Color {
        testRecorderService.audioLevel > 0.8 ? .red : testRecorderService.audioLevel > 0.5 ? .yellow : .green
    }

    private var isTestRecording: Bool { testRecorderService.isRecording }

    private func deviceSubtitle(for device: AudioDevice) -> String {
        var parts: [String] = []
        if device.isDefault { parts.append("Default") }
        if device.transportType != .unknown { parts.append(device.transportType.displayName) }
        return parts.joined(separator: " · ")
    }

    private func startTestRecording() {
        let (device, _) = deviceManager.resolveDevice(preferredUID: appState.preferredDeviceUID)
        testStatusMessage = "Starting test recording..."
        Task { @MainActor in
            do {
                try await testRecorderService.startRecording(device: device)
                testStatusMessage = "Recording… speak into your microphone"
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
                let fileName = "test_recording_\(UUID().uuidString).wav"
                let newURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
                try audioData.write(to: newURL, options: .atomic)
                if let prev = testRecordingURL, prev != newURL { try? FileManager.default.removeItem(at: prev) }
                testRecordingURL = newURL
                testStatusMessage = "Recording saved. Press Play to listen."
            } catch {
                testStatusMessage = "Error: \(error.localizedDescription)"
            }
        }
    }

    private func playTestRecording() {
        guard let url = testRecordingURL else { testStatusMessage = "No recording available"; return }
        do {
            testAudioPlayer = try AVAudioPlayer(contentsOf: url)
            testAudioPlayer?.delegate = AudioPlayerDelegate.shared
            AudioPlayerDelegate.shared.onFinish = { [self] in
                DispatchQueue.main.async { isTestPlaying = false; testStatusMessage = "Playback finished" }
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
        if let url = testRecordingURL { try? FileManager.default.removeItem(at: url); testRecordingURL = nil }
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
