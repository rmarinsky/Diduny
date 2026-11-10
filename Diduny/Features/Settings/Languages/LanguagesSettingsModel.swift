import Foundation
import Observation

/// The two lists the Change popup edits (05 §2.3).
enum LanguageChangeList: String, CaseIterable {
    case speak
    case yourLanguages

    /// `popup.change.<name>` (test-plan 2.1).
    var popupName: String {
        switch self {
        case .speak: "change.speak"
        case .yourLanguages: "change.yourLanguages"
        }
    }

    var title: String {
        switch self {
        case .speak: String(localized: "Languages you speak")
        case .yourLanguages: String(localized: "Your languages")
        }
    }

    var subtitle: String {
        switch self {
        case .speak: String(localized: "A hint for every engine: Your languages, in order")
        case .yourLanguages: String(localized: "Shown first everywhere you pick a language")
        }
    }

    /// Both lists are Your languages (the hints come from it); empty means the engine detects.
    var mayBeEmpty: Bool {
        true
    }
}

/// The rows of the Change popup: "Chosen" in list order, then "All languages" by name; search filters both.
struct ChangeLanguagesRows: Equatable {
    let chosen: [String]
    let rest: [String]

    var isEmpty: Bool {
        chosen.isEmpty && rest.isEmpty
    }

    init(chosen: [String], all: [String], query: String, name: (String) -> String) {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        func matches(_ code: String) -> Bool {
            query.isEmpty || name(code).range(of: query, options: .caseInsensitive) != nil
        }
        let chosenSet = Set(chosen)
        self.chosen = chosen.filter(matches)
        rest = all.filter { !chosenSet.contains($0) && matches($0) }
            .sorted { name($0).localizedStandardCompare(name($1)) == .orderedAscending }
    }
}

/// Settings > Languages (05 §2.3, spec 7.13). Reads and writes `SettingsStorage`; every tick is written at once,
/// so the page, menus and open panels follow.
@MainActor
@Observable
final class LanguagesSettingsModel {
    @ObservationIgnored private let store: SettingsStorage

    private(set) var speak: [String] = []
    private(set) var yourLanguages: [String] = []
    private(set) var defaultTarget = ""
    private(set) var pairs: [TranslationLanguagePair] = []
    private(set) var pair: TranslationLanguagePair?
    private(set) var voiceCommandsEnabled = true
    private(set) var voicePosition: VoiceTranslationCommandPosition = .startAndEnd
    private(set) var voiceTargets: VoiceTranslationCommandTargets = .anySupported

    init(store: SettingsStorage = .shared) {
        self.store = store
        reload()
    }

    func reload() {
        speak = store.speechLanguageHints
        yourLanguages = store.yourLanguages
        defaultTarget = store.defaultTranslationTargetLanguage
        pairs = store.offeredTranslationPairs
        pair = store.translationPair
        voiceCommandsEnabled = store.voiceTranslationCommandsEnabled
        voicePosition = store.voiceTranslationCommandPosition
        voiceTargets = store.voiceTranslationCommandTargets
    }

    // MARK: - Change popup

    /// The 60 Diduny Cloud languages (05 §2.3 popup table).
    static let allCodes = SupportedLanguage.cloudLanguages.map(\.code)

    static func name(_ code: String) -> String {
        if let language = SupportedLanguage.language(for: code) { return language.name }
        let locale = Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en")
        return locale.localizedString(forLanguageCode: code) ?? code.uppercased()
    }

    /// "Ukrainian, English", or "Detect the language" for an empty speak list.
    static func listText(_ codes: [String]) -> String {
        codes.isEmpty ? String(localized: "Detect the language") : codes.map(name).joined(separator: ", ")
    }

    func chosen(_ list: LanguageChangeList) -> [String] {
        list == .speak ? speak : yourLanguages
    }

    /// The last of Your languages cannot be unticked (05 §2.3 limits).
    func canToggle(_ code: String, in list: LanguageChangeList) -> Bool {
        list.mayBeEmpty || !(chosen(list) == [code])
    }

    func toggle(_ code: String, in list: LanguageChangeList) {
        guard canToggle(code, in: list) else { return }
        let isChosen = chosen(list).contains(code)
        // The hints are Your languages, so both lists edit it.
        let current = store.yourLanguages
        store.yourLanguages = isChosen ? current.filter { $0 != code } : current + [code]
        reload()
    }

    // MARK: - Translation

    /// "Translate into, by default" lists the translatable Your languages.
    var targetOptions: [String] {
        YourLanguages(yourLanguages)?.translatableCodes ?? []
    }

    func setDefaultTarget(_ code: String) {
        store.defaultTranslationTargetLanguage = code
        reload()
    }

    func selectPair(id: String) {
        guard let pair = pairs.first(where: { $0.id == id }) else { return }
        store.selectTranslationPair(pair)
        reload()
    }

    // MARK: - Voice commands

    func setVoiceCommandsEnabled(_ isOn: Bool) {
        store.voiceTranslationCommandsEnabled = isOn
        reload()
    }

    func setVoicePosition(_ position: VoiceTranslationCommandPosition) {
        store.voiceTranslationCommandPosition = position
        reload()
    }

    func setVoiceTargets(_ targets: VoiceTranslationCommandTargets) {
        store.voiceTranslationCommandTargets = targets
        reload()
    }
}
