import SwiftUI

struct TranslationSettingsView: View {
    @State private var favoriteLanguageCodes: Set<String> = Set(SettingsStorage.shared.favoriteLanguages)
    @State private var translationRealtimeSocketEnabled: Bool = SettingsStorage.shared.translationRealtimeSocketEnabled

    var body: some View {
        Form {
            Section("Realtime Translation") {
                Toggle("Realtime translation via WebSocket", isOn: $translationRealtimeSocketEnabled)
                    .onChange(of: translationRealtimeSocketEnabled) { _, newValue in
                        SettingsStorage.shared.translationRealtimeSocketEnabled = newValue
                    }

                Text("When enabled, translation is streamed live via cloud socket. Socket mode can improve paragraph detection from pauses/endpoints. If unavailable, app falls back to async cloud translation.")
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

                Text("Selected languages are used as quick-translate buttons and as language hints for cloud transcription. Supports 60 languages via Soniox.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            translationRealtimeSocketEnabled = SettingsStorage.shared.translationRealtimeSocketEnabled
        }
    }
}

#Preview {
    TranslationSettingsView()
        .frame(width: 500, height: 500)
}
