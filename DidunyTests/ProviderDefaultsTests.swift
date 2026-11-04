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

    func testBYOKSelectionWithoutKeyKeepsLegacyEngineAndHasNoPlan() {
        for job in STTJob.allCases {
            for legacy in [TranscriptionProvider.cloud, .local] {
                XCTAssertEqual(
                    ProviderEngineRouting.engine(for: job, selection: elevenLive, legacy: legacy, context: noKey),
                    legacy
                )
            }
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
        XCTAssertEqual(options.filter { $0.disabledReason == nil }.map(\.id), [STTProviderID.didunyCloud])
        XCTAssertTrue(options.contains { $0.id.hasPrefix(STTProviderID.elevenLabs + "/") && $0.disabledReason != nil })
    }

    func testOnDeviceEnginesAreOfferedForEveryModeButMeetingTranslation() {
        XCTAssertEqual(EngineOptions.onDeviceJobs, [.dictation, .dictationTranslation, .meeting, .file])
        let ids = EngineOptions.options(for: JobRequest(job: .meetingTranslation), context: withKey, signedIn: true).map(\.id)
        XCTAssertTrue(Set(ids).isDisjoint(with: STTProviderID.onDeviceEngines))
    }

    func testFileSnapshotPicksUpOnDeviceSelection() {
        let defaults = SettingsStorage.shared.providerDefaults
        let previous = defaults.selection(for: .file)
        defer { defaults.setSelection(previous, for: .file) }
        defaults.setSelection(JobProviderSelection(providerID: STTProviderID.parakeet, modelID: nil), for: .file)
        XCTAssertEqual(FileTranscriptionSettingsSnapshot.current().onDeviceEngineID, STTProviderID.parakeet)
        defaults.setSelection(.didunyCloud, for: .file)
        XCTAssertNil(FileTranscriptionSettingsSnapshot.current().onDeviceEngineID)
    }
}
