import SwiftUI

struct TranslationSettingsView: View {
    @State private var translationProvider: TranscriptionProvider = SettingsStorage.shared.translationProvider
    @State private var favoriteLanguageCodes: Set<String> = Set(SettingsStorage.shared.favoriteLanguages)
    @State private var translationLanguageA: String = SettingsStorage.shared.translationLanguageA
    @State private var translationLanguageB: String = SettingsStorage.shared.translationLanguageB

    private var translationPairLabel: String {
        "\(translationLanguageA.uppercased()) <-> \(translationLanguageB.uppercased())"
    }

    var body: some View {
        Form {
            Section("Translation Provider") {
                Picker("Provider", selection: $translationProvider) {
                    ForEach(TranscriptionProvider.allCases) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: translationProvider) { _, newValue in
                    SettingsStorage.shared.translationProvider = newValue
                }
            }

            if translationProvider == .cloud {
                cloudTranslationSection
            } else {
                localTranslationSection
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Cloud Translation

    @ViewBuilder
    private var cloudTranslationSection: some View {
        Section("Default Translation Pair") {
            Picker("Language A", selection: $translationLanguageA) {
                ForEach(SupportedLanguage.cloudLanguages.filter { $0.code != translationLanguageB }) { lang in
                    Text(lang.name).tag(lang.code)
                }
            }
            .onChange(of: translationLanguageA) { _, newValue in
                SettingsStorage.shared.translationLanguageA = newValue
            }

            Picker("Language B", selection: $translationLanguageB) {
                ForEach(SupportedLanguage.cloudLanguages.filter { $0.code != translationLanguageA }) { lang in
                    Text(lang.name).tag(lang.code)
                }
            }
            .onChange(of: translationLanguageB) { _, newValue in
                SettingsStorage.shared.translationLanguageB = newValue
            }

            Text("Translation pair: \(translationPairLabel)")
                .font(.caption)
                .foregroundColor(.secondary)
        }

        Section("Favorite Languages") {
            ForEach(SupportedLanguage.cloudLanguages) { lang in
                Toggle(lang.name, isOn: Binding(
                    get: { favoriteLanguageCodes.contains(lang.code) },
                    set: { isOn in
                        if isOn {
                            favoriteLanguageCodes.insert(lang.code)
                        } else {
                            favoriteLanguageCodes.remove(lang.code)
                        }
                        SettingsStorage.shared.favoriteLanguages = SupportedLanguage.cloudLanguages
                            .map(\.code)
                            .filter { favoriteLanguageCodes.contains($0) }
                    }
                ))
                .toggleStyle(.checkbox)
            }

            Text("Selected languages are used as language hints for cloud transcription. Supports 60 languages.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .onAppear {
            translationProvider = SettingsStorage.shared.translationProvider
        }
    }

    // MARK: - Local (Whisper) Translation

    private var localTranslationSection: some View {
        Section("Local Whisper Translation") {
            Label("Whisper translates any language to English only.", systemImage: "info.circle")
                .font(.callout)
                .foregroundColor(.secondary)

            whisperModelStatus
        }
    }

    @ViewBuilder
    private var whisperModelStatus: some View {
        let selectedModel = WhisperModelManager.shared.selectedModel()

        if let model = selectedModel {
            if model.isEnglishOnly {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Model \"\(model.displayName)\" is English-only")
                            .fontWeight(.medium)
                        Text("English-only models cannot translate. Select a multilingual model in Offline Models.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                }
            } else {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Model \"\(model.displayName)\" supports translation")
                            .fontWeight(.medium)
                        Text("Speech in any language will be translated to English.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                } icon: {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                }
            }
        } else {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("No model selected")
                        .fontWeight(.medium)
                    Text("Download and select a multilingual model in the Offline Models tab.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
            }
        }
    }
}

#Preview {
    TranslationSettingsView()
        .frame(width: 500, height: 500)
}
