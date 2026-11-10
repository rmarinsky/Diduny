import Foundation

/// Copy and visibility rules for Settings > Audio (changes/05 §2.4). Pure, so it is unit-tested.
enum AudioSettingsText {
    /// "Identify speakers" caption: the lead, then the speaker model state as the last sentence.
    static func identifySpeakersCaption(state: SpeakerModelManager.State, downloadMegabytes: Int) -> String {
        let lead = String(localized: "After Stop, Diduny tells the voices apart on this Mac when the engine cannot.")
        return "\(lead) \(modelSentence(state: state, downloadMegabytes: downloadMegabytes))"
    }

    static func modelSentence(state: SpeakerModelManager.State, downloadMegabytes: Int) -> String {
        switch state {
        case .ready:
            String(localized: "Ready to use.")
        case .notDownloaded:
            String(localized: "Needs a one-time download of about \(downloadMegabytes) MB, started after your first meeting.")
        case .downloading:
            String(localized: "Downloading speaker model…")
        case .failed:
            String(localized: "Couldn't download the speaker model. Meetings will use Me / Others. Try again later.")
        }
    }

    /// "Retry" sits in the control slot next to the switch only after a failed download.
    static func showsRetry(_ state: SpeakerModelManager.State) -> Bool {
        state == .failed
    }

    static func gainPercent(_ gain: Float) -> String {
        "\(Int((gain * 100).rounded()))%"
    }

    /// Today's rule (MeetingSettings): the microphone gain only matters when the microphone is recorded.
    static func showsMicrophoneLevel(_ source: MeetingAudioSource) -> Bool {
        source == .systemPlusMicrophone
    }

    static func levelFraction(_ level: Float) -> Double {
        Double(min(max(level, 0), 1))
    }
}
