@testable import Diduny
import Foundation
import Testing

/// WP-17 rule: each mode runs the same engine after the update as before. Every WP-13 migration fixture is
/// migrated, then routed by `RunTimeRouting`; the expectations are what today's build runs for that seed
/// (05 §4.3, inventory 4.3). Legacy keys stay on disk but are not read (T5-MIG-34).
@MainActor
@Suite("Run-time routing after the migration")
struct RunTimeRoutingTests {
    /// What a meeting runs today: segment, the engine that makes the text, Cloud/Local, Whisper preview,
    /// and the on-device engine that transcribes after Stop.
    struct Meeting: Equatable {
        var segment: MeetingSegment
        var engine: EngineID
        var provider: TranscriptionProvider
        var localPreview = false
        var afterStop: EngineID?
    }

    struct Today: CustomTestStringConvertible {
        let fixture: String
        var hasKey = false
        var appleSilicon = true
        let dictation: (EngineID, TranscriptionProvider)
        let translation: (EngineID, TranscriptionProvider)
        let meeting: Meeting
        var meetingTranslation: EngineID = .didunyCloud
        var file: EngineID = .whisper
        var testDescription: String { "\(fixture) key:\(hasKey) AS:\(appleSilicon)" }
    }

    static let cloudMeeting = Meeting(segment: .cloud, engine: .didunyCloud, provider: .cloud)

    static let personas: [Today] = [
        Today(fixture: "cloud-default", dictation: (.didunyCloud, .cloud), translation: (.didunyCloud, .cloud),
              meeting: cloudMeeting),
        Today(fixture: "local-whisper-preview-on", dictation: (.whisper, .local), translation: (.whisper, .local),
              meeting: Meeting(segment: .thisMac, engine: .whisper, provider: .local, localPreview: true)),
        Today(fixture: "local-whisper-preview-off", dictation: (.whisper, .local), translation: (.didunyCloud, .cloud),
              meeting: Meeting(segment: .recordOnly, engine: .whisper, provider: .local)),
        Today(fixture: "elevenlabs-meeting", hasKey: true, dictation: (.elevenLabs, .cloud), translation: (.didunyCloud, .cloud),
              meeting: Meeting(segment: .cloud, engine: .elevenLabs, provider: .cloud)),
        Today(fixture: "elevenlabs-meeting", dictation: (.didunyCloud, .cloud), translation: (.didunyCloud, .cloud),
              meeting: cloudMeeting),
        Today(fixture: "parakeet-meeting", dictation: (.didunyCloud, .cloud), translation: (.didunyCloud, .cloud),
              meeting: Meeting(segment: .recordOnly, engine: .parakeet, provider: .local, afterStop: .parakeet)),
        Today(fixture: "apple-meeting", dictation: (.didunyCloud, .cloud), translation: (.didunyCloud, .cloud),
              meeting: Meeting(segment: .thisMac, engine: .appleSpeech, provider: .local, afterStop: .appleSpeech),
              meetingTranslation: .appleSpeech),
        Today(fixture: "files-diduny-cloud", dictation: (.didunyCloud, .cloud), translation: (.didunyCloud, .cloud),
              meeting: cloudMeeting),
        Today(fixture: "files-unset", dictation: (.didunyCloud, .cloud), translation: (.didunyCloud, .cloud),
              meeting: cloudMeeting),
        Today(fixture: "cloud-default", appleSilicon: false, dictation: (.didunyCloud, .cloud),
              translation: (.didunyCloud, .cloud), meeting: cloudMeeting),
        // T5-MIG-36: legacy local translation stays Whisper on this Mac; meeting stays ElevenLabs live.
        Today(fixture: "roman-setup", hasKey: true, dictation: (.didunyCloud, .cloud), translation: (.whisper, .local),
              meeting: Meeting(segment: .cloud, engine: .elevenLabs, provider: .cloud)),
    ]

    func route(_ job: STTJob, _ defaults: UserDefaults, segment: MeetingSegment? = nil) -> RunTimeRoute {
        RunTimeRouting.route(job: job, segment: segment, defaults: ModeDefaults(defaults: defaults),
                             readiness: FakeEngineReadinessSource(), whisper: .init(downloaded: [], selected: nil),
                             signedIn: true)
    }

    @Test("Each mode routes to today's engine", arguments: personas)
    func personaRoutesToday(_ today: Today) throws {
        let (defaults, _) = try SettingsMigrationTests.load(today.fixture)
        SettingsMigrationTests.migrate(defaults, hasKey: today.hasKey, appleSilicon: today.appleSilicon)

        let dictation = route(.dictation, defaults)
        #expect(dictation.engine == today.dictation.0)
        #expect(dictation.baseProvider == today.dictation.1)
        let translation = route(.dictationTranslation, defaults)
        #expect(translation.engine == today.translation.0)
        #expect(translation.baseProvider == today.translation.1)

        let startsIn = ModeDefaults(defaults: defaults).meetingStartsIn
        let start = RunTimeRouting.meetingStart(segment: startsIn, route: route(.meeting, defaults, segment: startsIn))
        let meeting = Meeting(segment: start.segment, engine: start.runningEngine, provider: start.provider,
                              localPreview: start.localPreview, afterStop: start.afterStopEngineID.flatMap(EngineID.init(rawValue:)))
        #expect(meeting == today.meeting)

        #expect(route(.meetingTranslation, defaults).engine == today.meetingTranslation)
        #expect(route(.file, defaults).engine == today.file)
    }

    @Test("T5-MIG-34: changing a retired key after the migration does not change routing", arguments: personas)
    func retiredKeysIgnored(_ today: Today) throws {
        let (defaults, _) = try SettingsMigrationTests.load(today.fixture)
        SettingsMigrationTests.migrate(defaults, hasKey: today.hasKey, appleSilicon: today.appleSilicon)
        let before = [route(.dictation, defaults), route(.dictationTranslation, defaults), route(.meeting, defaults)]
        let flipped = defaults.string(forKey: "transcriptionProvider") == "local" ? "cloud" : "local"
        defaults.set(flipped, forKey: "transcriptionProvider")
        defaults.set(flipped, forKey: "translationProvider")
        defaults.set(!defaults.bool(forKey: "meetingRealtimeTranscriptionEnabled"), forKey: "meetingRealtimeTranscriptionEnabled")
        defaults.set(!defaults.bool(forKey: "meetingLocalLivePreviewEnabled"), forKey: "meetingLocalLivePreviewEnabled")
        #expect([route(.dictation, defaults), route(.dictationTranslation, defaults), route(.meeting, defaults)] == before)
    }

    @Test("Parakeet not downloaded: Record only falls back to Whisper and makes the text on this Mac")
    func parakeetFallback() throws {
        let (defaults, _) = try SettingsMigrationTests.load("parakeet-meeting")
        SettingsMigrationTests.migrate(defaults, hasKey: false, appleSilicon: true)
        let turbo = WhisperModelManager.WhisperModel.recommendedName
        let route = RunTimeRouting.route(job: .meeting, segment: .recordOnly, defaults: ModeDefaults(defaults: defaults),
                                         readiness: FakeEngineReadinessSource([.parakeet: .notDownloaded(bytes: 1)]),
                                         whisper: .init(downloaded: [turbo], selected: turbo), signedIn: true)
        let start = RunTimeRouting.meetingStart(segment: .recordOnly, route: route)
        #expect(start.runningEngine == .whisper)
        #expect(start.afterStopEngineID == nil)
        #expect(start.recordOnly && start.provider == .local)
    }

    @Test("A cloud engine in Record only keeps the audio on this Mac until WP-62")
    func recordOnlyCloudStaysLocal() {
        let start = RunTimeRouting.meetingStart(
            segment: .recordOnly,
            route: RunTimeRoute(engine: .didunyCloud, modelID: nil, unavailable: nil, baseProvider: .cloud)
        )
        #expect(start.provider == .local && start.recordOnly && !start.localPreview)
        #expect(start.runningEngine == .whisper)
    }

    @Test("Signed out: the Cloud persona runs Local, recovers on this Mac, and Turbo does not translate (bug 9)")
    func signedOutCloudPersona() throws {
        let (defaults, _) = try SettingsMigrationTests.load("cloud-default")
        SettingsMigrationTests.migrate(defaults, hasKey: false, appleSilicon: true)
        let modes = ModeDefaults(defaults: defaults)
        let fake = FakeEngineReadinessSource()
        for job in [STTJob.dictation, .dictationTranslation] {
            let route = RunTimeRouting.route(job: job, defaults: modes, readiness: fake,
                                             whisper: .init(downloaded: [], selected: nil), signedIn: false)
            #expect(route.engine == .didunyCloud && route.baseProvider == .local)
        }
        let start = RunTimeRouting.meetingStart(segment: .cloud, route: route(.meeting, defaults, segment: .cloud))
        #expect(start.recoversInCloud(signedIn: true))
        #expect(!start.recoversInCloud(signedIn: false))
        #expect(!JobRequest.whisperTranslationUsable(model: WhisperModelManager.WhisperModel.recommendedName, target: "en"))
    }

    @Test("Recovery: Record only, Parakeet and Apple meetings recover on this Mac")
    func recoveryStaysLocal() {
        let cloud = RunTimeRoute(engine: .didunyCloud, modelID: nil, unavailable: nil, baseProvider: .cloud)
        #expect(!RunTimeRouting.meetingStart(segment: .recordOnly, route: cloud).recoversInCloud(signedIn: true))
        for engine in [EngineID.parakeet, .appleSpeech] {
            let local = RunTimeRoute(engine: engine, modelID: nil, unavailable: nil, baseProvider: .cloud)
            for segment in MeetingSegment.allCases {
                #expect(!RunTimeRouting.meetingStart(segment: segment, route: local).recoversInCloud(signedIn: true))
            }
        }
        let whisper = RunTimeRoute(engine: .whisper, modelID: nil, unavailable: nil, baseProvider: .local)
        #expect(!RunTimeRouting.meetingStart(segment: .thisMac, route: whisper).recoversInCloud(signedIn: true))
    }

    @Test("An engine that cannot run refuses Start with the reason (ElevenLabs key removed)")
    func unavailableRefusesStart() throws {
        let defaults = try #require(UserDefaults(suiteName: "test.\(UUID().uuidString)"))
        let modes = ModeDefaults(defaults: defaults)
        modes.apply([.engine(.dictation, ModeEngineRules.selection(engine: .elevenLabs, job: .dictation))])
        let route = RunTimeRouting.route(job: .dictation, defaults: modes, readiness: FakeEngineReadinessSource([.elevenLabs: .needsKey]),
                                         whisper: .init(downloaded: [], selected: nil), signedIn: true)
        #expect(route.unavailable == .needsKey)
        #expect(RunTimeRouting.startError(route.unavailable, engine: route.engine)
            == String(localized: "The selected engine isn't available. Check Settings › Providers."))
        #expect(RunTimeRouting.startError(nil, engine: .didunyCloud) == nil)
        #expect(RunTimeRouting.startError(.notDownloaded(bytes: 1), engine: .parakeet) == OnDeviceEngines.notReadyMessage)
    }

    @Test("AppDelegate.modeRoute: a running meeting overrides Settings")
    func runningMeetingOverridesSettings() {
        let delegate = AppDelegate()
        delegate.activeMeetingStartRoute = MeetingStartRoute(segment: .recordOnly, engine: .parakeet, provider: .local,
                                                             recordOnly: true, localPreview: false,
                                                             afterStopEngineID: STTProviderID.parakeet)
        #expect(delegate.modeRoute(for: .meeting).engine == .parakeet)
        #expect(delegate.modeRoute(for: .meeting).baseProvider == .local)
        #expect(delegate.onDeviceSelection(for: .meeting) == STTProviderID.parakeet)
        delegate.activeMeetingStartRoute = nil
        #expect(delegate.meetingStartRoute(segment: .cloud).segment == .cloud)
    }

    @Test("Local translation without a capable model: Diduny step signed in, sign-in needed signed out")
    func localTranslationSteps() {
        let turbo = WhisperModelManager.WhisperModel.recommendedName
        #expect(RunTimeRouting.localTranslation(model: turbo, target: "en", signedIn: true) == .didunyStep)
        #expect(RunTimeRouting.localTranslation(model: turbo, target: "en", signedIn: false) == .signInNeeded)
        #expect(RunTimeRouting.localTranslation(model: "ggml-large-v3", target: "uk", signedIn: true) == .didunyStep)
        #expect(RunTimeRouting.localTranslation(model: "ggml-large-v3", target: "en", signedIn: false) == .whisper)
    }

    @Test("Translate meeting recovery uses the saved target")
    func meetingTranslationRecoveryTarget() {
        let pair = TranslationLanguagePair(languageA: "en", languageB: "uk")
        #expect(RunTimeRouting.meetingTranslationRecoveryTarget(saved: "pl", pair: pair) == "pl")
        #expect(RunTimeRouting.meetingTranslationRecoveryTarget(saved: nil, pair: pair) == "uk")
    }
}
