import Foundation

/// What the meeting and Translate meeting panels read from the store (WP-31, WP-32), with the
/// session defaults from Settings > Modes (WP-13, ADR-0012 D4).
extension LiveDictationOverlayStore {
    /// Called by `reset(mode:)`: "Starts in", the per-segment engines, the Translate meeting engine,
    /// pair and "Show original text".
    func applyMeetingDefaults() {
        let modeDefaults = settings.modeDefaults
        meetingSegment = modeDefaults.meetingStartsIn
        meetingEngines = Dictionary(uniqueKeysWithValues: MeetingSegment.allCases.map { ($0, modeDefaults.engine(for: $0)) })
        meetingTranslationEngine = modeDefaults.engine(for: .meetingTranslation)
        meetingTranslationPair = settings.translationPair ?? settings.defaultTranslationLanguagePair
        meetingTranslation.reset(pair: meetingTranslationPair)
        meetingTranslationShowsOriginal = settings.meetingTranslationShowOriginal
    }

    var meetingPanelState: MeetingPanelState {
        MeetingPanelState(
            segment: meetingSegment,
            engines: meetingEngines,
            switchingLocked: meetingSwitchingLocked,
            readiness: ModesInterimReadiness(),
            isOnBattery: powerSource.isOnBattery,
            connection: connectionStatus
        )
    }

    var meetingLines: [MeetingTranscriptLines.Line] {
        var turns = meetingTranscript.segments.map { MeetingTranscriptLines.Turn(speaker: $0.speaker, text: $0.text) }
        let provisional = meetingTranscript.provisionalText
        if !provisional.trimmingCharacters(in: .whitespaces).isEmpty {
            turns.append(.init(speaker: meetingTranscript.provisionalSpeaker, text: provisional))
        }
        return MeetingTranscriptLines.make(turns: turns, speakerLabels: meetingTranscript.speakerLabels)
    }

    var translateMeetingPanelModel: TranslateMeetingPanelModel? {
        let readiness = ModesInterimReadiness()
        let options = EngineID.allCases.filter { !meetingSwitchingLocked || $0 == meetingTranslationEngine }.compactMap { id -> TranslateMeetingEngineOption? in
            MeetingPanelState.registryCapabilities(id).map {
                TranslateMeetingEngineOption(caps: $0, name: MeetingPanelState.name(id), readiness: readiness.readiness(of: id))
            }
        }
        guard let engine = options.first(where: { $0.caps.id == meetingTranslationEngine }) ?? options.first else { return nil }
        return TranslateMeetingPanelModel(
            pair: meetingTranslationPair,
            offeredPairs: settings.offeredTranslationPairs,
            engine: engine,
            engines: options
        )
    }

    /// "Turn on live transcript" in the Record only calm box (WP-30); nil in other segments.
    var meetingTurnOnLiveTranscript: (() -> Void)? {
        meetingSegment == .recordOnly ? onTurnOnLiveTranscript : nil
    }

    /// What the running meeting session uses (set by AppDelegate after Start).
    func showRunningMeeting(segment: MeetingSegment, engine: EngineID) {
        meetingSegment = segment
        meetingEngines[segment] = engine
    }

    /// The engine the running Translate meeting session uses.
    func showRunningMeetingTranslation(engine: EngineID) {
        meetingTranslationEngine = engine
    }

    /// A pair picked in the panel holds for this meeting only (decision 14 DEFAULT).
    func pickMeetingTranslationPair(_ pair: TranslationLanguagePair) {
        meetingTranslationPair = pair
    }
}

/// The segment and engine a started meeting really runs (WP-31): the live panel shows these,
/// not the Settings > Modes defaults.
enum RunningMeetingSession {
    static func segment(recordOnly: Bool, cloudMode: Bool, localPreview: Bool) -> MeetingSegment {
        if recordOnly { return .recordOnly }
        if cloudMode { return .cloud }
        return localPreview ? .thisMac : .recordOnly
    }

    /// `ownLiveEngine`: ElevenLabs or Apple streaming live; `afterStopEngine`: the on-device pick for after Stop.
    static func engine(segment: MeetingSegment, ownLiveEngine: EngineID?, afterStopEngine: String?) -> EngineID {
        switch segment {
        case .cloud: ownLiveEngine ?? .didunyCloud
        case .thisMac: .whisper
        case .recordOnly: afterStopEngine.flatMap(EngineID.init(rawValue:)) ?? .whisper
        }
    }
}
