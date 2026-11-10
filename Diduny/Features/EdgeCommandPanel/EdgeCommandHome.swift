import Foundation

/// The engines each tile uses while the Engine picker is on "As in Settings" (Settings > Modes).
/// An input: today it is read from the per-job defaults; WP-13 replaces the source with `ModeDefaults`.
struct CommandHomeDefaults: Equatable {
    var dictation: EngineID
    var translation: EngineID
    /// Meeting "Starts in" and the engine of that segment.
    var meetingSegment: MeetingSegment
    var meetingEngine: EngineID
    var translateMeeting: EngineID

    /// The prototype's Modes defaults: all Diduny Cloud, meeting starts in Cloud.
    static let prototype = CommandHomeDefaults(
        dictation: .didunyCloud, translation: .didunyCloud,
        meetingSegment: .cloud, meetingEngine: .didunyCloud, translateMeeting: .didunyCloud
    )
}

extension EdgeCommandAction {
    /// `commandPanel.tile.<id>` (test-plan 2.1).
    var tileID: String {
        switch self {
        case .transcribe: "transcribe"
        case .translate: "translate"
        case .meeting: "recordMeeting"
        case .translateMeeting: "translateMeeting"
        case .batch: "batch"
        }
    }
}

/// What a tile hands to the recording entry point (plan 3.3).
struct CommandTileStart: Equatable {
    let action: EdgeCommandAction
    let engine: EngineID
    /// True when the engine came from the panel's session pick, not Settings.
    let isPick: Bool
    /// Record meeting only.
    let segment: MeetingSegment?
    /// Translate only: the Translate into language.
    let targetLanguage: String?
    /// Translate meeting only: the saved pair, both directions.
    let pair: TranslationLanguagePair?
}

/// Command home rules (02 sections 2 to 5, spec 7.4 to 7.6). Pure: capabilities and settings come in.
enum CommandHome {
    static let tiles: [EdgeCommandAction] = [.transcribe, .translate, .meeting, .translateMeeting]
    static let asInSettingsRowID = "asInSettings"
    static let providersRowID = "providers"
    /// The header "Settings" link: Settings > Modes (02 Q2).
    static let settingsSection = MainSection.modes
    static let fallbackTarget = "en"
    /// `PickerMenuModel.languageRowID` prefix.
    static let languageRowPrefix = "lang."

    /// Product names in the menus ("Whisper", not "Local Whisper").
    static func engineName(_ id: EngineID) -> String {
        switch id {
        case .didunyCloud: "Diduny Cloud"
        case .elevenLabs: "ElevenLabs"
        case .whisper: "Whisper"
        case .parakeet: "Parakeet V3"
        case .appleSpeech: "Apple Speech"
        }
    }

    /// The segment a picked engine opens Record meeting on (`cmdRec` P:594).
    static func segment(for caps: EngineCapabilities) -> MeetingSegment {
        if caps.traits.runsOn == .cloud { return .cloud }
        return caps.liveMeetingText == .none ? .recordOnly : .thisMac
    }

    static func engine(for action: EdgeCommandAction, pick: EngineID?, defaults: CommandHomeDefaults) -> EngineID {
        if let pick { return pick }
        switch action {
        case .transcribe, .batch: return defaults.dictation
        case .translate: return defaults.translation
        case .meeting: return defaults.meetingEngine
        case .translateMeeting: return defaults.translateMeeting
        }
    }

    static func start(
        _ action: EdgeCommandAction,
        pick: EngineID?,
        defaults: CommandHomeDefaults,
        target: String,
        pair: TranslationLanguagePair,
        caps: (EngineID) -> EngineCapabilities?
    ) -> CommandTileStart {
        let engine = engine(for: action, pick: pick, defaults: defaults)
        let segment: MeetingSegment? = action == .meeting
            ? (pick.flatMap(caps).map(segment(for:)) ?? defaults.meetingSegment)
            : nil
        return CommandTileStart(
            action: action,
            engine: engine,
            isPick: pick != nil,
            segment: segment,
            targetLanguage: action == .translate ? target : nil,
            pair: action == .translateMeeting ? pair : nil
        )
    }

    /// "Providers..." opens another window, so the pointer stays where it is.
    static func returnsPointer(afterPicking rowID: String) -> Bool {
        rowID != providersRowID
    }

    /// What a picked tile start runs for its job; nil when the tile follows Settings > Modes.
    static func panelSelection(_ start: CommandTileStart, job: STTJob) -> JobProviderSelection? {
        start.isPick ? ModeEngineRules.selection(engine: start.engine, job: job) : nil
    }

    // MARK: Captions (02 section 5)

    static func caption(
        for action: EdgeCommandAction,
        caps: EngineCapabilities?,
        target: String,
        pair: TranslationLanguagePair
    ) -> String {
        switch action {
        case .transcribe:
            String(localized: "Voice → text")
        case .translate:
            String(localized: "Voice → \(languageName(target))")
        case .meeting:
            String(localized: "System + mic")
        case .translateMeeting:
            caps?.meetingTranslation == .liveBothDirections
                ? String(localized: "Live · \(pairCodes(pair))")
                : String(localized: "After Stop · \(pairCodes(pair))")
        case .batch:
            ""
        }
    }

    /// "EN ↔ UK".
    static func pairCodes(_ pair: TranslationLanguagePair) -> String {
        "\(pair.languageA.uppercased()) ↔ \(pair.languageB.uppercased())"
    }

    static func languageName(_ code: String) -> String {
        SupportedLanguage.language(for: code)?.name ?? code.uppercased()
    }

    // MARK: Engine menu (02 section 3, spec 12.4)

    /// "As in Settings", Cloud, On this Mac, "Providers...". An engine that needs a key it has not got, or other
    /// hardware, has no row; one that cannot run for another reason is listed disabled with the reason.
    static func engineMenu(
        pick: EngineID?,
        caps: (EngineID) -> EngineCapabilities?,
        readiness: (EngineID) -> EngineReadiness
    ) -> PickerMenuModel {
        func rows(_ runsOn: EngineTraits.RunsOn) -> [PickerMenuRow] {
            EngineID.allCases.compactMap { id in
                guard let caps = caps(id), caps.traits.runsOn == runsOn else { return nil }
                let state = readiness(id)
                switch state {
                case .needsKey, .unsupportedHardware:
                    return nil
                case .ready, .signedOut, .notDownloaded:
                    // Signed out keeps every engine pickable (02 section 6).
                    let ready: EngineReadiness = state == .signedOut ? .ready : state
                    return PickerMenuRow(
                        id: id.rawValue, title: engineName(id),
                        subline: EngineCaptions.withNote(EngineCaptions.blurb(caps), caps: caps, readiness: ready)
                    )
                case .noQuota, .unavailable:
                    return PickerMenuRow(
                        id: id.rawValue, title: engineName(id), subline: reason(state), isEnabled: false
                    )
                }
            }
        }
        return PickerMenuModel(
            groups: [
                PickerMenuGroup(id: "asInSettings", rows: [
                    PickerMenuRow(
                        id: asInSettingsRowID, title: String(localized: "As in Settings"),
                        subline: String(localized: "Each mode uses its own default")
                    ),
                ]),
                PickerMenuGroup(id: "cloud", header: String(localized: "Cloud"), rows: rows(.cloud)),
                PickerMenuGroup(id: "onThisMac", header: String(localized: "On this Mac"), rows: rows(.thisMac)),
                PickerMenuGroup(id: "providers", rows: [
                    PickerMenuRow(
                        id: providersRowID, title: String(localized: "Providers..."),
                        subline: String(localized: "Compare engines, add a key")
                    ),
                ]),
            ],
            selectedID: pick?.rawValue ?? asInSettingsRowID,
            search: .never
        )
    }

    private static func reason(_ state: EngineReadiness) -> String {
        state == .noQuota ? String(localized: "Diduny quota used up") : String(localized: "Not on this Mac")
    }

    // MARK: Translate into (02 section 4)

    /// Every engine translates into the 60 Diduny Cloud languages (`trLangs` P:405).
    static var targetLanguages: [PickerMenuLanguage] {
        SupportedLanguage.cloudLanguages
            .map { PickerMenuLanguage(code: $0.code, name: $0.name) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func translateIntoMenu(target: String, yourLanguages: [String]) -> PickerMenuModel {
        .languages(targetLanguages, yours: yourLanguages, selectedCode: target)
    }

    /// The current target, or English when it is not one of the 60 (P:579).
    static func validTarget(_ code: String) -> String {
        targetLanguages.contains { $0.code == code } ? code : fallbackTarget
    }
}
