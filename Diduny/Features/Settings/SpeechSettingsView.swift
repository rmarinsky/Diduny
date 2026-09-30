import SwiftUI

/// Text-to-speech settings: 60db API key, voice catalog, model tier, and speed.
struct SpeechSettingsView: View {
    @State private var ttsService = SixtyDBTTSService.shared

    // API key
    @State private var apiKeyInput = ""
    @State private var hasStoredKey = false
    @State private var isTestingConnection = false
    @State private var connectionResult: ConnectionResult?

    // Voice
    @State private var selectedVoiceID = SettingsStorage.shared.ttsSelectedVoiceID ?? ""
    @State private var voicesError: String?

    // Config
    @State private var modelTier = SettingsStorage.shared.ttsModelTier
    @State private var speed = SettingsStorage.shared.ttsSpeed

    enum ConnectionResult {
        case success
        case failure(String)
    }

    var body: some View {
        Form {
            apiKeySection
            voiceSection
            modelSection
            speedSection
        }
        .formStyle(.grouped)
        .onAppear {
            hasStoredKey = ttsService.hasAPIKey
            selectedVoiceID = SettingsStorage.shared.ttsSelectedVoiceID ?? ""
            modelTier = SettingsStorage.shared.ttsModelTier
            speed = SettingsStorage.shared.ttsSpeed
        }
    }

    // MARK: - API Key Section

    private var apiKeySection: some View {
        Section {
            SecureField("API Key", text: $apiKeyInput)
                .textFieldStyle(.roundedBorder)

            HStack(spacing: 8) {
                Button("Save Key") {
                    saveAPIKey()
                }
                .buttonStyle(.bordered)
                .disabled(apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                if hasStoredKey {
                    Button("Remove Key") {
                        removeAPIKey()
                    }
                    .buttonStyle(.bordered)
                }

                Button("Test Connection") {
                    testConnection()
                }
                .buttonStyle(.bordered)
                .disabled(!hasStoredKey || isTestingConnection)

                if isTestingConnection {
                    ProgressView()
                        .controlSize(.small)
                }

                Spacer()
            }

            if let connectionResult {
                connectionResultView(connectionResult)
            }

            HStack(spacing: 4) {
                Image(systemName: hasStoredKey ? "checkmark.circle" : "key")
                    .foregroundColor(hasStoredKey ? .green : .secondary)
                Text(hasStoredKey ? "API key is stored in the Keychain." : "No API key configured.")
            }
            .font(.caption)
            .foregroundColor(.secondary)

            Text("Create a key in the 60db dashboard (app.60db.ai → Developers). The key is stored in your Mac's Keychain and sent only to api.60db.ai.")
                .font(.caption)
                .foregroundColor(.secondary)
        } header: {
            Text("60db API Key")
        } footer: {
            Text("Text-to-speech calls the 60db API directly; the transcription proxy is not involved.")
        }
    }

    // MARK: - Voice Section

    private var voiceSection: some View {
        Section {
            HStack(spacing: 8) {
                Button {
                    loadVoices()
                } label: {
                    Label("Load Voices", systemImage: "arrow.down.circle")
                }
                .buttonStyle(.bordered)
                .disabled(!hasStoredKey || ttsService.isLoadingVoices)

                if ttsService.isLoadingVoices {
                    ProgressView()
                        .controlSize(.small)
                }

                Spacer()
            }

            if let voicesError {
                Text(voicesError)
                    .font(.caption)
                    .foregroundColor(.red)
            }

            if ttsService.voices.isEmpty {
                Text(hasStoredKey ? "No voices loaded yet. Load the catalog or paste a voice ID below." : "Add an API key to enable text-to-speech.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                Picker("Voice", selection: $selectedVoiceID) {
                    Text("Default").tag("")
                    ForEach(ttsService.voices) { voice in
                        Text(voiceSubtitleLabel(voice)).tag(voice.voiceId.uuidString)
                    }
                }
            }

            TextField("Voice ID (optional)", text: $selectedVoiceID)
                .textFieldStyle(.roundedBorder)
                .font(.system(.caption, design: .monospaced))
                .onChange(of: selectedVoiceID) { _, newValue in
                    SettingsStorage.shared.ttsSelectedVoiceID = newValue.isEmpty ? nil : newValue
                }

            HStack {
                Text(currentVoiceSummary)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Button("Reset to Default") {
                    selectedVoiceID = ""
                    SettingsStorage.shared.ttsSelectedVoiceID = nil
                }
                .controlSize(.small)
                .disabled(selectedVoiceID.isEmpty)
            }
        } header: {
            Text("Voice")
        }
    }

    // MARK: - Model Section

    private var modelSection: some View {
        Section {
            Picker("Model", selection: $modelTier) {
                ForEach(TTSModelTier.allCases) { tier in
                    Text(tier.displayName).tag(tier)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: modelTier) { _, newValue in
                SettingsStorage.shared.ttsModelTier = newValue
                // The voice catalog differs per tier; drop the stale list.
                voicesError = nil
            }
        } header: {
            Text("Model")
        } footer: {
            Text("Quality lists professional voices; Fast lists cloned voices.")
        }
    }

    // MARK: - Speed Section

    private var speedSection: some View {
        Section {
            HStack {
                Slider(value: $speed, in: 0.5 ... 2.0, step: 0.05) {
                    Text("Speed")
                }
                .onChange(of: speed) { _, newValue in
                    SettingsStorage.shared.ttsSpeed = newValue
                }

                Text(String(format: "%.2f×", speed))
                    .monospacedDigit()
                    .frame(width: 48, alignment: .trailing)
            }
        } header: {
            Text("Speed")
        } footer: {
            Text("Speech rate multiplier applied to synthesized audio (0.5–2.0).")
        }
    }

    // MARK: - Helpers

    private var currentVoiceSummary: String {
        if selectedVoiceID.isEmpty {
            return "Using the 60db default voice."
        }
        if let voice = ttsService.voices.first(where: { $0.voiceId.uuidString == selectedVoiceID }) {
            return "Selected: \(voice.name)"
        }
        return "Selected voice ID: \(selectedVoiceID)"
    }

    private func voiceSubtitleLabel(_ voice: TTSVoice) -> String {
        voice.subtitle.isEmpty ? voice.name : "\(voice.name) — \(voice.subtitle)"
    }

    private func saveAPIKey() {
        do {
            try ttsService.saveAPIKey(apiKeyInput)
            apiKeyInput = ""
            hasStoredKey = ttsService.hasAPIKey
            connectionResult = nil
            voicesError = nil
        } catch {
            connectionResult = .failure("Failed to save key: \(error.localizedDescription)")
        }
    }

    private func removeAPIKey() {
        do {
            try ttsService.saveAPIKey(nil)
            hasStoredKey = false
            connectionResult = nil
        } catch {
            connectionResult = .failure("Failed to remove key: \(error.localizedDescription)")
        }
    }

    private func testConnection() {
        isTestingConnection = true
        connectionResult = nil

        Task {
            do {
                _ = try await ttsService.testConnection()
                connectionResult = .success
            } catch {
                connectionResult = .failure(error.localizedDescription)
            }
            isTestingConnection = false
        }
    }

    private func loadVoices() {
        voicesError = nil

        Task {
            do {
                try await ttsService.fetchVoices()
            } catch {
                voicesError = error.localizedDescription
            }
        }
    }

    @ViewBuilder
    private func connectionResultView(_ result: ConnectionResult) -> some View {
        HStack {
            switch result {
            case .success:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                Text("Connection successful")
                    .foregroundColor(.green)
            case let .failure(message):
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.red)
                Text(message)
                    .foregroundColor(.red)
            }
        }
        .font(.caption)
    }
}

#Preview {
    SpeechSettingsView()
        .frame(width: 500, height: 620)
}
