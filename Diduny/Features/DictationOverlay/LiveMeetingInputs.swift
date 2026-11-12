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
            isConnecting: meetingSwitch.isConnecting,
            runningIsLive: meetingSwitch.runningIsLive,
            readiness: LiveEngineReadinessSource(),
            isOnBattery: powerSource.isOnBattery,
            connection: connectionStatus,
            segmentsEnabled: meetingSwitchHandler != nil
        )
    }

    var meetingLines: [MeetingTranscriptLines.Line] {
        var turns = meetingTranscript.segments.map { MeetingTranscriptLines.Turn(speaker: $0.speaker, text: $0.text) }
        let provisional = meetingTranscript.provisionalText
        if !provisional.trimmingCharacters(in: .whitespaces).isEmpty {
            turns.append(.init(speaker: meetingTranscript.provisionalSpeaker, text: provisional))
        }
        return MeetingTranscriptLines.make(turns: turns, speakerLabels: meetingTranscript.speakerLabels,
                                           markers: meetingSwitch.markers, translateMeeting: false)
    }

    var translateMeetingPanelModel: TranslateMeetingPanelModel? {
        let readiness = LiveEngineReadinessSource()
        // Meeting translation runs in the cloud only: engines on this Mac cannot translate a meeting.
        let options = EngineID.allCases.compactMap { id -> TranslateMeetingEngineOption? in
            MeetingPanelState.registryCapabilities(id).flatMap { $0.traits.runsOn == .cloud ? $0 : nil }.map {
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

    /// What the running meeting session uses (set by AppDelegate after Start).
    func showRunningMeeting(segment: MeetingSegment, engine: EngineID) {
        meetingSegment = segment
        meetingEngines[segment] = engine
    }

    /// The engine the running Translate meeting session uses.
    func showRunningMeetingTranslation(engine: EngineID) {
        meetingTranslationEngine = engine
    }

    /// A pair picked in the panel holds for this meeting only (decision 14 DEFAULT). In a live meeting it
    /// restarts the session; a failure puts the old pair back (`applyMeetingSwitch`).
    func pickMeetingTranslationPair(_ pair: TranslationLanguagePair) {
        if meetingSwitchHandler?.changePair(pair) == false { return }
        meetingTranslationPair = pair
    }

    /// A click on a segment: its engine goes live, or Record only starts now. Text and audio are the handler's job.
    func pickMeetingSegment(_ segment: MeetingSegment) {
        let engine = meetingEngines[segment] ?? MeetingPanelState.defaultEngines[segment] ?? .didunyCloud
        guard let handler = meetingSwitchHandler else {
            meetingSegment = segment
            return
        }
        handler.click(segment == .recordOnly ? .afterStopOnly(engine) : .live(engine))
    }

    /// A pick in the Engine menu of the current segment.
    func pickMeetingEngine(_ engine: EngineID) {
        guard let handler = meetingSwitchHandler else {
            meetingEngines[meetingSegment] = engine
            return
        }
        meetingEngines[meetingSegment] = engine
        handler.click(meetingSegment == .recordOnly ? .afterStopOnly(engine) : .live(engine))
    }

    /// Translate meeting: only Diduny Cloud translates live, everything else waits for Stop.
    func pickMeetingTranslationEngine(_ engine: EngineID) {
        guard let handler = meetingSwitchHandler else {
            meetingTranslationEngine = engine
            return
        }
        handler.click(engine == .didunyCloud ? .live(engine) : .afterStopOnly(engine))
    }

    /// The line under the engine: a failed switch, or why the meeting moved.
    var meetingSwitchLine: MeetingSwitchText.Line? {
        MeetingSwitchText.line(
            meetingSwitch, translateMeeting: mode == .meetingTranslation,
            canUseAppleSpeech: LiveEngineReadinessSource().readiness(of: .appleSpeech) == .ready,
            canUseElevenLabs: LiveEngineReadinessSource().readiness(of: .elevenLabs) == .ready
        )
    }

    /// The link on that line: try the last pick again, or the engine the line names.
    func runMeetingFailureAction() {
        guard let handler = meetingSwitchHandler else { return }
        switch meetingSwitch.failure {
        case .noModel: handler.click(.live(.appleSpeech))
        case .noQuota: handler.click(.live(.elevenLabs))
        case .some: if let target = meetingSwitch.failedTarget { handler.click(target) }
        case nil: if meetingSwitch.note == .offline { handler.click(.live(.whisper)) }
        }
    }

    /// Turns the panel can place a marker after: the mode's own transcript.
    var meetingTurnCount: Int {
        mode == .meetingTranslation ? meetingTranslation.turns.count : meetingTranscript.segments.count
    }

    /// Mirrors the machine: the highlight, the engine shown, the lines. Nothing here touches audio.
    func applyMeetingSwitch(_ machine: MeetingSwitchMachine) {
        let selected = machine.selected
        if mode == .meetingTranslation {
            meetingTranslationEngine = selected.engine
        } else {
            meetingSegment = selected.segment
            meetingEngines[selected.segment] = selected.engine
            if !machine.isConnecting { meetingEngines[.recordOnly] = machine.afterStopEngine }
        }
        meetingSwitch = MeetingSwitchDisplay(machine: machine)
    }
}

/// Where a running panel's clicks go; set while a meeting records.
struct MeetingSwitchHandler {
    var click: (MeetingEngineTarget) -> Void
    /// False: the pair stays as it was.
    var changePair: (TranslationLanguagePair) -> Bool
}

/// What the panel shows of a switch.
struct MeetingSwitchDisplay: Equatable {
    var isConnecting = false
    var runningIsLive = true
    var running: MeetingEngineTarget = .live(.didunyCloud)
    var markers: [MeetingSwitchMarker] = []
    var failure: SwitchFailure?
    /// What "Try again" clicks.
    var failedTarget: MeetingEngineTarget?
    var note: MeetingPersistentNote?
    /// The target a switch is connecting to; nil when none is.
    var pending: MeetingEngineTarget?
    /// A cut happened: the recording has more than one span.
    var switched = false

    init() {}

    init(machine: MeetingSwitchMachine) {
        isConnecting = machine.isConnecting
        running = machine.running
        runningIsLive = machine.running.isLive
        markers = machine.markers
        failure = machine.failure
        failedTarget = machine.failedTarget
        note = machine.persistentNote
        pending = machine.isConnecting ? machine.selected : nil
        switched = machine.history.spans.count > 1
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
