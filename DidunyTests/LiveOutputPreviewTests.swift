@testable import Diduny
import Testing

/// Output changed during a recording: past the preview limit the panel must not freeze on an old translation.
@MainActor
struct LiveOutputPreviewTests {
    private let english = DictationOutput.translation(targetLanguage: "en")

    private func store(spoken: String) -> LiveDictationOverlayStore {
        let store = LiveDictationOverlayStore()
        store.reset(mode: .voice)
        store.phase = .recording
        store.configureOutput(native: .original, options: [english], listensForVoiceCommands: false)
        store.pickOutput(english)
        store.finalText = spoken
        store.convertedPreview = (output: english, source: "earlier", text: "PREVIEW")
        return store
    }

    @Test("Within the limit the preview shows")
    func withinLimit() {
        #expect(store(spoken: "short").visibleText == "PREVIEW")
    }

    @Test("Past the limit the spoken words keep updating")
    func pastLimit() {
        let spoken = String(repeating: "a", count: LiveDictationOverlayStore.maxPreviewSourceBytes + 1)
        let store = store(spoken: spoken)

        #expect(store.visibleText == spoken)
        #expect(!store.isShowingConvertedPreview)
    }
}
