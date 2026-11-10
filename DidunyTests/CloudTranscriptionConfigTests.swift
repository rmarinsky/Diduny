@testable import Diduny
import Foundation
import Testing

/// T5-LA-23 (WP-53): an empty "Languages you speak" sends no language hint and is not strict.
@MainActor
struct CloudTranscriptionConfigTests {
    @Test("T5-LA-23: no languages → no hints, strict off")
    func emptyLanguagesSendNoHint() throws {
        let hints: [String] = []
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
