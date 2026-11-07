import Foundation

/// What a mode runs at Start (WP-17). Read only from `ModeDefaults` through `EffectiveEngineResolver`;
/// the legacy Cloud/Local keys stay on disk but no longer route (05 §4.2, T5-MIG-34).
struct RunTimeRoute: Equatable {
    var engine: EngineID
    var modelID: String?
    /// The engine cannot run and nothing stands in; Start refuses with `RunTimeRouting.startError`.
    var unavailable: EngineReadiness?
    /// The Cloud/Local flow the recording code branches on. Own engines (ElevenLabs, Parakeet, Apple) branch
    /// before it. Whisper is Local; any other engine is Cloud when signed in, else Local (today's rule).
    var baseProvider: TranscriptionProvider

    var selection: JobProviderSelection { JobProviderSelection(providerID: engine.rawValue, modelID: modelID) }

    /// Parakeet V3 or Apple Speech: transcribed by `OnDeviceEngines`.
    var onDeviceEngineID: String? {
        STTProviderID.onDeviceEngines.contains(engine.rawValue) ? engine.rawValue : nil
    }
}

/// How a meeting starts in its segment (ADR-0012 D4, 05 §3).
struct MeetingStartRoute: Equatable {
    var segment: MeetingSegment
    var engine: EngineID
    var modelID: String?
    /// `.cloud` streams live (sign-in resolved later by `resolveMeetingTranscriptionProvider`).
    var provider: TranscriptionProvider
    var recordOnly: Bool
    /// Whisper's live preview on This Mac.
    var localPreview: Bool
    /// Parakeet or Apple makes the transcript after Stop.
    var afterStopEngineID: String?
    /// The segment's engine cannot run and nothing stands in; Start shows the reason.
    var unavailable: EngineReadiness?

    var selection: JobProviderSelection { JobProviderSelection(providerID: engine.rawValue, modelID: modelID) }

    /// The engine that makes the text; Record only runs its own engine after Stop, cloud ones too (WP-62).
    var runningEngine: EngineID { engine }

    /// Recovering an orphaned capture: Cloud only for a signed-in Cloud segment without an after-Stop
    /// engine on this Mac; Record only, This Mac, Parakeet and Apple recover on this Mac.
    func recoversInCloud(signedIn: Bool) -> Bool {
        provider == .cloud && !recordOnly && afterStopEngineID == nil && signedIn
    }
}

enum RunTimeRouting {
    @MainActor
    static func route(
        job: STTJob,
        segment: MeetingSegment? = nil,
        override: JobProviderSelection? = nil,
        defaults: ModeDefaults,
        readiness: any EngineReadinessSource,
        whisper: EffectiveEngineResolver.WhisperState,
        signedIn: Bool
    ) -> RunTimeRoute {
        let selection = override ?? (job == .meeting
            ? defaults.selection(for: segment ?? defaults.meetingStartsIn)
            : defaults.selection(for: job))
        let engine: EngineID
        let modelID: String?
        var unavailable: EngineReadiness?
        switch EffectiveEngineResolver.resolve(job: job, segment: segment, override: override, defaults: defaults,
                                               readiness: readiness, whisper: whisper) {
        case let .engine(id, model), let .fallback(id, model, _):
            engine = id
            modelID = model
        case let .none(state):
            engine = EngineID(rawValue: selection.providerID) ?? .didunyCloud
            modelID = selection.modelID
            unavailable = state
        }
        return RunTimeRoute(engine: engine, modelID: modelID, unavailable: unavailable,
                            baseProvider: baseProvider(for: engine, signedIn: signedIn))
    }

    /// The Start refusal for an engine that cannot run: on-device engines name the download, others
    /// (ElevenLabs without a key) point to Providers. Nil when it can run.
    static func startError(_ unavailable: EngineReadiness?, engine: EngineID) -> String? {
        guard unavailable != nil else { return nil }
        return STTProviderID.onDeviceEngines.contains(engine.rawValue)
            ? OnDeviceEngines.notReadyMessage
            : String(localized: "The selected engine isn't available. Check Settings › Providers.")
    }

    /// Local Whisper translation into `target` (bug 9): Whisper itself where its model can; else Whisper
    /// transcribes and the Diduny text step translates; signed out that step cannot run.
    enum LocalTranslation: Equatable { case whisper, didunyStep, signInNeeded }

    static func localTranslation(model: String?, target: String, signedIn: Bool) -> LocalTranslation {
        if JobRequest.whisperTranslationUsable(model: model, target: target) { return .whisper }
        return signedIn ? .didunyStep : .signInNeeded
    }

    /// Translate meeting on an engine that cannot translate live: audio only, the engine transcribes after
    /// Stop and Diduny translates (WP-61, 10A).
    static func meetingTranslationAfterStop(_ route: RunTimeRoute) -> MeetingStartRoute {
        MeetingStartRoute(segment: .recordOnly, engine: route.engine, modelID: route.modelID, provider: .local,
                          recordOnly: false, localPreview: false, afterStopEngineID: route.onDeviceEngineID,
                          unavailable: route.unavailable)
    }

    /// Translate meeting recovery: the target saved with the session, else the pair's Language B.
    static func meetingTranslationRecoveryTarget(saved: String?, pair: TranslationLanguagePair) -> String {
        saved ?? pair.languageB
    }

    /// "On this Mac" in the reminder: the resolved start's engine runs on the device (8A).
    static func calendarShowsThisMac(_ start: MeetingStartRoute) -> Bool {
        [.whisper, .parakeet, .appleSpeech].contains(start.engine)
    }

    /// A calendar meeting starts in "Starts in" (8A). A pick that matches what is shown keeps it; a
    /// different pick goes to This Mac or Cloud. `localRecording` no longer picks the segment.
    static func calendarSegment(localOverride: Bool?, startsIn: MeetingSegment, showsThisMac: Bool) -> MeetingSegment {
        guard let local = localOverride, local != showsThisMac else { return startsIn }
        return local ? .thisMac : .cloud
    }

    static func baseProvider(for engine: EngineID, signedIn: Bool) -> TranscriptionProvider {
        engine == .whisper || !signedIn ? .local : .cloud
    }

    /// Cloud streams live; This Mac streams Whisper's preview or Apple; Record only records and its
    /// engine transcribes after Stop (Diduny Cloud and ElevenLabs with speaker labels, WP-62).
    static func meetingStart(segment: MeetingSegment, route: RunTimeRoute) -> MeetingStartRoute {
        let onDevice = route.onDeviceEngineID
        var start = MeetingStartRoute(segment: segment, engine: route.engine, modelID: route.modelID,
                                      provider: .local, recordOnly: false, localPreview: false,
                                      afterStopEngineID: onDevice, unavailable: route.unavailable)
        switch segment {
        case .cloud:
            start.provider = .cloud
        case .thisMac:
            start.localPreview = route.engine == .whisper
        case .recordOnly:
            start.recordOnly = true
        }
        return start
    }
}
