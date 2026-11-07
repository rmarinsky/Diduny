import Foundation

/// The engine of the running session and what it can do in this session (N6, N18). `caps` is the
/// effective record: an ElevenLabs model planned for after Stop shows the no-live rows (01 §4 states).
struct LiveSessionEngine: Equatable {
    let id: EngineID
    let caps: EngineCapabilities

    /// Product names as the panels show them (design-spec 8.1); not localized.
    var name: String {
        switch id {
        case .didunyCloud: "Diduny Cloud"
        case .elevenLabs: "ElevenLabs"
        case .whisper: "Whisper"
        case .parakeet: "Parakeet V3"
        case .appleSpeech: "Apple Speech"
        }
    }

    var hasLiveText: Bool {
        caps.liveDictation != .none
    }

    /// The record of `id` from the registry. `liveOverride` replaces the live text kind, for a model
    /// planned for after Stop. Nil when the registry has no such engine.
    static func make(
        _ id: EngineID,
        liveOverride: LiveText? = nil,
        registry: ProviderRegistry = .shared
    ) -> LiveSessionEngine? {
        guard let module = registry.module(id: id.rawValue),
              let caps = EngineCapabilities.make(module, activeWhisperModel: nil) else { return nil }
        guard let liveOverride else { return LiveSessionEngine(id: id, caps: caps) }
        return LiveSessionEngine(id: id, caps: EngineCapabilities(
            id: caps.id,
            traits: caps.traits,
            liveDictation: liveOverride,
            liveMeetingText: liveOverride,
            speakerLabelsLive: liveOverride == .none ? false : caps.speakerLabelsLive,
            speakerLabelsAfterStop: caps.speakerLabelsAfterStop,
            dictationTranslation: liveOverride == .none && caps.dictationTranslation == .itself
                ? .byDiduny : caps.dictationTranslation,
            meetingTranslation: caps.meetingTranslation,
            returnsOriginalWithTranslation: caps.returnsOriginalWithTranslation
        ))
    }

    /// The engine the session runs (`RunTimeRoute`, fixed at start until WP-64). ElevenLabs follows its
    /// model: no realtime capability means after Stop.
    @MainActor
    static func running(_ selection: JobProviderSelection) -> LiveSessionEngine? {
        let id = EngineID(rawValue: selection.providerID) ?? .didunyCloud
        guard id == .elevenLabs, let module = ProviderRegistry.shared.module(id: id.rawValue) else { return make(id) }
        let model = module.models.first { $0.id == selection.modelID } ?? module.models.first
        return make(id, liveOverride: model?.capabilities.realtime?.liveQuality ?? LiveText.none)
    }
}

/// What the live panel shell and the dictation content show, derived from the store (spec 7.2, 4.7,
/// 01 §1 and §4). Pure, so it is unit tested; WP-31 and WP-32 add their mode's rows here.
struct LivePanelState: Equatable {
    enum Status: Equatable {
        /// Accent dot, `text`.
        case live(String)
        /// `secondary`, no dot.
        case plain(String)
        case error(String)
    }

    enum Body: Equatable {
        case transcript
        case calm(title: String, detail: String)
    }

    let title: String
    let icon: String
    let status: Status
    /// Under the row; nil for modes that do not build one yet.
    let caption: String?
    let body: Body
    let isCopyEnabled: Bool
    /// After Stop the controls row becomes the progress row with this line (M3).
    let progressLine: String?

    init(
        mode: RecordingMode,
        phase: LiveDictationOverlayPhase,
        connectionStatus: RealtimeConnectionStatus,
        engine: LiveSessionEngine?,
        output: DictationOutput,
        hasText: Bool
    ) {
        let translating = output != .original
        let isDictation = !mode.isMeeting
        let live = engine?.hasLiveText ?? true

        title = Self.title(mode: mode, translating: translating)
        icon = isDictation ? (translating ? "globe" : "mic") : mode.icon
        status = Self.status(phase: phase, connection: connectionStatus, live: live)

        if isDictation, let engine {
            caption = EngineCaptions.dictationPanelCaption(translating: translating, caps: engine.caps)
        } else {
            caption = nil
        }

        if isDictation, let engine, !engine.hasLiveText, phase != .pasted {
            body = .calm(
                title: String(localized: "Recording"),
                detail: String(localized: "No live text with \(engine.name). The text is pasted after Stop.")
            )
        } else {
            body = .transcript
        }

        isCopyEnabled = hasText && body == .transcript

        progressLine = switch phase {
        case .finalizing, .processing:
            mode.isMeeting
                ? String(localized: "Saving the recording...")
                : String(localized: "Finishing the last words...")
        default:
            nil
        }
    }

    private static func title(mode: RecordingMode, translating: Bool) -> String {
        switch mode {
        case .voice, .translation:
            translating ? String(localized: "Translating") : String(localized: "Dictating")
        case .meeting:
            String(localized: "Recording meeting")
        case .meetingTranslation:
            String(localized: "Translating meeting")
        case .fileTranscription:
            String(localized: "File Transcription")
        }
    }

    private static func status(
        phase: LiveDictationOverlayPhase,
        connection: RealtimeConnectionStatus,
        live: Bool
    ) -> Status {
        switch phase {
        case .starting:
            return .plain(String(localized: "Starting"))
        case .recording:
            // 01 Q18 default: an engine without live text says so instead of a connection state.
            guard live else { return .plain(String(localized: "Recording · no live text")) }
            return switch connection {
            case .connected: .live(String(localized: "Recording live"))
            case .connecting: .plain(String(localized: "Connecting"))
            case .reconnecting: .plain(String(localized: "Reconnecting"))
            case .failed: .plain(String(localized: "Recording offline"))
            case .disconnected: .plain(String(localized: "Recording"))
            }
        case .finalizing:
            return .plain(String(localized: "Finalizing"))
        case .processing:
            return .plain(String(localized: "Formatting"))
        case .pasted:
            return .plain(String(localized: "Complete"))
        case let .error(message):
            return .error(message)
        case let .info(message):
            return .plain(message)
        }
    }
}

/// The Output menu (01 §4 item 3): "Original", then "Translate into: your languages", then the other
/// Diduny languages alphabetically. The same for every engine. Row ids `original` and `lang.<code>`.
enum DictationOutputMenu {
    static let originalRowID = "original"

    static func model(yourLanguages: [String], selected: DictationOutput) -> PickerMenuModel {
        let all = SupportedLanguage.cloudLanguages
        let yours = yourLanguages.compactMap { code in all.first { $0.code == code } }
        let row = { (language: SupportedLanguage) in
            PickerMenuRow(id: PickerMenuModel.languageRowID(language.code), title: language.name)
        }
        let groups = [
            PickerMenuGroup(id: "original", rows: [
                PickerMenuRow(
                    id: originalRowID,
                    title: String(localized: "Original"),
                    subline: String(localized: "Your words, no translation")
                )
            ]),
            PickerMenuGroup(
                id: "yourLanguages", header: String(localized: "Translate into: your languages"),
                isYours: true, rows: yours.map(row)
            ),
            PickerMenuGroup(
                id: "allLanguages", header: PickerMenuModel.allLanguagesTitle,
                rows: all.filter { language in !yours.contains(language) }
                    .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                    .map(row)
            ),
        ]
        return PickerMenuModel(groups: groups, selectedID: rowID(selected), search: .always)
    }

    /// Outputs in menu order, for tests and callers that list them.
    static func outputs(yourLanguages: [String]) -> [DictationOutput] {
        model(yourLanguages: yourLanguages, selected: .original).groups
            .flatMap(\.rows)
            .compactMap { output(forRowID: $0.id) }
    }

    static func rowID(_ output: DictationOutput) -> String {
        output.targetLanguage.map(PickerMenuModel.languageRowID) ?? originalRowID
    }

    static func output(forRowID id: String) -> DictationOutput? {
        if id == originalRowID { return .original }
        let prefix = PickerMenuModel.languageRowID("")
        guard id.hasPrefix(prefix) else { return nil }
        return .translation(targetLanguage: String(id.dropFirst(prefix.count)))
    }
}
