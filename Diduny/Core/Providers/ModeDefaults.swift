import Foundation

/// The default engine of each mode (plan 3.2, ADR-0012 D4). New-install defaults are read-time defaults here;
/// `ProviderDefaultsStore.selection(for:)` keeps "unset = Diduny Cloud" for the legacy readers until WP-17.
struct ModeDefaults {
    let defaults: UserDefaults
    var knownProviderIDs: Set<String> = ProviderRegistry.shared.providerIDs

    static let meetingTranscriptModeKey = "meetingTranscriptMode"

    enum Write: Equatable {
        case engine(STTJob, JobProviderSelection)
        case segmentEngine(MeetingSegment, JobProviderSelection)
        case startsIn(MeetingSegment)
    }

    static func storageKey(for segment: MeetingSegment) -> String {
        "sttJobDefault.meeting.\(segment.rawValue)"
    }

    /// New-install value of a mode; `.meeting` without a segment means the "Starts in" segment.
    static func newInstallEngine(for job: STTJob) -> EngineID {
        switch job {
        case .dictation, .dictationTranslation, .meetingTranslation, .meeting: .didunyCloud
        case .file: .parakeet
        }
    }

    static func newInstallEngine(for segment: MeetingSegment) -> EngineID {
        switch segment {
        case .thisMac: .whisper
        case .cloud: .didunyCloud
        case .recordOnly: .parakeet
        }
    }

    static let newInstallStartsIn: MeetingSegment = .cloud

    private var store: ProviderDefaultsStore {
        ProviderDefaultsStore(defaults: defaults, knownProviderIDs: knownProviderIDs)
    }

    var meetingStartsIn: MeetingSegment {
        defaults.string(forKey: Self.meetingTranscriptModeKey).flatMap(MeetingSegment.init(rawValue:))
            ?? Self.newInstallStartsIn
    }

    /// The stored selection, or the new-install default. For `.meeting` reads the "Starts in" segment.
    func selection(for job: STTJob) -> JobProviderSelection {
        if job == .meeting { return selection(for: meetingStartsIn) }
        return validSelection(forKey: ProviderDefaultsStore.storageKey(for: job))
            ?? Self.selection(Self.newInstallEngine(for: job))
    }

    func selection(for segment: MeetingSegment) -> JobProviderSelection {
        validSelection(forKey: Self.storageKey(for: segment)) ?? Self.selection(Self.newInstallEngine(for: segment))
    }

    func engine(for job: STTJob) -> EngineID {
        EngineID(rawValue: selection(for: job).providerID) ?? Self.newInstallEngine(for: job)
    }

    func engine(for segment: MeetingSegment) -> EngineID {
        EngineID(rawValue: selection(for: segment).providerID) ?? Self.newInstallEngine(for: segment)
    }

    /// Sets a mode's engine. For `.meeting` it edits the current "Starts in" segment (T5-MD-05).
    func setSelection(_ selection: JobProviderSelection, for job: STTJob) {
        if job == .meeting {
            apply([.segmentEngine(meetingStartsIn, selection)])
        } else {
            apply([.engine(job, selection)])
        }
    }

    func apply(_ writes: [Write]) {
        for write in writes {
            switch write {
            case let .engine(job, selection):
                if job == .meeting {
                    store.setSelection(selection, forKey: Self.storageKey(for: meetingStartsIn))
                } else {
                    store.setSelection(selection, forKey: ProviderDefaultsStore.storageKey(for: job))
                }
            case let .segmentEngine(segment, selection):
                store.setSelection(selection, forKey: Self.storageKey(for: segment))
            case let .startsIn(segment):
                defaults.set(segment.rawValue, forKey: Self.meetingTranscriptModeKey)
            }
        }
    }

    /// Key removal (05 2.1 proposal): modes on `engine` go back to their new-install default, so ElevenLabs
    /// modes read Diduny Cloud and a Record only segment reads Parakeet V3. Returns the keys reset.
    @discardableResult
    func resetModes(using engine: EngineID) -> [String] {
        let keys = [STTJob.dictation, .dictationTranslation, .meetingTranslation, .file]
            .map(ProviderDefaultsStore.storageKey(for:))
            + MeetingSegment.allCases.map(Self.storageKey(for:))
        let affected = keys.filter { store.storedSelection(forKey: $0)?.providerID == engine.rawValue }
        affected.forEach(defaults.removeObject(forKey:))
        return affected
    }

    private func validSelection(forKey key: String) -> JobProviderSelection? {
        guard let stored = store.storedSelection(forKey: key), EngineID(rawValue: stored.providerID) != nil
        else { return nil }
        return stored
    }

    private static func selection(_ engine: EngineID) -> JobProviderSelection {
        JobProviderSelection(providerID: engine.rawValue, modelID: nil)
    }
}
