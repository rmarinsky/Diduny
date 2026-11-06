@testable import Diduny
import Testing

/// T3-CAP-01: the capability record of every engine equals the implementation-plan 3.1 table
/// (prototype `ENG` v9). One row per engine, so a failure names the engine.
struct EngineCapabilitiesTests {
    struct Row: CustomTestStringConvertible, Sendable {
        let id: EngineID
        let runsOn: EngineTraits.RunsOn
        let obtainedBy: EngineTraits.ObtainedBy
        let needs: [EngineTraits.Need]
        let recommended: EngineTraits.Recommended
        let liveDictation: LiveText
        let liveMeetingText: LiveText
        let speakerLabelsLive: Bool
        let speakerLabelsAfterStop: AfterStopLabels
        let dictationTranslation: DictationTranslation
        let meetingTranslation: MeetingTranslation
        let returnsOriginalWithTranslation: Bool

        var testDescription: String { id.rawValue }
    }

    static let table: [Row] = [
        Row(id: .didunyCloud, runsOn: .cloud, obtainedBy: .builtIn, needs: [.account], recommended: .none,
            liveDictation: .final, liveMeetingText: .final, speakerLabelsLive: true,
            speakerLabelsAfterStop: .yes(maxSpeakers: nil), dictationTranslation: .itself,
            meetingTranslation: .liveBothDirections, returnsOriginalWithTranslation: true),
        Row(id: .elevenLabs, runsOn: .cloud, obtainedBy: .ownKey, needs: [.ownKey], recommended: .none,
            liveDictation: .final, liveMeetingText: .final, speakerLabelsLive: false,
            speakerLabelsAfterStop: .yes(maxSpeakers: 32), dictationTranslation: .byDiduny,
            meetingTranslation: .afterStopIntoSecondLanguage, returnsOriginalWithTranslation: false),
        Row(id: .whisper, runsOn: .thisMac, obtainedBy: .download(bytes: 1_500_000_000), needs: [.download],
            recommended: .model(id: "ggml-large-v3-turbo"),
            liveDictation: .preview, liveMeetingText: .preview, speakerLabelsLive: false,
            speakerLabelsAfterStop: .none, dictationTranslation: .englishOnlyItselfPlusDiduny,
            meetingTranslation: .afterStopIntoSecondLanguage, returnsOriginalWithTranslation: false),
        Row(id: .parakeet, runsOn: .thisMac, obtainedBy: .download(bytes: 480_000_000), needs: [.download, .appleSilicon],
            recommended: .engine,
            liveDictation: .none, liveMeetingText: .none, speakerLabelsLive: false,
            speakerLabelsAfterStop: .none, dictationTranslation: .byDiduny,
            meetingTranslation: .afterStopIntoSecondLanguage, returnsOriginalWithTranslation: false),
        Row(id: .appleSpeech, runsOn: .thisMac, obtainedBy: .system, needs: [.macOSSpeech], recommended: .none,
            liveDictation: .final, liveMeetingText: .final, speakerLabelsLive: false,
            speakerLabelsAfterStop: .none, dictationTranslation: .byDiduny,
            meetingTranslation: .afterStopIntoSecondLanguage, returnsOriginalWithTranslation: false)
    ]

    static func capabilities(_ id: EngineID, whisper: WhisperModelManager.WhisperModel? = nil) throws -> EngineCapabilities {
        let module = try #require(ProviderRegistry.shared.module(id: id.rawValue))
        return try #require(EngineCapabilities.make(module, activeWhisperModel: whisper))
    }

    static func whisperModel(_ name: String) throws -> WhisperModelManager.WhisperModel {
        try #require(WhisperModelManager.availableModels.first { $0.name == name })
    }

    @Test("Every engine has a registry module and a record")
    func everyEngineHasARecord() throws {
        #expect(Self.table.map(\.id) == EngineID.allCases)
        for id in EngineID.allCases {
            #expect(try Self.capabilities(id).id == id)
        }
    }

    @Test("Capability record matches the design table", arguments: table)
    func recordMatchesTable(_ row: Row) throws {
        // Whisper's "English plus Diduny" needs a model that translates; Large v3 does.
        let caps = try Self.capabilities(row.id, whisper: Self.whisperModel("ggml-large-v3"))
        #expect(caps.traits.runsOn == row.runsOn)
        #expect(caps.traits.obtainedBy == row.obtainedBy)
        #expect(caps.traits.needs == row.needs)
        #expect(caps.traits.recommended == row.recommended)
        #expect(caps.liveDictation == row.liveDictation)
        #expect(caps.liveMeetingText == row.liveMeetingText)
        #expect(caps.speakerLabelsLive == row.speakerLabelsLive)
        #expect(caps.speakerLabelsAfterStop == row.speakerLabelsAfterStop)
        #expect(caps.dictationTranslation == row.dictationTranslation)
        #expect(caps.meetingTranslation == row.meetingTranslation)
        #expect(caps.returnsOriginalWithTranslation == row.returnsOriginalWithTranslation)
    }

    @Test("Bring-your-own-key matches how the engine is obtained", arguments: EngineID.allCases)
    func requiresKeyMatchesObtainedBy(_ id: EngineID) throws {
        let module = try #require(ProviderRegistry.shared.module(id: id.rawValue))
        let caps = try #require(EngineCapabilities.make(module, activeWhisperModel: nil))
        #expect(module.requiresKey == (caps.traits.obtainedBy == .ownKey))
    }

    static let whisperTranslation: [(String, Bool)] = [
        ("ggml-tiny", true), ("ggml-tiny.en", false),
        ("ggml-base", true), ("ggml-base.en", false),
        ("ggml-small", true), ("ggml-small.en", false),
        ("ggml-medium", true), ("ggml-medium.en", false),
        ("ggml-large-v2", true), ("ggml-large-v3", true),
        ("ggml-large-v3-turbo", false), ("ggml-large-v3-turbo-q5_0", false)
    ]

    @Test("Turbo and .en Whisper models do not translate into English", arguments: whisperTranslation)
    func whisperModelTranslation(_ name: String, _ translates: Bool) throws {
        let model = try Self.whisperModel(name)
        #expect(model.translatesToEnglish == translates)
        let caps = try Self.capabilities(.whisper, whisper: model)
        #expect(caps.dictationTranslation == (translates ? .englishOnlyItselfPlusDiduny : .byDiduny))
    }

    @Test("Without a Whisper model, Whisper does not claim to translate itself")
    func whisperWithoutModel() throws {
        #expect(try Self.capabilities(.whisper).dictationTranslation == .byDiduny)
    }

    @Test("A module that is not one of the five engines has no record")
    func unknownModuleHasNoRecord() {
        struct Unknown: STTProviderModule {
            let id = "unknown-engine"
            let displayName = "Unknown"
            let requiresKey = false
            let models: [STTModel] = []
            let traits = EngineTraits(runsOn: .cloud, obtainedBy: .builtIn, needs: [], recommended: .none, languages: .system)
        }
        #expect(EngineCapabilities.make(Unknown(), activeWhisperModel: nil) == nil)
    }

    @Test("Whisper download size comes from the catalog", arguments: WhisperModelManager.availableModels.map(\.name))
    func whisperCatalogSizes(_ name: String) throws {
        #expect(try Self.whisperModel(name).sizeBytes > 0)
    }

    @Test("Every Whisper model is in the translation table")
    func whisperTableCoversCatalog() {
        #expect(Set(Self.whisperTranslation.map(\.0)) == Set(WhisperModelManager.availableModels.map(\.name)))
    }

    @Test("Only Large v3 Turbo is the recommended Whisper model", arguments: WhisperModelManager.availableModels.map(\.name))
    func whisperRecommended(_ name: String) throws {
        #expect(try Self.whisperModel(name).isRecommended == (name == "ggml-large-v3-turbo"))
    }

    @Test("The active Whisper model does not change other engines", arguments: EngineID.allCases)
    func activeWhisperModelOnlyAffectsWhisper(_ id: EngineID) throws {
        let turbo = try Self.whisperModel("ggml-large-v3-turbo")
        let base = try Self.capabilities(id)
        let withTurbo = try Self.capabilities(id, whisper: turbo)
        if id == .whisper {
            #expect(withTurbo.dictationTranslation == .byDiduny)
        } else {
            #expect(withTurbo == base)
        }
    }
}
