import SwiftUI

struct TranscriptionSettingsView: View {
    @State private var transcriptionProvider: TranscriptionProvider = SettingsStorage.shared.transcriptionProvider
    @State private var selectedModel: String = SettingsStorage.shared.selectedWhisperModel
    @State private var modelSort: ModelSort = .speed
    @State private var whisperLanguage: String = SettingsStorage.shared.whisperLanguage
    @State private var whisperPrompt: String = SettingsStorage.shared.whisperPrompt
    @State private var sonioxPrompt: String = SettingsStorage.shared.sonioxPrompt
    @State private var favoriteLanguageCodes: Set<String> = Set(SettingsStorage.shared.favoriteLanguages)
    @State private var sonioxLanguageHintCodes: Set<String> = Set(SettingsStorage.shared.sonioxLanguageHints)
    @State private var sonioxLanguageHintsStrict: Bool = SettingsStorage.shared.sonioxLanguageHintsStrict
    @State private var translationRealtimeSocketEnabled: Bool = SettingsStorage.shared.translationRealtimeSocketEnabled
    @State private var transcriptionRealtimeSocketEnabled: Bool = SettingsStorage.shared.transcriptionRealtimeSocketEnabled
    @State private var meetingCloudModeEnabled: Bool = SettingsStorage.shared.meetingRealtimeTranscriptionEnabled

    enum ModelSort: String, CaseIterable {
        case speed, accuracy

        var label: String {
            switch self {
            case .speed: "Speed"
            case .accuracy: "Accuracy"
            }
        }
    }

    // Soniox state
    @State private var sonioxAPIKey: String = ""
    @State private var showSonioxKey = false
    @State private var isTesting = false
    @State private var testResult: TestResult?
    @State private var keychainAccessible = true

    private let modelManager = WhisperModelManager.shared

    enum TestResult {
        case success
        case failure(String)
    }

    // Soniox is always needed (translation + meeting always use cloud)
    private var needsSoniox: Bool { true }

    private var needsWhisper: Bool {
        transcriptionProvider == .whisperLocal
    }

    private var hasSonioxKey: Bool {
        !sonioxAPIKey.isEmpty
    }

    var body: some View {
        Form {
            // Transcription provider
            Section("Transcription") {
                Picker("Provider", selection: $transcriptionProvider) {
                    ForEach(TranscriptionProvider.allCases) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: transcriptionProvider) { _, newValue in
                    SettingsStorage.shared.transcriptionProvider = newValue
                }

                if transcriptionProvider == .soniox {
                    Toggle("Realtime dictation via WebSocket", isOn: $transcriptionRealtimeSocketEnabled)
                        .onChange(of: transcriptionRealtimeSocketEnabled) { _, newValue in
                            SettingsStorage.shared.transcriptionRealtimeSocketEnabled = newValue
                        }
                        .disabled(!hasSonioxKey)

                    Text("When enabled, dictation is streamed live via cloud socket. If unavailable, app falls back to async cloud transcription.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            // Translation — always cloud
            Section("Translation") {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Cloud only (Soniox)")
                            .font(.body)
                        if !hasSonioxKey {
                            Text("A Soniox API key is required for translation.")
                                .font(.caption)
                                .foregroundColor(.red)
                        }
                    }
                } icon: {
                    Image(systemName: "cloud.fill")
                        .foregroundColor(.blue)
                }

                Toggle("Realtime translation via WebSocket", isOn: $translationRealtimeSocketEnabled)
                    .onChange(of: translationRealtimeSocketEnabled) { _, newValue in
                        SettingsStorage.shared.translationRealtimeSocketEnabled = newValue
                    }
                    .disabled(!hasSonioxKey)

                Text("When enabled, translation is streamed live via cloud socket. If unavailable, app falls back to async cloud translation.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // Favorite languages for quick translation
            Section("Favorite Languages") {
                ForEach(SupportedLanguage.allLanguages) { lang in
                    Toggle(lang.name, isOn: Binding(
                        get: { favoriteLanguageCodes.contains(lang.code) },
                        set: { isOn in
                            if isOn {
                                favoriteLanguageCodes.insert(lang.code)
                            } else {
                                favoriteLanguageCodes.remove(lang.code)
                            }
                            SettingsStorage.shared.favoriteLanguages = SupportedLanguage.allLanguages
                                .map(\.code)
                                .filter { favoriteLanguageCodes.contains($0) }
                        }
                    ))
                    .toggleStyle(.checkbox)
                }

                Text("Selected languages appear as quick-translate buttons in the Recordings detail view.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // Soniox cloud language restrictions
            Section("Cloud Language Restrictions") {
                ForEach(SupportedLanguage.allLanguages) { lang in
                    Toggle(lang.name, isOn: Binding(
                        get: { sonioxLanguageHintCodes.contains(lang.code) },
                        set: { isOn in
                            if isOn {
                                sonioxLanguageHintCodes.insert(lang.code)
                            } else {
                                sonioxLanguageHintCodes.remove(lang.code)
                            }

                            SettingsStorage.shared.sonioxLanguageHints = SupportedLanguage.allLanguages
                                .map(\.code)
                                .filter { sonioxLanguageHintCodes.contains($0) }

                            if sonioxLanguageHintCodes.isEmpty {
                                sonioxLanguageHintsStrict = false
                                SettingsStorage.shared.sonioxLanguageHintsStrict = false
                            }
                        }
                    ))
                    .toggleStyle(.checkbox)
                }

                Toggle("Strict mode (only selected languages)", isOn: $sonioxLanguageHintsStrict)
                    .onChange(of: sonioxLanguageHintsStrict) { _, newValue in
                        let strict = !sonioxLanguageHintCodes.isEmpty && newValue
                        sonioxLanguageHintsStrict = strict
                        SettingsStorage.shared.sonioxLanguageHintsStrict = strict
                    }
                    .disabled(sonioxLanguageHintCodes.isEmpty)

                if sonioxLanguageHintCodes.isEmpty {
                    Text("No language selected: Soniox auto-detects any language.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else if sonioxLanguageHintsStrict {
                    Text("Strict mode enabled: cloud recognition is limited to selected languages only.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    Text("Selected languages are hints; Soniox can still detect other languages.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            // Meeting Recording
            Section("Meeting Recording") {
                Picker("Provider", selection: $meetingCloudModeEnabled) {
                    Text("Cloud").tag(true)
                    Text("Local").tag(false)
                }
                .pickerStyle(.segmented)
                .onChange(of: meetingCloudModeEnabled) { _, newValue in
                    SettingsStorage.shared.meetingRealtimeTranscriptionEnabled = newValue
                }

                if meetingCloudModeEnabled {
                    if hasSonioxKey {
                        Text("Cloud mode streams transcription during recording. If realtime is unavailable, app falls back to cloud transcription after stop.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        Text("Cloud selected, but API key is missing. Recording will continue as audio-only.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                } else {
                    Text("Local mode records audio only. You can process it later from Recordings using local Whisper models.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            // Soniox API key — shown when any feature uses cloud
            if needsSoniox {
                sonioxSection
            }

            // Whisper models — shown when any feature uses local
            if needsWhisper {
                whisperSection
            }

            // Prompts section
            promptsSection
        }
        .formStyle(.grouped)
        .onAppear {
            sonioxAPIKey = KeychainManager.shared.getSonioxAPIKey() ?? ""
            keychainAccessible = KeychainManager.shared.isKeychainAccessible()
            sonioxLanguageHintCodes = Set(SettingsStorage.shared.sonioxLanguageHints)
            sonioxLanguageHintsStrict = SettingsStorage.shared.sonioxLanguageHintsStrict
            translationRealtimeSocketEnabled = SettingsStorage.shared.translationRealtimeSocketEnabled
            transcriptionRealtimeSocketEnabled = SettingsStorage.shared.transcriptionRealtimeSocketEnabled
            meetingCloudModeEnabled = SettingsStorage.shared.meetingRealtimeTranscriptionEnabled
        }
    }

    // MARK: - Soniox Section

    @ViewBuilder
    private var sonioxSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text("Soniox API Key")
                    .font(.headline)

                HStack(spacing: 6) {
                    Image(systemName: keychainAccessible ? "lock.shield.fill" : "exclamationmark.shield.fill")
                        .foregroundColor(keychainAccessible ? .green : .red)
                        .font(.caption)
                    Text(keychainAccessible
                        ? "Your API key is stored securely in the macOS Keychain"
                        : "Keychain access unavailable — key cannot be stored securely")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                if !hasSonioxKey {
                    Text("Enter your API key for full cloud features (transcription, translation, diarization).")
                        .font(.caption)
                        .foregroundColor(.red)
                }

                HStack {
                    Group {
                        if showSonioxKey {
                            TextField("Enter API key", text: $sonioxAPIKey)
                        } else {
                            SecureField("Enter API key", text: $sonioxAPIKey)
                        }
                    }
                    .textFieldStyle(.roundedBorder)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(!hasSonioxKey ? Color.red : Color.clear, lineWidth: 1)
                    )
                    .onChange(of: sonioxAPIKey) { _, newValue in
                        saveSonioxKey(newValue)
                    }

                    Button(showSonioxKey ? "Hide" : "Show") {
                        showSonioxKey.toggle()
                    }
                    .buttonStyle(.bordered)

                    Button("Test") {
                        testSonioxConnection()
                    }
                    .buttonStyle(.bordered)
                    .disabled(sonioxAPIKey.isEmpty || isTesting)
                }

                Link("Get your key at console.soniox.com",
                     destination: URL(string: "https://console.soniox.com")!)
                    .font(.caption)
                    .foregroundColor(.secondary)

                if let result = testResult {
                    testResultView(result)
                }
            }
        }
    }

    // MARK: - Whisper Section

    private var sortedModels: [WhisperModelManager.WhisperModel] {
        WhisperModelManager.availableModels.sorted {
            switch modelSort {
            case .speed: $0.speed > $1.speed
            case .accuracy: $0.accuracy > $1.accuracy
            }
        }
    }

    @ViewBuilder
    private var whisperSection: some View {
        Section("Whisper Models") {
            Picker("Sort by", selection: $modelSort) {
                ForEach(ModelSort.allCases, id: \.self) { sort in
                    Text(sort.label).tag(sort)
                }
            }
            .pickerStyle(.segmented)

            ForEach(sortedModels) { model in
                whisperModelRow(model)
                    .id(model.id)
            }
        }

        Section {
            VStack(alignment: .leading, spacing: 4) {
                Label("Translation is limited with local Whisper — it can only translate to English.", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Label("On Intel Macs, Whisper runs on CPU only — smaller models (Tiny, Base, Small) are recommended.", systemImage: "desktopcomputer")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    @ViewBuilder
    private func whisperModelRow(_ model: WhisperModelManager.WhisperModel) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // Top row: name, badges, actions
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(model.displayName)
                            .fontWeight(selectedModel == model.name ? .semibold : .regular)

                        if selectedModel == model.name {
                            Text("Active")
                                .font(.caption2)
                                .fontWeight(.medium)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.blue.opacity(0.15))
                                .foregroundColor(.blue)
                                .clipShape(Capsule())
                        } else if modelManager.isModelDownloaded(model) {
                            Text("Downloaded")
                                .font(.caption2)
                                .fontWeight(.medium)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.green.opacity(0.15))
                                .foregroundColor(.green)
                                .clipShape(Capsule())
                        }

                        if model.isEnglishOnly {
                            Text("EN")
                                .font(.caption2)
                                .fontWeight(.medium)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(.orange.opacity(0.15))
                                .foregroundColor(.orange)
                                .clipShape(Capsule())
                        }
                    }

                    Text(model.description)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                // Action buttons
                modelActions(model)
            }

            // Metrics row
            HStack(spacing: 16) {
                metricView(label: "Speed", value: model.speed)
                metricView(label: "Accuracy", value: model.accuracy)
                HStack(spacing: 3) {
                    Image(systemName: "memorychip")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text(model.ramUsage)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                HStack(spacing: 3) {
                    Image(systemName: "arrow.down.circle")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text(model.sizeDescription)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            // Download progress
            if modelManager.isDownloading[model.name] == true {
                HStack(spacing: 8) {
                    ProgressView(value: modelManager.downloadProgress[model.name] ?? 0)
                    Text("\(Int((modelManager.downloadProgress[model.name] ?? 0) * 100))%")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                    Button("Cancel") {
                        modelManager.cancelDownload(model)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func modelActions(_ model: WhisperModelManager.WhisperModel) -> some View {
        if modelManager.isDownloading[model.name] == true {
            EmptyView()
        } else if modelManager.isModelDownloaded(model) {
            HStack(spacing: 6) {
                if selectedModel != model.name {
                    Button("Select") {
                        selectedModel = model.name
                        SettingsStorage.shared.selectedWhisperModel = model.name
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }

                Button(role: .destructive) {
                    modelManager.deleteModel(model)
                    if selectedModel == model.name {
                        selectedModel = ""
                    }
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        } else {
            Button {
                modelManager.downloadModel(model)
            } label: {
                Label("Download", systemImage: "arrow.down.circle")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    @ViewBuilder
    private func metricView(label: String, value: Double) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary)
            HStack(spacing: 2) {
                ForEach(0 ..< 5, id: \.self) { i in
                    Circle()
                        .fill(dotColor(value: value, index: i))
                        .frame(width: 6, height: 6)
                }
            }
            Text(String(format: "%.1f", value * 10))
                .font(.caption2)
                .foregroundColor(.secondary)
                .monospacedDigit()
        }
    }

    private func dotColor(value: Double, index: Int) -> Color {
        let threshold = Double(index + 1) / 5.0
        guard value >= threshold else { return Color.gray.opacity(0.3) }
        if value >= 0.8 { return .green }
        if value >= 0.6 { return .yellow }
        if value >= 0.4 { return .orange }
        return .red
    }

    // MARK: - Prompts Section

    private static let whisperLanguages: [(code: String, name: String)] = [
        ("auto", "Auto-detect"),
        ("uk", "Ukrainian"),
        ("en", "English"),
        ("ro", "Romanian"),
        ("es", "Spanish"),
        ("de", "German"),
        ("fr", "French"),
        ("pl", "Polish"),
        ("it", "Italian"),
        ("pt", "Portuguese"),
        ("ja", "Japanese"),
        ("zh", "Chinese"),
        ("ko", "Korean"),
        ("ru", "Russian"),
    ]

    @ViewBuilder
    private var promptsSection: some View {
        if needsSoniox {
            Section("Soniox Prompt") {
                VStack(alignment: .leading, spacing: 6) {
                    TextEditor(text: $sonioxPrompt)
                        .font(.system(.caption, design: .monospaced))
                        .frame(minHeight: 80, maxHeight: 160)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(.quaternary, lineWidth: 1)
                        )
                        .onChange(of: sonioxPrompt) { _, newValue in
                            SettingsStorage.shared.sonioxPrompt = newValue
                        }

                    Text("Context prompt sent with every Soniox transcription in Voice Note mode. Leave empty to use the built-in default.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    if !sonioxPrompt.isEmpty {
                        Button("Reset to default") {
                            sonioxPrompt = ""
                            SettingsStorage.shared.sonioxPrompt = ""
                        }
                        .font(.caption)
                    }
                }
            }
        }

        if needsWhisper {
            Section("Whisper Language & Prompt") {
                Picker("Language", selection: $whisperLanguage) {
                    ForEach(Self.whisperLanguages, id: \.code) { lang in
                        Text(lang.name).tag(lang.code)
                    }
                }
                .onChange(of: whisperLanguage) { _, newValue in
                    SettingsStorage.shared.whisperLanguage = newValue
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Initial prompt:")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    TextEditor(text: $whisperPrompt)
                        .font(.system(.caption, design: .monospaced))
                        .frame(minHeight: 60, maxHeight: 120)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(.quaternary, lineWidth: 1)
                        )
                        .onChange(of: whisperPrompt) { _, newValue in
                            SettingsStorage.shared.whisperPrompt = newValue
                        }

                    Text("Guides the Whisper decoder. Write a sentence in your target language to improve recognition. Example for Ukrainian: \"Привіт, це транскрипція українською мовою.\"")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    // MARK: - Soniox Helpers

    @ViewBuilder
    private func testResultView(_ result: TestResult) -> some View {
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

    private func saveSonioxKey(_ key: String) {
        if key.isEmpty {
            try? KeychainManager.shared.deleteSonioxAPIKey()
        } else {
            try? KeychainManager.shared.setSonioxAPIKey(key)
        }
    }

    private func testSonioxConnection() {
        isTesting = true
        testResult = nil

        Task {
            let service = SonioxTranscriptionService()
            service.apiKey = sonioxAPIKey

            do {
                let success = try await service.testConnection()
                await MainActor.run {
                    testResult = success ? .success : .failure("Connection failed")
                    isTesting = false
                }
            } catch {
                await MainActor.run {
                    testResult = .failure(error.localizedDescription)
                    isTesting = false
                }
            }
        }
    }
}

#Preview {
    TranscriptionSettingsView()
        .frame(width: 600, height: 650)
}
