import SwiftUI

struct OfflineModelsSettingsView: View {
    @State private var selectedModel: String = SettingsStorage.shared.selectedWhisperModel
    @State private var modelSort: ModelSort = .speed
    @State private var whisperLanguage: String = SettingsStorage.shared.whisperLanguage
    @State private var whisperPrompt: String = SettingsStorage.shared.whisperPrompt

    enum ModelSort: String, CaseIterable {
        case speed, accuracy

        var label: String {
            switch self {
            case .speed: "Speed"
            case .accuracy: "Accuracy"
            }
        }
    }

    private let modelManager = WhisperModelManager.shared

    var body: some View {
        Form {
            whisperModelsSection
            whisperLanguageSection
        }
        .formStyle(.grouped)
    }

    // MARK: - Whisper Models

    private var sortedModels: [WhisperModelManager.WhisperModel] {
        WhisperModelManager.availableModels.sorted {
            switch modelSort {
            case .speed: $0.speed > $1.speed
            case .accuracy: $0.accuracy > $1.accuracy
            }
        }
    }

    @ViewBuilder
    private var whisperModelsSection: some View {
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
                Label("Models with the \"Translate\" badge can translate speech from any language to English.", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Label("On Intel Macs, Whisper runs on CPU only \u{2014} smaller models (Tiny, Base, Small) are recommended.", systemImage: "desktopcomputer")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    @ViewBuilder
    private func whisperModelRow(_ model: WhisperModelManager.WhisperModel) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(model.displayName)
                            .fontWeight(selectedModel == model.name ? .semibold : .regular)

                        if selectedModel == model.name {
                            ModelBadge("Active", color: .blue)
                        } else if modelManager.isModelDownloaded(model) {
                            ModelBadge("Downloaded", color: .green)
                        }

                        if model.isEnglishOnly {
                            ModelBadge("EN", color: .orange)
                        } else {
                            ModelBadge("Translate", color: .purple)
                        }
                    }

                    Text(model.description)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                modelActions(model)
            }

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
                        SettingsStorage.shared.selectedWhisperModel = ""
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

    // MARK: - Whisper Language & Prompt

    @ViewBuilder
    private var whisperLanguageSection: some View {
        Section("Whisper Language & Prompt") {
            Picker("Language", selection: $whisperLanguage) {
                ForEach(SupportedLanguage.whisperLanguages) { lang in
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

                Text("Guides the Whisper decoder. Write a sentence in your target language to improve recognition. Example for Ukrainian: \"\u{041F}\u{0440}\u{0438}\u{0432}\u{0456}\u{0442}, \u{0446}\u{0435} \u{0442}\u{0440}\u{0430}\u{043D}\u{0441}\u{043A}\u{0440}\u{0438}\u{043F}\u{0446}\u{0456}\u{044F} \u{0443}\u{043A}\u{0440}\u{0430}\u{0457}\u{043D}\u{0441}\u{044C}\u{043A}\u{043E}\u{044E} \u{043C}\u{043E}\u{0432}\u{043E}\u{044E}.\"")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
}

// MARK: - Model Badge

private struct ModelBadge: View {
    let text: String
    let color: Color

    init(_ text: String, color: Color) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text)
            .font(.caption2)
            .fontWeight(.medium)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15))
            .foregroundColor(color)
            .clipShape(Capsule())
    }
}

#Preview {
    OfflineModelsSettingsView()
        .frame(width: 500, height: 650)
}
