@testable import Diduny
import Foundation
import Testing

/// Settings > Modes model (05 2.1, test-plan 4.5 T5-MD-*, T5-ALL-01/02).
@MainActor
struct ModesViewModelTests {
    final class FakeSource: ModesSettingsSource {
        var engines: [STTJob: EngineID] = [
            .dictation: .didunyCloud, .dictationTranslation: .didunyCloud, .meetingTranslation: .didunyCloud, .file: .parakeet,
        ]
        var segments: [MeetingSegment: EngineID] = [.thisMac: .whisper, .cloud: .didunyCloud, .recordOnly: .parakeet]
        var meetingStartsIn: MeetingSegment = .cloud
        var dictationTranslationTarget = "en"
        var yourLanguages = ["en", "uk"]
        var pair: TranslationLanguagePair? = .defaultPair
        var translationPair: TranslationLanguagePair? { pair }
        var offeredTranslationPairs = [TranslationLanguagePair.defaultPair]
        var meetingTranslationShowOriginal = false
        var meetingSuggestionsEnabled = true
        var ptt: [STTJob: ModePushToTalk] = [
            .dictation: ModePushToTalk(key: .rightShift, toggleEnabled: true, tapCount: 2, holdEnabled: false, holdDelaySeconds: 1.2),
            .dictationTranslation: ModePushToTalk(key: .rightOption, toggleEnabled: true, tapCount: 2, holdEnabled: false, holdDelaySeconds: 1.2),
        ]
        var silences: [STTJob: ModeSilence] = [:]
        var counts: [STTJob: Int] = [:]

        func engine(for job: STTJob) -> EngineID { engines[job] ?? .didunyCloud }
        func setEngine(_ engine: EngineID, for job: STTJob) { engines[job] = engine }
        func meetingEngine(for segment: MeetingSegment) -> EngineID { segments[segment]! }
        func setMeetingEngine(_ engine: EngineID, for segment: MeetingSegment) { segments[segment] = engine }
        func selectTranslationPair(_ pair: TranslationLanguagePair) { self.pair = pair }
        func pushToTalk(for job: STTJob) -> ModePushToTalk { ptt[job]! }
        func setPushToTalk(_ value: ModePushToTalk, for job: STTJob) { ptt[job] = value }
        func silence(for job: STTJob) -> ModeSilence {
            silences[job] ?? ModeSilence(enabled: true, seconds: job == .meeting || job == .meetingTranslation ? 60 : 5)
        }
        func setSilence(_ value: ModeSilence, for job: STTJob) { silences[job] = value }
        func pressCount(for job: STTJob) -> Int { counts[job] ?? 1 }
        func setPressCount(_ count: Int, for job: STTJob) { counts[job] = count }
    }

    static func allCaps() throws -> [EngineCapabilities] {
        try EngineID.allCases.map { try EngineCapabilitiesTests.capabilities($0) }
    }

    func model(
        _ source: FakeSource? = nil,
        readiness: [EngineID: EngineReadiness] = [:],
        signedIn: Bool = true
    ) throws -> ModesViewModel {
        try ModesViewModel(
            source: source ?? FakeSource(),
            readiness: FakeEngineReadinessSource(readiness),
            engines: Self.allCaps(),
            isSignedIn: { signedIn }
        )
    }

    private func rows(_ menu: PickerMenuModel) -> [[String]] {
        menu.groups.map { $0.rows.map(\.id) }
    }

    // MARK: Offered engines

    @Test("T5-MD-01: each row and segment offers only its engines; ElevenLabs only with a key")
    func offeredEngines() throws {
        let withKey = try model()
        let cloud = ["diduny-cloud", "elevenlabs"], local = ["local-whisper", "parakeet-v3", "apple-speech"]
        for job in [STTJob.dictation, .dictationTranslation, .meetingTranslation] {
            #expect(rows(withKey.engineMenu(job: job, segment: nil)) == [cloud, local])
        }
        #expect(rows(withKey.engineMenu(job: .file, segment: nil)) == [local])
        #expect(rows(withKey.engineMenu(job: .meeting, segment: .thisMac)) == [["local-whisper", "apple-speech"]])
        #expect(rows(withKey.engineMenu(job: .meeting, segment: .cloud)) == [cloud])
        let recordOnly = withKey.engineMenu(job: .meeting, segment: .recordOnly)
        #expect(rows(recordOnly) == [local, cloud])
        #expect(recordOnly.groups.map(\.header) == ["On this Mac, recommended", "Cloud"])

        let noKey = try model(readiness: [.elevenLabs: .needsKey])
        #expect(rows(noKey.engineMenu(job: .dictation, segment: nil)) == [["diduny-cloud"], local])
        // T5-MD-16: one engine left in the Cloud segment draws a static field.
        #expect(noKey.isStatic(job: .meeting, segment: .cloud))
        #expect(!withKey.isStatic(job: .meeting, segment: .cloud))
    }

    @Test("Parakeet on an Intel Mac is hidden; not downloaded is listed with its size")
    func readinessInMenus() throws {
        let intel = try model(readiness: [.parakeet: .unsupportedHardware])
        #expect(rows(intel.engineMenu(job: .file, segment: nil)) == [["local-whisper", "apple-speech"]])
        let missing = try model(readiness: [.parakeet: .notDownloaded(bytes: 480_000_000)])
        let row = try #require(missing.engineMenu(job: .file, segment: nil).groups[0].rows.first { $0.id == "parakeet-v3" })
        #expect(row.isEnabled)
        #expect(row.subline?.hasPrefix("Not downloaded, ") == true)
    }

    // MARK: Meeting row

    @Test("T5-MD-05: the Meeting row engine edits the Starts in segment")
    func meetingRowEditsSegment() throws {
        let source = FakeSource()
        let modes = try model(source)
        modes.pickEngine("elevenlabs", job: .meeting)
        modes.pickStartsIn("thisMac")
        modes.pickEngine("apple-speech", job: .meeting)
        #expect(source.segments == [.cloud: .elevenLabs, .thisMac: .appleSpeech, .recordOnly: .parakeet])
        #expect(modes.meetingEngine(for: .cloud) == .elevenLabs)
        #expect(modes.engine(for: .meeting) == .appleSpeech)
        #expect(modes.caption(for: .meeting) == "Live text · no speaker labels")
    }

    // MARK: Use one engine for everything

    @Test("T5-ALL-01: the write rule, Meeting segment table and Files kept for cloud engines",
          arguments: [
              (EngineID.didunyCloud, MeetingSegment.cloud),
              (.elevenLabs, .cloud),
              (.whisper, .thisMac),
              (.appleSpeech, .thisMac),
              (.parakeet, .recordOnly),
          ])
    func uniformWrite(engine: EngineID, segment: MeetingSegment) throws {
        let source = FakeSource()
        source.engines[.file] = .appleSpeech
        source.dictationTranslationTarget = "pl"
        let modes = try model(source)
        modes.pickUniformEngine(engine.rawValue)

        for job in [STTJob.dictation, .dictationTranslation, .meetingTranslation] {
            #expect(source.engines[job] == engine)
        }
        let local = engine == .whisper || engine == .parakeet || engine == .appleSpeech
        #expect(source.engines[.file] == (local ? engine : .appleSpeech))
        #expect(source.meetingStartsIn == segment)
        #expect(source.segments[segment] == engine)
        let defaults: [MeetingSegment: EngineID] = [.thisMac: .whisper, .cloud: .didunyCloud, .recordOnly: .parakeet]
        for other in MeetingSegment.allCases where other != segment {
            #expect(source.segments[other] == defaults[other])
        }
        #expect(source.dictationTranslationTarget == "pl")
        #expect(source.pair == .defaultPair)
        #expect(modes.uniformEngine == engine)
    }

    @Test("T5-ALL-02: one engine, or Different per mode with no selected row")
    func uniformValue() throws {
        let modes = try model()
        modes.pickUniformEngine("diduny-cloud")
        #expect(modes.uniformEngineValue == "Diduny Cloud")
        #expect(modes.uniformEngineMenu().selectedID == "diduny-cloud")
        modes.pickEngine("local-whisper", job: .dictation)
        #expect(modes.uniformEngine == nil)
        #expect(modes.uniformEngineValue == "Different per mode")
        #expect(modes.uniformEngineMenu().selectedID == nil)
    }

    @Test("T5-MD-08: fresh defaults read as the prototype")
    func freshDefaults() throws {
        let modes = try model()
        #expect(modes.engine(for: .dictation) == .didunyCloud)
        #expect(modes.intoValue == "English")
        #expect(modes.startsInValue == "Cloud")
        #expect(modes.betweenValue == "EN ↔ UK")
        #expect(modes.engine(for: .file) == .parakeet)
        #expect(modes.engineName(.whisper) == "Whisper")
        #expect(ModesViewModel.jobs.allSatisfy { modes.pressCount(for: $0) == 1 })
    }

    // MARK: Second pickers

    @Test("T5-MD-06: Into lists the Cloud languages, yours first, with search")
    func intoMenu() throws {
        let modes = try model()
        let menu = modes.intoMenu()
        #expect(menu.groups.first?.isYours == true)
        #expect(menu.groups.first?.rows.map(\.id) == ["lang.en", "lang.uk"])
        #expect(menu.groups.reduce(0) { $0 + $1.rows.count } == SupportedLanguage.cloudLanguages.count)
        #expect(menu.showsSearch)
        modes.pickInto("lang.pl")
        #expect(modes.intoValue == "Polish")
    }

    @Test("Between lists the pairs in full names, then Other languages")
    func betweenMenu() throws {
        let source = FakeSource()
        let enPl = TranslationLanguagePair(languageA: "en", languageB: "pl")
        source.offeredTranslationPairs = [.defaultPair, enPl]
        let modes = try model(source)
        let menu = modes.betweenMenu()
        #expect(menu.groups[0].rows.map(\.title) == ["English ↔ Ukrainian", "English ↔ Polish"])
        #expect(menu.selectedID == TranslationLanguagePair.defaultPair.id)
        #expect(menu.groups[1].rows.map(\.id) == [ModesViewModel.otherPairRowID])
        #expect(modes.pickBetween(enPl.id))
        #expect(modes.betweenValue == "EN ↔ PL")
        #expect(!modes.pickBetween(ModesViewModel.otherPairRowID))
    }

    // MARK: Expanders

    @Test("T5-MD-09: one expander open at a time; Files has none")
    func oneExpander() throws {
        let modes = try model()
        modes.toggleExpander(.dictation)
        #expect(modes.expandedJob == .dictation)
        modes.toggleExpander(.meeting)
        #expect(modes.expandedJob == .meeting)
        modes.toggleExpander(.meeting)
        #expect(modes.expandedJob == nil)
        modes.toggleExpander(.file)
        #expect(modes.expandedJob == nil)
    }

    @Test("WP-51: the Calendar & meetings link opens Modes with Meeting expanded; Files has none")
    func expandFromLink() throws {
        let modes = try model()
        modes.toggleExpander(.dictation)
        modes.expand(.meeting)
        #expect(modes.expandedJob == .meeting)
        modes.expand(.meeting)
        #expect(modes.expandedJob == .meeting)
        modes.expand(.file)
        #expect(modes.expandedJob == .meeting)
    }

    @Test("T5-MD-11: Tap to start and stop writes the switch and the count")
    func tapSelection() throws {
        let source = FakeSource()
        let modes = try model(source)
        for job in [STTJob.dictation, .dictationTranslation] {
            modes.setTapSelection(0, for: job)
            #expect(source.ptt[job]?.toggleEnabled == false)
            #expect(modes.tapSelection(for: job) == 0)
            modes.setTapSelection(2, for: job)
            #expect(source.ptt[job]?.toggleEnabled == true && source.ptt[job]?.tapCount == 2)
            modes.setTapSelection(3, for: job)
            #expect(source.ptt[job]?.tapCount == 3)
        }
    }

    @Test("T5-MD-12: Hold for rounds to 0.1 s and labels in seconds", arguments: [(0.5, 0.5, "0.5 s"), (1.23, 1.2, "1.2 s"), (2.0, 2.0, "2.0 s")])
    func holdFor(input: Double, stored: Double, label: String) throws {
        let source = FakeSource()
        let modes = try model(source)
        modes.updatePushToTalk(for: .dictation) { $0.holdDelaySeconds = input }
        #expect(source.ptt[.dictation]?.holdDelaySeconds == stored)
        #expect(modes.holdForLabel(stored) == label)
    }

    @Test("T5-MD-13: silence menus; a stored value outside them is added, not changed")
    func silenceMenus() throws {
        let source = FakeSource()
        let modes = try model(source)
        #expect(modes.silenceOptions(for: .dictation) == [3, 5, 10])
        #expect(modes.silenceOptions(for: .meeting) == [30, 60, 120])
        source.silences[.dictation] = ModeSilence(enabled: true, seconds: 7)
        source.silences[.meeting] = ModeSilence(enabled: true, seconds: 90)
        modes.reload()
        #expect(modes.silenceOptions(for: .dictation) == [3, 5, 7, 10])
        #expect(modes.silenceOptions(for: .meeting) == [30, 60, 90, 120])
    }

    @Test("T5-MD-15: the signed-out notice shows only when signed out")
    func signedOutNotice() throws {
        #expect(try model(signedIn: false).showsSignedOutNotice)
        #expect(try !model(signedIn: true).showsSignedOutNotice)
    }

    @Test("T5-MD-17: both Option keys taken blocks in-place translation")
    func pttConflict() throws {
        let source = FakeSource()
        let modes = try model(source)
        #expect(!modes.blocksInplaceTranslation())
        modes.updatePushToTalk(for: .dictation) { $0.key = .leftOption }
        #expect(modes.blocksInplaceTranslation())
    }

    @Test("T5-MD-18: Parakeet missing warns under Files and under Meeting's Record only")
    func parakeetWarning() throws {
        let missing = try model(readiness: [.parakeet: .notDownloaded(bytes: 480_000_000)])
        #expect(missing.notDownloadedBytes(for: .file) == 480_000_000)
        #expect(missing.notDownloadedBytes(for: .meeting) == 480_000_000)
        #expect(missing.notDownloadedBytes(for: .dictation) == nil)
        #expect(missing.downloadLinkTitle(bytes: 480_000_000, locale: Locale(identifier: "en_US")) == "Download 480 MB")
        #expect(try model().notDownloadedBytes(for: .file) == nil)
    }
}

/// The interim live adapter over `SettingsStorage` (until WP-13 `ModeDefaults`).
@MainActor
struct LiveModesSettingsSourceTests {
    func storage() throws -> SettingsStorage {
        let name = "LiveModesSettingsSourceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        return SettingsStorage(defaults: defaults)
    }

    @Test("T5-MD-10: expander defaults on a new install")
    func newInstallDefaults() throws {
        let storage = try storage()
        storage.applyNewUserDefaultsIfMissing()
        let source = LiveModesSettingsSource(storage: storage, notifications: NotificationCenter())
        #expect(source.pushToTalk(for: .dictation) == ModePushToTalk(key: .rightShift, toggleEnabled: true, tapCount: 2, holdEnabled: false, holdDelaySeconds: 1.2))
        #expect(source.pushToTalk(for: .dictationTranslation) == ModePushToTalk(key: .rightOption, toggleEnabled: true, tapCount: 2, holdEnabled: false, holdDelaySeconds: 1.2))
        #expect(source.silence(for: .dictation) == ModeSilence(enabled: true, seconds: 5))
        #expect(source.silence(for: .meeting) == ModeSilence(enabled: true, seconds: 60))
        #expect(source.meetingSuggestionsEnabled)
        #expect(source.engine(for: .file) == .parakeet)
        #expect(source.meetingStartsIn == .cloud)
        #expect(source.meetingEngine(for: .recordOnly) == .parakeet)
    }

    @Test("T5-MD-11: Off and 2x write the two push-to-talk keys")
    func tapWritesTwoKeys() throws {
        let storage = try storage()
        let source = LiveModesSettingsSource(storage: storage, notifications: NotificationCenter())
        var value = source.pushToTalk(for: .dictationTranslation)
        value.toggleEnabled = false
        source.setPushToTalk(value, for: .dictationTranslation)
        #expect(!storage.translationPushToTalkToggleEnabled)
        value.toggleEnabled = true
        value.tapCount = 3
        source.setPushToTalk(value, for: .dictationTranslation)
        #expect(storage.translationPushToTalkToggleEnabled && storage.translationPushToTalkToggleTapCount == 3)
    }

    @Test("Meeting picks write only the new keys (WP-17: the legacy Cloud/Local keys stop being written)")
    func meetingWritesNewKeys() throws {
        let storage = try storage()
        let source = LiveModesSettingsSource(storage: storage, notifications: NotificationCenter())
        source.meetingStartsIn = .thisMac
        #expect(storage.defaults.string(forKey: "meetingTranscriptMode") == "thisMac")
        source.setMeetingEngine(.didunyCloud, for: .recordOnly)
        source.meetingStartsIn = .recordOnly
        #expect(source.meetingEngine(for: .recordOnly) == .didunyCloud)
        #expect(storage.defaults.data(forKey: "sttJobDefault.meeting.recordOnly") != nil)
        source.setMeetingEngine(.elevenLabs, for: .cloud)
        #expect(storage.modeDefaults.selection(for: .cloud).modelID == ElevenLabsProvider.realtimeModelID)
        for key in ["meetingRealtimeTranscriptionEnabled", "meetingLocalLivePreviewEnabled", "sttJobDefault.meeting"] {
            #expect(storage.defaults.object(forKey: key) == nil, "\(key)")
        }
    }

    @Test("Engine picks write ModeDefaults, not transcriptionProvider; Files never reads a cloud engine")
    func jobEngines() throws {
        let storage = try storage()
        let source = LiveModesSettingsSource(storage: storage, notifications: NotificationCenter())
        source.setEngine(.whisper, for: .dictation)
        #expect(storage.defaults.object(forKey: "transcriptionProvider") == nil)
        #expect(storage.modeDefaults.engine(for: .dictation) == .whisper)
        #expect(source.engine(for: .dictation) == .whisper)
        source.setEngine(.appleSpeech, for: .file)
        #expect(source.engine(for: .file) == .appleSpeech)
        storage.providerDefaults.setSelection(.didunyCloud, for: .file)
        #expect(source.engine(for: .file) == .whisper)
    }

    @Test("Stop after silence: each mode has its own two keys (05 Q5)")
    func silenceFourKeys() throws {
        let storage = try storage()
        let source = LiveModesSettingsSource(storage: storage, notifications: NotificationCenter())
        source.setSilence(ModeSilence(enabled: false, seconds: 3), for: .dictationTranslation)
        source.setSilence(ModeSilence(enabled: true, seconds: 120), for: .meetingTranslation)
        #expect(!storage.translationSilenceAutoStopEnabled && storage.translationSilenceAutoStopSeconds == 3)
        #expect(storage.meetingTranslationSilenceAutoStopEnabled && storage.meetingTranslationSilenceAutoStopSeconds == 120)
        #expect(storage.defaults.object(forKey: "dictationSilenceAutoStopEnabled") == nil)
        #expect(storage.defaults.object(forKey: "meetingSilenceAutoStopSeconds") == nil)
        #expect(source.silence(for: .dictationTranslation) == storage.silenceAutoStop(for: .dictationTranslation))
        #expect(storage.silenceAutoStop(for: .meetingTranslation) == ModeSilence(enabled: true, seconds: 120))
    }
}
