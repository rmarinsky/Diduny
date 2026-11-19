import SwiftUI

/// Settings > Local models (design-spec 7.10, changes/04): one table for Parakeet V3, Apple Speech and
/// the 12 Whisper models, then the Whisper options.
struct OfflineModelsSettingsView: View {
    @State private var model = LocalModelsModel(
        whisper: WhisperModelManagerStore(),
        parakeet: ParakeetModelController.shared,
        isAppleSpeechAvailable: AppleBenchmarkEngine().availability() == .ready,
        yourLanguages: SettingsStorage.shared.yourLanguages
    )

    var body: some View {
        PageScaffold(title: "Local models", subtitle: "Run on this Mac. Audio never leaves it.",
                     columnMaxWidth: DS.Layout.wideColumnMaxWidth) {
            VStack(alignment: .leading, spacing: 18) {
                ModelTable(model: model)
                WhisperOptionsSection()
                compareAndTest
            }
        }
        .onAppear { ParakeetModelController.shared.refresh() }
        // Escape and leaving the page count as Keep (design-spec 4.12).
        .onExitCommand { model.keep() }
        .onDisappear { model.keep() }
    }

    /// Opens the Compare engines and Benchmark sub-pages; each has a "‹ Engines" button back.
    private var compareAndTest: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Compare and test")
                .font(DS.Font.groupHeading)
                .foregroundStyle(DS.Palette.text)
                .accessibilityAddTraits(.isHeader)
            SettingsLineRow(title: "What each engine does, task by task", kind: .button) {
                Button("Compare engines…") { MainWindowController.shared.showWindow(section: .providers) }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("models.compare")
            }
            SettingsLineRow(title: "Test engines on your own recordings", kind: .button, showsHairline: false) {
                Button("Benchmark…") { MainWindowController.shared.showWindow(section: .benchmark) }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("models.benchmark")
            }
        }
    }
}

#Preview {
    OfflineModelsSettingsView()
        .frame(width: 762, height: 680)
}
