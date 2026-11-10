import Foundation

/// An engine the Translate meeting Engine menu may offer, with whether it can run now.
struct TranslateMeetingEngineOption: Equatable {
    let caps: EngineCapabilities
    let name: String
    var readiness: EngineReadiness = .ready
}

/// What the Translate meeting live panel shows (design-spec 7.3, 12.3; 01 section 3). Pure: the
/// live panel shell (WP-30) passes the session's pair, engine and Your languages in.
struct TranslateMeetingPanelModel: Equatable {
    enum RowID {
        static let otherLanguages = "otherLanguages"
        static func pair(_ pair: TranslationLanguagePair) -> String { "pair.\(pair.languageA)-\(pair.languageB)" }
    }

    let pair: TranslationLanguagePair
    /// Pairs made from Your languages (`YourLanguages.offeredPairs(stored:)`); empty with fewer than two.
    let offeredPairs: [TranslationLanguagePair]
    let engine: TranslateMeetingEngineOption
    let engines: [TranslateMeetingEngineOption]
    var locale: Locale = EngineLanguages.appLocale

    var isLive: Bool { EngineCaptions.translateMeetingIsLive(engine.caps) }

    /// "Show original text" exists only with live text (Diduny Cloud).
    var showsOriginalLink: Bool { isLive }

    var caption: String {
        EngineCaptions.translateMeetingPanelCaption(caps: engine.caps, pair: pair, locale: locale)
    }

    var calmDetail: String? {
        EngineCaptions.translateMeetingCalmDetail(caps: engine.caps, engineName: engine.name, pair: pair, locale: locale)
    }

    /// Status line without live text; nil while live (the shell shows the connection status with its dot).
    var notLiveStatus: String? {
        isLive ? nil : EngineCaptions.translateMeetingNotLiveStatus
    }

    /// `pairMenu` (Proto:441-443): the pairs in full names, then "Other languages...". No search.
    var betweenMenu: PickerMenuModel {
        PickerMenuModel(
            groups: [
                PickerMenuGroup(
                    id: "pairs",
                    header: String(localized: "Both directions, between your languages"),
                    rows: offeredPairs.map { PickerMenuRow(id: RowID.pair($0), title: $0.fullName(locale: locale)) }
                ),
                PickerMenuGroup(id: "other", rows: [
                    PickerMenuRow(
                        id: RowID.otherLanguages,
                        title: String(localized: "Other languages..."),
                        subline: String(localized: "Add them to Your languages in Settings")
                    ),
                ]),
            ],
            selectedID: offeredPairs.first { $0.hasSameLanguages(as: pair) }.map(RowID.pair),
            search: .never
        )
    }

    /// Engine menu (`engineItems` with `tSub`): "Cloud" then "On this Mac"; hidden and disabled per 12.4.
    var engineMenu: PickerMenuModel {
        let rows = { (runsOn: EngineTraits.RunsOn) in
            engines.filter { $0.caps.traits.runsOn == runsOn }.compactMap(Self.row)
        }
        return PickerMenuModel(
            groups: [
                PickerMenuGroup(id: "cloud", header: String(localized: "Cloud"), rows: rows(.cloud)),
                PickerMenuGroup(id: "thisMac", header: String(localized: "On this Mac"), rows: rows(.thisMac)),
            ],
            selectedID: engine.caps.id.rawValue,
            search: .never
        )
    }

    /// The offered pair a Between row stands for; nil for "Other languages..." and unknown ids.
    func pair(forRowID id: String) -> TranslationLanguagePair? {
        offeredPairs.first { RowID.pair($0) == id }
    }

    private static func row(_ option: TranslateMeetingEngineOption) -> PickerMenuRow? {
        let id = option.caps.id.rawValue
        switch option.readiness {
        case .needsKey, .unsupportedHardware:
            return nil
        case .ready, .notDownloaded:
            let subline = EngineCaptions.menuSubline(job: .meetingTranslation, caps: option.caps, readiness: option.readiness)
            return PickerMenuRow(id: id, title: option.name, subline: subline)
        case .signedOut:
            return PickerMenuRow(id: id, title: option.name, subline: String(localized: "Sign in to use"), isEnabled: false)
        case .noQuota:
            return PickerMenuRow(id: id, title: option.name, subline: String(localized: "Diduny quota used up"), isEnabled: false)
        case .unavailable:
            return PickerMenuRow(id: id, title: option.name, subline: String(localized: "Not available"), isEnabled: false)
        }
    }
}
