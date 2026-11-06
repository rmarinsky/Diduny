@testable import Diduny
import XCTest

final class BuiltInProviderRoutingTests: XCTestCase {
    private let signedIn = RoutingContext(providersWithKey: [], didunyTranslationAvailable: true)
    private let signedOut = RoutingContext(providersWithKey: [], didunyTranslationAvailable: false)

    @MainActor
    private func route(
        _ job: STTJob,
        _ defaults: UserDefaults,
        segment: MeetingSegment? = nil,
        readiness: FakeEngineReadinessSource? = nil,
        signedIn: Bool = true
    ) -> RunTimeRoute {
        RunTimeRouting.route(job: job, segment: segment, defaults: ModeDefaults(defaults: defaults), readiness: readiness ?? FakeEngineReadinessSource(),
                             whisper: .init(downloaded: [], selected: nil), signedIn: signedIn)
    }

    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "BuiltInProviderRoutingTests.\(UUID().uuidString)")!
    }

    // MARK: Routing reads ModeDefaults (WP-17, T5-MIG-34)

    @MainActor
    func testFreshInstallRoutesTheNewInstallDefaults() {
        let defaults = freshDefaults()
        for job in [STTJob.dictation, .dictationTranslation, .meetingTranslation, .meeting] {
            XCTAssertEqual(route(job, defaults).engine, .didunyCloud, "\(job)")
            XCTAssertEqual(route(job, defaults).baseProvider, .cloud, "\(job)")
            // Today's rule: Diduny Cloud signed out runs Local.
            XCTAssertEqual(route(job, defaults, signedIn: false).baseProvider, .local, "\(job)")
        }
        XCTAssertEqual(route(.file, defaults).engine, .parakeet)
        XCTAssertEqual(route(.meeting, defaults, segment: .thisMac).engine, .whisper)
    }

    @MainActor
    func testRetiredLegacyKeysNoLongerRoute() {
        let defaults = freshDefaults()
        ModeDefaults(defaults: defaults).apply([.engine(.dictation, JobProviderSelection(providerID: "diduny-cloud"))])
        for value in [TranscriptionProvider.local, .cloud] {
            defaults.set(value.rawValue, forKey: "transcriptionProvider")
            defaults.set(value.rawValue, forKey: "translationProvider")
            defaults.set(value == .cloud, forKey: "meetingRealtimeTranscriptionEnabled")
            XCTAssertEqual(route(.dictation, defaults).baseProvider, .cloud)
            XCTAssertEqual(route(.dictationTranslation, defaults).baseProvider, .cloud)
            XCTAssertEqual(route(.meeting, defaults).engine, .didunyCloud)
        }
    }

    @MainActor
    func testUnknownProviderSelectionReadsTheModeDefault() {
        let defaults = freshDefaults()
        ProviderDefaultsStore(defaults: defaults).setSelection(JobProviderSelection(providerID: "foo"), for: .dictation)
        XCTAssertEqual(route(.dictation, defaults).engine, .didunyCloud)
    }

    @MainActor
    func testExplicitLocalWhisperSelectionRoutesLocal() {
        let defaults = freshDefaults()
        let whisper = JobProviderSelection(providerID: STTProviderID.localWhisper, modelID: nil)
        ModeDefaults(defaults: defaults).apply([.engine(.dictation, whisper), .segmentEngine(.cloud, whisper)])
        XCTAssertEqual(route(.dictation, defaults).baseProvider, .local)
        XCTAssertEqual(route(.dictation, defaults, signedIn: false).baseProvider, .local)
        XCTAssertEqual(route(.meeting, defaults).baseProvider, .local)
    }

    // MARK: Registry + capabilities

    func testRegistryContainsBuiltInModules() {
        let registry = ProviderRegistry.shared
        XCTAssertNotNil(registry.module(id: STTProviderID.didunyCloud))
        XCTAssertNotNil(registry.module(id: STTProviderID.localWhisper))
        XCTAssertFalse(registry.module(id: STTProviderID.didunyCloud)!.requiresKey)
        XCTAssertFalse(registry.module(id: STTProviderID.localWhisper)!.requiresKey)
        // ADR-0012 D1: five modules, one per engine; Parakeet V3 and Apple Speech need no key.
        XCTAssertEqual(registry.modules.count, 5)
        XCTAssertEqual(Set(registry.modules.map(\.id)), Set(EngineID.allCases.map(\.rawValue)))
        XCTAssertFalse(try XCTUnwrap(registry.module(id: STTProviderID.parakeet)).requiresKey)
        XCTAssertFalse(try XCTUnwrap(registry.module(id: STTProviderID.appleSpeech)).requiresKey)
        XCTAssertEqual(registry.providerIDs, Set(EngineID.allCases.map(\.rawValue)))
    }

    /// Parakeet V3 and Apple Speech run on this Mac through `OnDeviceEngines`, never through the Cloud flow.
    @MainActor
    func testOnDeviceSelectionsRouteToOnDeviceEngines() {
        for engine in [EngineID.parakeet, .appleSpeech] {
            let defaults = freshDefaults()
            ModeDefaults(defaults: defaults).apply([.engine(.dictation, JobProviderSelection(providerID: engine.rawValue))])
            XCTAssertEqual(route(.dictation, defaults).onDeviceEngineID, engine.rawValue)
        }
    }

    func testCloudPlansMatchCurrentFlows() throws {
        let model = try XCTUnwrap(DidunyCloudProvider().models.first)
        let plan = { (request: JobRequest) in
            JobRouter.plan(request, providerID: STTProviderID.didunyCloud, requiresKey: false,
                           model: model, context: self.signedOut)
        }
        XCTAssertEqual(plan(JobRequest(job: .dictation)), .plan(ExecutionPlan(mode: .live)))
        XCTAssertEqual(
            plan(JobRequest(job: .dictationTranslation)),
            .plan(ExecutionPlan(mode: .live, translation: .native))
        )
        XCTAssertEqual(
            plan(JobRequest(job: .meeting, speakerLabels: true, meetingTranslation: true)),
            .plan(ExecutionPlan(mode: .live, translation: .native, speakerLabels: true))
        )
        XCTAssertEqual(plan(JobRequest(job: .file)), .plan(ExecutionPlan(mode: .batch)))
    }

    func testLocalWhisperHasNoSpeakerLabelsAndOneWayTranslationOnly() throws {
        let model = try XCTUnwrap(LocalWhisperProvider().models.first)
        let caps = model.capabilities
        XCTAssertEqual(caps.batch?.diarization, false)
        XCTAssertEqual(caps.realtime?.diarization, false)
        XCTAssertEqual(caps.batch?.translation, TranslationCaps(oneWay: true, twoWay: false))
        XCTAssertEqual(
            JobRouter.plan(JobRequest(job: .meeting, speakerLabels: true), providerID: STTProviderID.localWhisper,
                           requiresKey: false, model: model, context: signedIn),
            .plan(ExecutionPlan(mode: .live, noSpeakerLabelsNote: true))
        )
    }

    func testDidunyTextTranslationConformsToProtocol() {
        let service: TextTranslationProtocol = DidunyTextTranslationService()
        XCTAssertNotNil(service)
    }
}
