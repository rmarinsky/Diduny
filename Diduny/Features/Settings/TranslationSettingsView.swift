import SwiftUI

struct TranslationSettingsView: View {
    @State private var favoriteLanguageCodes: Set<String> = Set(SettingsStorage.shared.favoriteLanguages)
    @State private var translationLanguageA: String = SettingsStorage.shared.translationLanguageA
    @State private var translationLanguageB: String = SettingsStorage.shared.translationLanguageB

    private var translationPairLabel: String {
        "\(translationLanguageA.uppercased()) <-> \(translationLanguageB.uppercased())"
    }

    var body: some View {
        Form {
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
        }
        .formStyle(.grouped)
    }
}

#Preview {
    TranslationSettingsView()
        .frame(width: 500, height: 500)
}
