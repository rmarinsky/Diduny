@testable import Diduny
import XCTest

final class JobRouterTests: XCTestCase {
    private struct FakeModule: STTProviderModule {
        let id: String
        let displayName: String
        let requiresKey: Bool
        let models: [STTModel]
        let traits = EngineTraits(runsOn: .cloud, obtainedBy: .ownKey, needs: [.ownKey], recommended: .none, languages: .system)
    }

    private let byok = "byok-fake"
    private let withKey = RoutingContext(providersWithKey: ["byok-fake"], didunyTranslationAvailable: true)

    private func caps(
        batch: BatchCaps? = nil,
        realtime: RealtimeCaps? = nil,
        languages: LanguageSupport = .all
    ) -> STTModelCapabilities {
        STTModelCapabilities(
            batch: batch, realtime: realtime, languages: languages, autoLanguageDetection: true,
            batchDeletion: .byID, realtimeDeletion: .unverified
        )
    }

    private var batchOnly: STTModel {
        STTModel(id: "batch", displayName: "Batch", capabilities: caps(
            batch: BatchCaps(maxDurationSeconds: 36000, maxFileBytes: 3_000_000_000, diarization: true, maxSpeakers: 32)
        ))
    }

    private var realtimeOnly: STTModel {
        STTModel(id: "rt", displayName: "RT", capabilities: caps(
            realtime: RealtimeCaps(idleTimeoutSeconds: 15, liveQuality: .final, diarization: false, manualCommit: true),
            languages: .set(["en", "uk"])
        ))
    }

    private var nativeTranslating: STTModel {
        let translation = TranslationCaps(oneWay: true, twoWay: true)
        return STTModel(id: "native", displayName: "Native", capabilities: caps(
            batch: BatchCaps(diarization: true, translation: translation),
            realtime: RealtimeCaps(liveQuality: .final, diarization: true, manualCommit: true, translation: translation)
        ))
    }

    private func route(_ request: JobRequest, _ model: STTModel, context: RoutingContext? = nil) -> RoutingResult {
        JobRouter.plan(request, providerID: byok, requiresKey: true, model: model, context: context ?? withKey)
    }

    // MARK: Meeting translation

    func test_meetingTranslation_nativeTwoWayModelTranslatesLive() {
        XCTAssertEqual(
            route(JobRequest(job: .meetingTranslation), nativeTranslating),
            .plan(ExecutionPlan(mode: .live, translation: .native))
        )
    }

    func test_meetingTranslation_withoutDidunyTranslationIsUnsupported() {
        let context = RoutingContext(providersWithKey: [byok], didunyTranslationAvailable: false)
        XCTAssertEqual(route(JobRequest(job: .meetingTranslation), realtimeOnly, context: context), .unsupported(.translationNeedsDiduny))
    }

    func test_onDeviceEnginesAreKnownProviderIDs() {
        XCTAssertTrue(ProviderRegistry.shared.providerIDs.isSuperset(of: STTProviderID.onDeviceEngines))
    }

    // MARK: Dictation

    func test_dictation_realtimeModelIsLive() {
        XCTAssertEqual(route(JobRequest(job: .dictation), realtimeOnly), .plan(ExecutionPlan(mode: .live)))
    }

    func test_dictation_batchOnlyFallsBackToAfterStop() {
        XCTAssertEqual(route(JobRequest(job: .dictation), batchOnly), .plan(ExecutionPlan(mode: .afterStop)))
    }

    func test_dictation_noModeIsUnsupported() {
        let none = STTModel(id: "none", displayName: "None", capabilities: caps())
        XCTAssertEqual(route(JobRequest(job: .dictation), none), .unsupported(.noUsableMode))
    }

    func test_byokWithoutKeyIsUnsupported() {
        let noKey = RoutingContext(providersWithKey: [], didunyTranslationAvailable: true)
        XCTAssertEqual(route(JobRequest(job: .dictation), realtimeOnly, context: noKey), .unsupported(.noKey))
    }

    // MARK: Translation

    func test_dictationTranslation_usesDidunyStepWhenModelCannotTranslate() {
        XCTAssertEqual(
            route(JobRequest(job: .dictationTranslation), realtimeOnly),
            .plan(ExecutionPlan(mode: .live, translation: .didunyStep))
        )
    }

    func test_dictationTranslation_needsDidunyWhenSignedOutOrNoQuota() {
        let signedOut = RoutingContext(providersWithKey: [byok], didunyTranslationAvailable: false)
        XCTAssertEqual(
            route(JobRequest(job: .dictationTranslation), realtimeOnly, context: signedOut),
            .unsupported(.translationNeedsDiduny)
        )
        // Plain dictation still works.
        XCTAssertEqual(route(JobRequest(job: .dictation), realtimeOnly, context: signedOut), .plan(ExecutionPlan(mode: .live)))
    }

    func test_translation_nativeWhenModelTranslates() {
        let signedOut = RoutingContext(providersWithKey: [byok], didunyTranslationAvailable: false)
        XCTAssertEqual(
            route(JobRequest(job: .dictationTranslation), nativeTranslating, context: signedOut),
            .plan(ExecutionPlan(mode: .live, translation: .native))
        )
    }

    // MARK: Meetings

    func test_meeting_withoutDiarizationIsLiveWithNoLabelsNote() {
        let result = route(JobRequest(job: .meeting, speakerLabels: true), realtimeOnly)
        XCTAssertEqual(result, .plan(ExecutionPlan(mode: .live, speakerLabels: false, noSpeakerLabelsNote: true)))
    }

    func test_meeting_withDiarizationKeepsLabels() {
        let result = route(JobRequest(job: .meeting, speakerLabels: true), nativeTranslating)
        XCTAssertEqual(result, .plan(ExecutionPlan(mode: .live, speakerLabels: true)))
    }

    func test_meeting_translationViaDidunyStepOrUnsupported() {
        let request = JobRequest(job: .meeting, meetingTranslation: true)
        XCTAssertEqual(route(request, realtimeOnly), .plan(ExecutionPlan(mode: .live, translation: .didunyStep)))
        let signedOut = RoutingContext(providersWithKey: [byok], didunyTranslationAvailable: false)
        XCTAssertEqual(route(request, realtimeOnly, context: signedOut), .unsupported(.translationNeedsDiduny))
    }

    // MARK: Files

    func test_file_realtimeOnlyModelIsUnsupported() {
        XCTAssertEqual(route(JobRequest(job: .file, fileDurationSeconds: 60), realtimeOnly), .unsupported(.noUsableMode))
    }

    func test_file_underLimitsIsSingleBatchWithLabels() {
        let request = JobRequest(job: .file, speakerLabels: true, fileDurationSeconds: 600, fileBytes: 10_000_000)
        XCTAssertEqual(route(request, batchOnly), .plan(ExecutionPlan(mode: .batch, speakerLabels: true)))
    }

    func test_file_exactly10hIsAllowed_over10hBlocked() {
        if case .unsupported = route(JobRequest(job: .file, fileDurationSeconds: 36000), batchOnly) {
            XCTFail("10 h exactly must be allowed")
        }
        XCTAssertEqual(
            route(JobRequest(job: .file, fileDurationSeconds: 36001), batchOnly),
            .unsupported(.fileTooLong(maxSeconds: 36000))
        )
    }

    func test_file_overSizeLimitIsChunkedWithOverlapAndSpeakerNote() throws {
        let request = JobRequest(job: .file, speakerLabels: true, fileDurationSeconds: 7200, fileBytes: 6_000_000_000)
        guard case let .plan(plan) = route(request, batchOnly),
              case let .chunked(chunkSeconds, overlap) = plan.mode
        else { return XCTFail("expected chunked plan") }
        XCTAssertEqual(overlap, JobRouter.chunkOverlapSeconds)
        XCTAssertLessThan(chunkSeconds, 3600)
        XCTAssertTrue(plan.speakerIDsMayDiffer)
        // Exactly at the size limit: single batch.
        let atLimit = JobRequest(job: .file, fileDurationSeconds: 7200, fileBytes: 3_000_000_000)
        XCTAssertEqual(route(atLimit, batchOnly), .plan(ExecutionPlan(mode: .batch)))
    }

    func test_file_unknownLimitsChunkConservatively() {
        let unknown = STTModel(id: "u", displayName: "U", capabilities: caps(batch: BatchCaps(diarization: false)))
        XCTAssertEqual(
            route(JobRequest(job: .file, fileDurationSeconds: 5 * 3600), unknown),
            .plan(ExecutionPlan(mode: .chunked(chunkSeconds: JobRouter.conservativeChunkSeconds, overlapSeconds: JobRouter.chunkOverlapSeconds)))
        )
    }

    // MARK: Languages and independence

    func test_unsupportedLanguageNamesTheLanguage() {
        XCTAssertEqual(route(JobRequest(job: .dictation, languages: ["uk", "ja"]), realtimeOnly), .unsupported(.language("ja")))
        XCTAssertEqual(route(JobRequest(job: .dictation, languages: ["auto"]), realtimeOnly), .plan(ExecutionPlan(mode: .live)))
    }

    func test_routingIsIndependentOfProviderID() {
        let other = RoutingContext(providersWithKey: ["something-else"], didunyTranslationAvailable: true)
        let a = route(JobRequest(job: .meeting, speakerLabels: true), realtimeOnly)
        let b = JobRouter.plan(JobRequest(job: .meeting, speakerLabels: true), providerID: "something-else",
                               requiresKey: true, model: realtimeOnly, context: other)
        XCTAssertEqual(a, b)
    }

    func test_thousandPlansUnder50ms() {
        let start = Date()
        for i in 0 ..< 1000 {
            _ = route(JobRequest(job: STTJob.allCases[i % 4], languages: ["uk"], fileDurationSeconds: 100), batchOnly)
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.05)
    }

    // MARK: Pickers

    func test_pickerListsOnlyPlannableModelsAndHidesByokWithoutKey() {
        let module = FakeModule(id: byok, displayName: "Fake", requiresKey: true, models: [batchOnly, realtimeOnly])
        let registry = ProviderRegistry(modules: [module])
        let file = JobRouter.pickerOptions(for: JobRequest(job: .file, fileDurationSeconds: 60), registry: registry, context: withKey)
        XCTAssertEqual(file.map(\.modelID), ["batch"])
        let dictation = JobRouter.pickerOptions(for: JobRequest(job: .dictation), registry: registry, context: withKey)
        XCTAssertEqual(dictation.map(\.modelID), ["batch", "rt"])
        XCTAssertEqual(dictation.first?.plan.mode, .afterStop)
        let noKey = RoutingContext(providersWithKey: [], didunyTranslationAvailable: true)
        XCTAssertTrue(JobRouter.pickerOptions(for: JobRequest(job: .dictation), registry: registry, context: noKey).isEmpty)
    }
}
