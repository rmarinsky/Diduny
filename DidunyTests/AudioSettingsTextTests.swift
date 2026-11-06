@testable import Diduny
import Foundation
import Testing

/// Settings > Audio copy and visibility rules (05 §2.4, test-plan T5-AU-04, T5-AU-08).
struct AudioSettingsTextTests {
    private static let lead = "After Stop, Diduny tells the voices apart on this Mac when the engine cannot."

    @Test("Speaker model state is the last sentence of the caption (T5-AU-08)", arguments: [
        (SpeakerModelManager.State.ready, "Ready to use."),
        (.notDownloaded, "Needs a one-time download of about 22 MB, started after your first meeting."),
        (.downloading, "Downloading speaker model…"),
        (.failed, "Couldn't download the speaker model. Meetings will use Me / Others. Try again later."),
    ])
    func speakerCaption(state: SpeakerModelManager.State, sentence: String) {
        let caption = AudioSettingsText.identifySpeakersCaption(state: state, downloadMegabytes: 22)
        #expect(caption == "\(Self.lead) \(sentence)")
    }

    @Test("Only a failed download offers Retry", arguments: [
        (SpeakerModelManager.State.ready, false),
        (.notDownloaded, false),
        (.downloading, false),
        (.failed, true),
    ])
    func retry(state: SpeakerModelManager.State, shows: Bool) {
        #expect(AudioSettingsText.showsRetry(state) == shows)
    }

    @Test("Gain shows as a whole percent (T5-AU-04)", arguments: [
        (Float(1.0), "100%"), (0.3, "30%"), (1.5, "150%"), (0, "0%"), (2, "200%"), (0.55, "55%"),
    ])
    func gainPercent(gain: Float, text: String) {
        #expect(AudioSettingsText.gainPercent(gain) == text)
    }

    @Test("Microphone level shows only with System + microphone (05 §2.4 proposal)")
    func microphoneLevelVisibility() {
        #expect(AudioSettingsText.showsMicrophoneLevel(.systemPlusMicrophone))
        #expect(!AudioSettingsText.showsMicrophoneLevel(.systemOnly))
    }

    @Test("Level bar fill is clamped to 0...1")
    func levelFraction() {
        #expect(AudioSettingsText.levelFraction(-0.2) == 0)
        #expect(AudioSettingsText.levelFraction(0.4) == 0.4)
        #expect(AudioSettingsText.levelFraction(1.7) == 1)
    }
}
