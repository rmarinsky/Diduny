import Foundation

/// What this Mac has, read once when the chooser draws. Tests pass their own.
struct TranscribeFacts: Equatable {
    var appleSilicon: Bool
    /// Local voice detection: Apple silicon and macOS 15 or later (`LocalSpeakerDiarizer.isSupported`).
    var speakerModelSupported: Bool
    var speakerModelReady: Bool
    var downloaded: Set<TranscribeChoice.MacModel>
    var appleSpeechReady: Bool
    var elevenLabsKey: Bool
}

/// The "Make a transcript" choice in the recording inspector: where, which model or service, speaker labels.
struct TranscribeChoice: Equatable {
    enum Place: Hashable { case mac, cloud }

    enum MacModel: String, CaseIterable, Hashable {
        case parakeet
        case whisperTurbo
        case whisperLarge
        case apple

        /// Whisper with the speaker model is the only local path to speaker labels (FluidAudio diarizer).
        var canLabelSpeakers: Bool { self == .whisperTurbo || self == .whisperLarge }

        var whisperModelName: String? {
            switch self {
            case .whisperTurbo: "ggml-large-v3-turbo"
            case .whisperLarge: "ggml-large-v3"
            case .parakeet, .apple: nil
            }
        }

        var engine: EngineID {
            switch self {
            case .parakeet: .parakeet
            case .whisperTurbo, .whisperLarge: .whisper
            case .apple: .appleSpeech
            }
        }
    }

    enum CloudService: String, CaseIterable, Hashable {
        case diduny
        case elevenLabs

        var engine: EngineID { self == .diduny ? .didunyCloud : .elevenLabs }
    }

    /// A line under the switch after the choice changed something by itself.
    enum Note: Equatable {
        case modelChangedForLabels
        case labelsOffForModel
    }

    /// What stands between the choice and a run.
    enum Blocker: Equatable {
        /// Needs Apple silicon (Parakeet) or is otherwise not on this Mac.
        case notOnThisMac
        case download(MacModel)
    }

    struct Run: Equatable {
        let action: RecordingQueueService.QueueAction
        let engine: EngineID
        let whisperModel: String?
        /// Per-run local labels; nil for cloud runs (the service labels by itself).
        let speakerLabels: Bool?
    }

    var place: Place
    var mac: MacModel
    var cloud: CloudService
    var labels: Bool
    private(set) var note: Note?

    /// Labels on for meetings and files when Whisper Turbo is already here; off when it is missing, so nothing blocks.
    static func defaults(offersLabels: Bool, facts: TranscribeFacts) -> TranscribeChoice {
        let labels = offersLabels && facts.downloaded.contains(.whisperTurbo)
        // Parakeet is the fast default on Apple silicon; Intel has only Whisper (and Apple Speech).
        let mac: MacModel = labels || !facts.appleSilicon ? .whisperTurbo : .parakeet
        return TranscribeChoice(place: .mac, mac: mac, cloud: .diduny, labels: labels, note: nil)
    }

    mutating func setLabels(_ on: Bool) {
        labels = on
        note = nil
        if on, place == .mac, !mac.canLabelSpeakers {
            mac = .whisperTurbo
            note = .modelChangedForLabels
        }
    }

    mutating func pick(_ model: MacModel) {
        mac = model
        place = .mac
        note = nil
        if labels, !model.canLabelSpeakers {
            labels = false
            note = .labelsOffForModel
        }
    }

    mutating func pick(_ service: CloudService) {
        cloud = service
        place = .cloud
        note = nil
    }

    mutating func choose(_ place: Place) {
        self.place = place
        note = nil
        if place == .mac, labels, !mac.canLabelSpeakers {
            mac = .whisperTurbo
            note = .modelChangedForLabels
        }
    }

    func blocker(_ facts: TranscribeFacts) -> Blocker? {
        guard place == .mac else { return nil }
        switch mac {
        case .parakeet:
            guard facts.appleSilicon else { return .notOnThisMac }
            return facts.downloaded.contains(.parakeet) ? nil : .download(.parakeet)
        case .apple:
            return facts.appleSpeechReady ? nil : .notOnThisMac
        case .whisperTurbo, .whisperLarge:
            return facts.downloaded.contains(mac) ? nil : .download(mac)
        }
    }

    /// Labels on this Mac without the speaker model give only "Me" and "Others" (two-channel meetings).
    func meAndOthersOnly(_ facts: TranscribeFacts) -> Bool {
        place == .mac && labels && (!facts.speakerModelSupported || !facts.speakerModelReady)
    }

    func run(offersLabels: Bool) -> Run {
        let wantsLabels = offersLabels && labels
        switch place {
        case .mac:
            return Run(action: .transcribe, engine: mac.engine, whisperModel: mac.whisperModelName,
                       speakerLabels: offersLabels ? wantsLabels && mac.canLabelSpeakers : nil)
        case .cloud:
            return Run(action: wantsLabels ? .transcribeDiarize : .transcribe, engine: cloud.engine,
                       whisperModel: nil, speakerLabels: nil)
        }
    }
}
