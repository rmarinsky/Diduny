import SwiftUI

struct TranscriptionSettingsView: View {
    @State private var transcriptionProvider: TranscriptionProvider = SettingsStorage.shared.transcriptionProvider
    @State private var translationProvider: TranscriptionProvider = SettingsStorage.shared.translationProvider
    @State private var selectedModel: String = SettingsStorage.shared.selectedWhisperModel
    @State private var modelSort: ModelSort = .speed

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

    private let modelManager = WhisperModelManager.shared

    enum TestResult {
        case success
        case failure(String)
    }

    private var needsSoniox: Bool {
        transcriptionProvider == .soniox || translationProvider == .soniox
    }

    private var needsWhisper: Bool {
        transcriptionProvider == .whisperLocal || translationProvider == .whisperLocal
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
            }

            // Translation provider
            Section("Translation") {
                Picker("Provider", selection: $translationProvider) {
                    ForEach(TranscriptionProvider.allCases) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: translationProvider) { _, newValue in
                    SettingsStorage.shared.translationProvider = newValue
                }

                if translationProvider == .whisperLocal {
                    Label("Local Whisper can only translate to English.", systemImage: "info.circle")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            // Meeting — cloud only
            Section("Meeting Recording") {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Cloud only (Soniox)")
                            .font(.body)
                        Text("Real-time streaming requires a cloud connection.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                } icon: {
                    Image(systemName: "cloud.fill")
                        .foregroundColor(.blue)
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
        }
        .formStyle(.grouped)
        .onAppear {
            sonioxAPIKey = KeychainManager.shared.getSonioxAPIKey() ?? ""
        }
    }

    // MARK: - Soniox Section

    @ViewBuilder
    private var sonioxSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text("Soniox API Key")
                    .font(.headline)

                HStack {
                    Group {
                        if showSonioxKey {
                            TextField("Enter API key", text: $sonioxAPIKey)
                        } else {
                            SecureField("Enter API key", text: $sonioxAPIKey)
                        }
                    }
                    .textFieldStyle(.roundedBorder)
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
