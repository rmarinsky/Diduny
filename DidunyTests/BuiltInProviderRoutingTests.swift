@testable import Diduny
import XCTest

final class BuiltInProviderRoutingTests: XCTestCase {
    private let signedIn = RoutingContext(providersWithKey: [], didunyTranslationAvailable: true)
    private let signedOut = RoutingContext(providersWithKey: [], didunyTranslationAvailable: false)

    private func engine(
        _ job: STTJob,
        _ selection: JobProviderSelection,
        legacy: TranscriptionProvider,
        context: RoutingContext? = nil
    ) -> TranscriptionProvider {
        ProviderEngineRouting.engine(
            for: job,
            selection: selection,
            legacy: legacy,
            context: context ?? signedIn
        )
    }

    // MARK: Default routing equals current behaviour

    func testDefaultSelectionKeepsLegacyProviderForEveryJob() {
        for job in STTJob.allCases {
            for legacy in [TranscriptionProvider.cloud, .local] {
                XCTAssertEqual(engine(job, .didunyCloud, legacy: legacy), legacy, "\(job) \(legacy)")
                XCTAssertEqual(engine(job, .didunyCloud, legacy: legacy, context: signedOut), legacy)
            }
        }
    }

    func testFreshDefaultsStoreRoutesExactlyLikeLegacy() {
        let defaults = UserDefaults(suiteName: "BuiltInProviderRoutingTests.\(UUID().uuidString)")!
        let store = ProviderDefaultsStore(defaults: defaults)
        for job in STTJob.allCases {
            XCTAssertEqual(engine(job, store.selection(for: job), legacy: .cloud), .cloud)
            XCTAssertEqual(engine(job, store.selection(for: job), legacy: .local), .local)
        }
    }

    func testUnknownProviderSelectionKeepsLegacy() {
        let selection = JobProviderSelection(providerID: "elevenlabs", modelID: "scribe_v2")
        XCTAssertEqual(engine(.dictation, selection, legacy: .cloud), .cloud)
    }

    func testExplicitLocalWhisperSelectionRoutesLocal() {
        let selection = JobProviderSelection(providerID: STTProviderID.localWhisper, modelID: nil)
        XCTAssertEqual(engine(.dictation, selection, legacy: .cloud), .local)
        XCTAssertEqual(engine(.meeting, selection, legacy: .cloud), .local)
        XCTAssertEqual(engine(.file, selection, legacy: .cloud), .local)
    }

    // MARK: Registry + capabilities

    func testRegistryContainsBuiltInModules() {
        let registry = ProviderRegistry.shared
        XCTAssertNotNil(registry.module(id: STTProviderID.didunyCloud))
        XCTAssertNotNil(registry.module(id: STTProviderID.localWhisper))
        XCTAssertFalse(registry.module(id: STTProviderID.didunyCloud)!.requiresKey)
        XCTAssertFalse(registry.module(id: STTProviderID.localWhisper)!.requiresKey)
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
