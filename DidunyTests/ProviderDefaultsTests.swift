@testable import Diduny
import XCTest

/// AC 14, 47: without a key every job keeps today's engine. AC 19/20 live in ProviderKeyStoreTests.
@MainActor
final class ProviderDefaultsTests: XCTestCase {
    private let elevenLive = JobProviderSelection(
        providerID: STTProviderID.elevenLabs,
        modelID: ElevenLabsProvider.realtimeModelID
    )
    private let noKey = RoutingContext(providersWithKey: [], didunyTranslationAvailable: true)
    private let withKey = RoutingContext(providersWithKey: [STTProviderID.elevenLabs], didunyTranslationAvailable: true)

    func testFreshStoreIsDidunyCloudForEveryJob() {
        let suite = "diduny.provider-defaults.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ProviderDefaultsStore(defaults: defaults)
        for job in STTJob.allCases {
            XCTAssertEqual(store.selection(for: job), .didunyCloud, "\(job)")
        }
    }

    func testBYOKSelectionWithoutKeyHasNoPlan() {
        for job in STTJob.allCases {
            XCTAssertNil(ProviderEngineRouting.byokPlan(
                for: job, providerID: STTProviderID.elevenLabs, selection: elevenLive, context: noKey
            ))
        }
    }

    func testElevenLabsDictationWithKeyPlansLive() throws {
        let plan = try XCTUnwrap(ProviderEngineRouting.byokPlan(
            for: .dictation, providerID: STTProviderID.elevenLabs, selection: elevenLive, context: withKey
        ))
        XCTAssertEqual(plan.mode, .live)
        XCTAssertNil(ProviderEngineRouting.byokPlan(
            for: .dictation, providerID: STTProviderID.elevenLabs, selection: .didunyCloud, context: withKey
        ))
    }

    func testMeetingPickerListsOnlyLiveElevenLabsWithNoSpeakerLabels() {
        let options = EngineOptions.options(
            for: JobRequest(job: .meeting, speakerLabels: true), context: withKey, signedIn: true
        )
        let byok = options.filter { $0.id.hasPrefix(STTProviderID.elevenLabs + "/") }
        XCTAssertEqual(byok.map(\.id), ["\(STTProviderID.elevenLabs)/\(ElevenLabsProvider.realtimeModelID)"])
        XCTAssertTrue(byok.first?.title.contains("no speaker labels") ?? false)
    }

    func testPickerOffersBYOKOnlyForWiredJobs() {
        for job in STTJob.allCases where job != .meetingTranslation {
            let ids = EngineOptions.options(for: JobRequest(job: job), context: withKey, signedIn: true).map(\.id)
            XCTAssertTrue(ids.starts(with: [STTProviderID.didunyCloud, STTProviderID.localWhisper]))
            let hasBYOK = ids.contains { $0.hasPrefix(STTProviderID.elevenLabs + "/") }
            XCTAssertEqual(hasBYOK, EngineOptions.byokJobs.contains(job), "\(job)")
        }
        // On-device engines (Parakeet, Apple) appear only when ready on this Mac, so ignore them here.
        let noKeyIDs = EngineOptions.options(for: JobRequest(job: .dictation), context: noKey, signedIn: true).map(\.id)
            .filter { !STTProviderID.onDeviceEngines.contains($0) }
        XCTAssertEqual(noKeyIDs, [STTProviderID.didunyCloud, STTProviderID.localWhisper])
    }

    func testMeetingTranslationOffersOnlyDidunyCloud() {
        let options = EngineOptions.options(for: JobRequest(job: .meetingTranslation), context: withKey, signedIn: true)
        // Parakeet / Apple may also be listed when ready on this Mac (transcribe after Stop, then translate once).
        XCTAssertEqual(
            options.filter { $0.disabledReason == nil && !STTProviderID.onDeviceEngines.contains($0.id) }.map(\.id),
            [STTProviderID.didunyCloud]
        )
        XCTAssertTrue(options.contains { $0.id.hasPrefix(STTProviderID.elevenLabs + "/") && $0.disabledReason != nil })
    }

    func testOnDeviceEnginesAreOfferedForEveryMode() {
        XCTAssertEqual(EngineOptions.onDeviceJobs, Set(STTJob.allCases))
    }

    func testFileSnapshotPicksUpOnDeviceSelection() {
        let suite = "diduny.file-snapshot.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let modes = ModeDefaults(defaults: defaults)
        func snapshot() -> FileTranscriptionSettingsSnapshot {
            .resolve(defaults: modes, readiness: FakeEngineReadinessSource(), whisper: .init(downloaded: [], selected: nil),
                     languageHints: [], selectedWhisperModel: "ggml-base")
        }
        modes.apply([.engine(.file, JobProviderSelection(providerID: STTProviderID.parakeet, modelID: nil))])
        XCTAssertEqual(snapshot().onDeviceEngineID, STTProviderID.parakeet)
        modes.apply([.engine(.file, .didunyCloud)])
        XCTAssertNil(snapshot().onDeviceEngineID)
        XCTAssertEqual(snapshot().provider, .local)
    }
}
