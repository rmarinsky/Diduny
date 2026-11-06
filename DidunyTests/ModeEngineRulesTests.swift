@testable import Diduny
import Foundation
import Testing

/// Matrix 05 §2.1.1 and the §3 rule (T1-MT-01, T3-CAP-03, T5-MD-01, T5-MD-05, T5-ALL-01, T5-ALL-02).
@Suite("Mode engine rules")
struct ModeEngineRulesTests {
    static func all(withKey: Bool) throws -> [EngineCapabilities] {
        try EngineID.allCases.filter { withKey || $0 != .elevenLabs }.map { try EngineCapabilitiesTests.capabilities($0) }
    }

    typealias G = ModeEngineRules.Group

    @Test("Offered engines per mode and segment", arguments: [false, true])
    func offered(withKey: Bool) throws {
        let caps = try Self.all(withKey: withKey)
        let cloud: [EngineID] = withKey ? [.didunyCloud, .elevenLabs] : [.didunyCloud]
        let local: [EngineID] = [.whisper, .parakeet, .appleSpeech]
        for job in [STTJob.dictation, .dictationTranslation, .meetingTranslation] {
            #expect(ModeEngineRules.offeredEngines(job: job, available: caps)
                == [G(kind: .cloud, engines: cloud), G(kind: .onThisMac, engines: local)])
        }
        #expect(ModeEngineRules.offeredEngines(job: .file, available: caps) == [G(kind: .onThisMac, engines: local)])
        #expect(ModeEngineRules.offeredEngines(job: .meeting, segment: .thisMac, available: caps)
            == [G(kind: .flat, engines: [.whisper, .appleSpeech])])
        #expect(ModeEngineRules.offeredEngines(job: .meeting, segment: .cloud, available: caps) == [G(kind: .flat, engines: cloud)])
        #expect(ModeEngineRules.offeredEngines(job: .meeting, segment: .recordOnly, available: caps)
            == [G(kind: .onThisMacRecommended, engines: local), G(kind: .cloud, engines: cloud)])
    }

    @Test("The segment an engine implies (05 §3 table)")
    func impliedSegment() throws {
        let expected: [EngineID: MeetingSegment] = [
            .didunyCloud: .cloud, .elevenLabs: .cloud, .whisper: .thisMac, .appleSpeech: .thisMac, .parakeet: .recordOnly,
        ]
        for caps in try Self.all(withKey: true) {
            #expect(ModeEngineRules.segment(implyingEngine: caps) == expected[caps.id])
        }
    }

    @Test("ElevenLabs model per mode (ADR-0012 D6)")
    func elevenLabsModel() {
        let live = ElevenLabsProvider.realtimeModelID, batch = ElevenLabsProvider.batchModelID
        #expect(ModeEngineRules.modelID(engine: .elevenLabs, job: .dictation) == live)
        #expect(ModeEngineRules.modelID(engine: .elevenLabs, job: .dictationTranslation) == live)
        #expect(ModeEngineRules.modelID(engine: .elevenLabs, job: .meeting, segment: .cloud) == live)
        #expect(ModeEngineRules.modelID(engine: .elevenLabs, job: .meeting, segment: .recordOnly) == batch)
        #expect(ModeEngineRules.modelID(engine: .elevenLabs, job: .meetingTranslation) == batch)
        #expect(ModeEngineRules.modelID(engine: .didunyCloud, job: .dictation) == nil)
    }

    @Test("After Stop: Record only, and Translate meeting without native two-way (ADR-0012 D2)")
    func afterStop() throws {
        let cloud = try EngineCapabilitiesTests.capabilities(.didunyCloud)
        let whisper = try EngineCapabilitiesTests.capabilities(.whisper)
        #expect(ModeEngineRules.runsAfterStop(job: .meeting, segment: .recordOnly, caps: cloud))
        #expect(!ModeEngineRules.runsAfterStop(job: .meeting, segment: .cloud, caps: cloud))
        #expect(!ModeEngineRules.runsAfterStop(job: .meetingTranslation, segment: nil, caps: cloud))
        #expect(ModeEngineRules.runsAfterStop(job: .meetingTranslation, segment: nil, caps: whisper))
    }

    @Test("Meeting row engine edits the current segment (T5-MD-05)")
    func meetingRowEditsSegment() {
        let modes = ModeDefaults(defaults: Self.suite())
        modes.setSelection(ModeEngineRules.selection(engine: .elevenLabs, job: .meeting, segment: .cloud), for: .meeting)
        modes.apply([.startsIn(.thisMac)])
        modes.setSelection(ModeEngineRules.selection(engine: .appleSpeech, job: .meeting), for: .meeting)
        #expect(modes.engine(for: .cloud) == .elevenLabs)
        #expect(modes.selection(for: .cloud).modelID == ElevenLabsProvider.realtimeModelID)
        #expect(modes.engine(for: .thisMac) == .appleSpeech)
        #expect(modes.engine(for: .recordOnly) == .parakeet)
    }

    @Test("Use one engine for everything writes each mode by the rule (T5-ALL-01)", arguments: EngineID.allCases)
    func useOneEngine(_ engine: EngineID) throws {
        let modes = ModeDefaults(defaults: Self.suite())
        let caps = try EngineCapabilitiesTests.capabilities(engine)
        modes.apply(ModeEngineRules.useOneEngineForEverything(caps))
        let segment = ModeEngineRules.segment(implyingEngine: caps)
        for job in [STTJob.dictation, .dictationTranslation, .meetingTranslation] {
            #expect(modes.engine(for: job) == engine)
        }
        #expect(modes.engine(for: .file) == (caps.traits.runsOn == .thisMac ? engine : .parakeet))
        #expect(modes.meetingStartsIn == segment)
        for other in MeetingSegment.allCases {
            #expect(modes.engine(for: other) == (other == segment ? engine : ModeDefaults.newInstallEngine(for: other)))
        }
        if engine == .elevenLabs {
            #expect(modes.selection(for: .meetingTranslation).modelID == ElevenLabsProvider.batchModelID)
        }
    }

    @Test("Field shows one engine or Different per mode (T5-ALL-02)")
    func displayedUniform() throws {
        let caps = try Self.all(withKey: true)
        let modes = ModeDefaults(defaults: Self.suite())
        modes.apply(ModeEngineRules.useOneEngineForEverything(try EngineCapabilitiesTests.capabilities(.didunyCloud)))
        #expect(ModeEngineRules.displayedUniformEngine(defaults: modes, available: caps) == .didunyCloud)
        modes.setSelection(JobProviderSelection(providerID: EngineID.whisper.rawValue), for: .dictation)
        #expect(ModeEngineRules.displayedUniformEngine(defaults: modes, available: caps) == nil)
    }

    @Test("Removing the key sends ElevenLabs modes to their defaults (05 2.1)")
    func keyRemoval() throws {
        let modes = ModeDefaults(defaults: Self.suite())
        modes.apply(ModeEngineRules.useOneEngineForEverything(try EngineCapabilitiesTests.capabilities(.elevenLabs)))
        modes.apply([.segmentEngine(.recordOnly, ModeEngineRules.selection(engine: .elevenLabs, job: .meeting, segment: .recordOnly))])
        modes.resetModes(using: .elevenLabs)
        #expect(modes.engine(for: .dictation) == .didunyCloud)
        #expect(modes.engine(for: .cloud) == .didunyCloud)
        #expect(modes.engine(for: .recordOnly) == .parakeet)
    }

    static func suite() -> UserDefaults {
        UserDefaults(suiteName: "test.\(UUID().uuidString)")!
    }
}
