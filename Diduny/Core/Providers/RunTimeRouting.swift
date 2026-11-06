import Foundation

/// What a mode runs at Start (WP-17). Read only from `ModeDefaults` through `EffectiveEngineResolver`;
/// the legacy Cloud/Local keys stay on disk but no longer route (05 §4.2, T5-MIG-34).
struct RunTimeRoute: Equatable {
    var engine: EngineID
    var modelID: String?
    /// The engine cannot run and nothing stands in; Start shows the reason.
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

    var selection: JobProviderSelection { JobProviderSelection(providerID: engine.rawValue, modelID: modelID) }

    /// The engine that makes the text: a cloud engine in Record only is Whisper until WP-62.
    var runningEngine: EngineID {
        recordOnly && (engine == .didunyCloud || engine == .elevenLabs) ? .whisper : engine
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

    static func baseProvider(for engine: EngineID, signedIn: Bool) -> TranscriptionProvider {
        engine == .whisper || !signedIn ? .local : .cloud
    }

    /// Cloud streams live; This Mac streams Whisper's preview or Apple; Record only records and
    /// transcribes after Stop. A cloud engine in Record only keeps the audio on this Mac (Whisper after
    /// Stop) until WP-62 sends it to the cloud after Stop.
    static func meetingStart(segment: MeetingSegment, route: RunTimeRoute) -> MeetingStartRoute {
        let onDevice = route.onDeviceEngineID
        var start = MeetingStartRoute(segment: segment, engine: route.engine, modelID: route.modelID,
                                      provider: .local, recordOnly: false, localPreview: false,
                                      afterStopEngineID: onDevice)
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
