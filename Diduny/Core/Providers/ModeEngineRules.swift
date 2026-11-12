import Foundation

/// Which engines each mode offers, which meeting segment an engine implies, the ElevenLabs model per mode and
/// "Use one engine for everything" (ADR-0012 D3, D6; 05 §2.1.1, §3). Pure: reads only `EngineCapabilities`.
enum ModeEngineRules {
    struct Group: Equatable {
        enum Kind: Equatable { case cloud, onThisMac, onThisMacRecommended, flat }
        let kind: Kind
        let engines: [EngineID]
    }

    /// Menu groups for a mode. `available` holds the engines the user has (ElevenLabs only with a key);
    /// order inside a group follows `EngineID.allCases`.
    static func offeredEngines(job: STTJob, segment: MeetingSegment? = nil, available: [EngineCapabilities]) -> [Group] {
        let ordered = EngineID.allCases.compactMap { id in available.first { $0.id == id } }
        let cloud = ordered.filter { $0.traits.runsOn == .cloud }.map(\.id)
        let thisMac = ordered.filter { $0.traits.runsOn == .thisMac }.map(\.id)
        let groups: [Group]
        switch job {
        case .dictation, .dictationTranslation:
            groups = [Group(kind: .cloud, engines: cloud), Group(kind: .onThisMac, engines: thisMac)]
        case .meetingTranslation:
            // Engines on this Mac record and transcribe a meeting but cannot translate it: cloud only.
            groups = [Group(kind: .cloud, engines: cloud)]
        case .file:
            groups = [Group(kind: .onThisMac, engines: thisMac)]
        case .meeting:
            switch segment ?? .cloud {
            case .thisMac:
                groups = [Group(kind: .flat, engines: ordered.filter {
                    $0.traits.runsOn == .thisMac && $0.liveMeetingText != .none
                }.map(\.id))]
            case .cloud:
                groups = [Group(kind: .flat, engines: ordered.filter {
                    $0.traits.runsOn == .cloud && $0.liveMeetingText != .none
                }.map(\.id))]
            case .recordOnly:
                groups = [Group(kind: .onThisMacRecommended, engines: thisMac), Group(kind: .cloud, engines: cloud)]
            }
        }
        return groups.filter { !$0.engines.isEmpty }
    }

    static func offers(_ engine: EngineID, job: STTJob, segment: MeetingSegment? = nil, available: [EngineCapabilities]) -> Bool {
        offeredEngines(job: job, segment: segment, available: available).contains { $0.engines.contains(engine) }
    }

    /// 05 §3 table: cloud engines → Cloud, live engines on this Mac → This Mac, others (Parakeet) → Record only.
    static func segment(implyingEngine caps: EngineCapabilities) -> MeetingSegment {
        if caps.traits.runsOn == .cloud { return .cloud }
        return caps.liveMeetingText == .none ? .recordOnly : .thisMac
    }

    /// ADR-0012 D2: the router must read only batch caps. Wired into `JobRequest.afterStop` by WP-17.
    static func runsAfterStop(job: STTJob, segment: MeetingSegment?, caps: EngineCapabilities) -> Bool {
        switch job {
        case .meeting: segment == .recordOnly
        case .meetingTranslation: caps.meetingTranslation != .liveBothDirections
        case .dictation, .dictationTranslation, .file: false
        }
    }

    /// ADR-0012 D6: the model id to store with a pick. Explicit for ElevenLabs, never nil; nil for the others.
    static func modelID(engine: EngineID, job: STTJob, segment: MeetingSegment? = nil) -> String? {
        guard engine == .elevenLabs else { return nil }
        switch job {
        case .dictation, .dictationTranslation: return ElevenLabsProvider.realtimeModelID
        case .meeting: return segment == .recordOnly ? ElevenLabsProvider.batchModelID : ElevenLabsProvider.realtimeModelID
        case .meetingTranslation, .file: return ElevenLabsProvider.batchModelID
        }
    }

    static func selection(engine: EngineID, job: STTJob, segment: MeetingSegment? = nil) -> JobProviderSelection {
        JobProviderSelection(providerID: engine.rawValue, modelID: modelID(engine: engine, job: job, segment: segment))
    }

    /// 05 §3: Dictation, Translation and Translate meeting always; Files only for an engine on this Mac;
    /// Meeting: "Starts in" and that segment's engine. Other segments, Into and the pair are untouched.
    static func useOneEngineForEverything(_ caps: EngineCapabilities) -> [ModeDefaults.Write] {
        let engine = caps.id
        // Meeting translation is cloud only, so an engine on this Mac leaves it as it is.
        let jobs: [STTJob] = caps.traits.runsOn == .cloud
            ? [.dictation, .dictationTranslation, .meetingTranslation] : [.dictation, .dictationTranslation]
        var writes: [ModeDefaults.Write] = jobs.map {
            .engine($0, selection(engine: engine, job: $0))
        }
        if caps.traits.runsOn == .thisMac {
            writes.append(.engine(.file, selection(engine: engine, job: .file)))
        }
        let segment = segment(implyingEngine: caps)
        writes.append(.startsIn(segment))
        writes.append(.segmentEngine(segment, selection(engine: engine, job: .meeting, segment: segment)))
        return writes
    }

    /// 05 §3 item 3: Dictation's engine when every mode that can run it uses it, else nil ("Different per mode").
    /// Files skip a cloud engine; Meeting compares its current segment's engine.
    static func displayedUniformEngine(defaults: ModeDefaults, available: [EngineCapabilities]) -> EngineID? {
        displayedUniformEngine(engine: defaults.engine(for:), available: available)
    }

    /// The same rule over any source; `engine(.meeting)` is the "Starts in" segment's engine.
    static func displayedUniformEngine(engine: (STTJob) -> EngineID, available: [EngineCapabilities]) -> EngineID? {
        let dictation = engine(.dictation)
        guard let caps = available.first(where: { $0.id == dictation }) else { return nil }
        var jobs: [STTJob] = [.dictationTranslation, .meeting]
        // Meeting translation is cloud only: it counts for a cloud engine; Files count for an engine on this Mac.
        if caps.traits.runsOn == .thisMac { jobs.append(.file) } else { jobs.append(.meetingTranslation) }
        return jobs.allSatisfy { engine($0) == dictation } ? dictation : nil
    }
}
