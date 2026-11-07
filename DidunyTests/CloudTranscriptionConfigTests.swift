@testable import Diduny
import Foundation
import Testing

/// T5-LA-23 (WP-53): an empty "Languages you speak" sends no language hint and is not strict.
@MainActor
struct CloudTranscriptionConfigTests {
    @Test("T5-LA-23: no languages → no hints, strict off")
    func emptyLanguagesSendNoHint() throws {
        let suite = "CloudTranscriptionConfigTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let storage = SettingsStorage(defaults: defaults)
        storage.manualSpeechLanguageHints = [] // "Languages you speak" changed to none
        let hints = storage.effectiveSpeechLanguageHints(detectedCodes: [])
        #expect(hints.isEmpty)

        let config = RecordingQueueService.buildCloudTranscriptionConfig(hints: hints, enableSpeakerDiarization: false)
        #expect(config["language_hints"] == nil)
        #expect((config["language_hints_strict"] as? Bool ?? false) == false)
    }

    @Test("Languages set → hints sent strictly")
    func languagesSendStrictHints() {
        let config = RecordingQueueService.buildCloudTranscriptionConfig(hints: ["en", "uk"], enableSpeakerDiarization: true)
        #expect(config["language_hints"] as? [String] == ["en", "uk"])
        #expect(config["language_hints_strict"] as? Bool == true)
        #expect(config["enable_speaker_diarization"] as? Bool == true)
    }
}
