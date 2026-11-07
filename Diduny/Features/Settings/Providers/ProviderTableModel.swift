import Foundation

/// Row ids of the Providers comparison table (test-plan 2.1, `providers.cell.<rowId>.<engineId>`).
enum ProviderRowID: String, CaseIterable, Sendable {
    case dictLive, dictAfterStop, dictTranslation, meetLive, meetLabels, meetTranslation, translateSelected, files
    case languages, needs

    /// The eight rows that hold marks (03 1.2); Languages and Needs hold text.
    static let markRows: [ProviderRowID] = [
        .dictLive, .dictAfterStop, .dictTranslation, .meetLive, .meetLabels, .meetTranslation, .translateSelected, .files
    ]

    var title: String {
        switch self {
        case .dictLive: String(localized: "Dictation, text as you speak")
        case .dictAfterStop: String(localized: "Dictation, after Stop")
        case .dictTranslation: String(localized: "Dictation translation")
        case .meetLive: String(localized: "Meeting, live transcript")
        case .meetLabels: String(localized: "Meeting speaker labels")
        case .meetTranslation: String(localized: "Meeting translation")
        case .translateSelected: String(localized: "Translate selected text")
        case .files: String(localized: "Files and URLs")
        case .languages: String(localized: "Languages")
        case .needs: String(localized: "Needs")
        }
    }
}

/// One mark in a cell, with its optional subline. A By Diduny mark also draws "By Diduny" under itself.
struct ProviderMarkPart: Equatable, Sendable {
    let kind: CapabilityMark.Kind
    var subline: String?

    var accessibilityText: String {
        let label = switch kind {
        case .yes: String(localized: "Yes")
        case .byDiduny: String(localized: "By Diduny")
        case .no: String(localized: "No")
        }
        return subline.map { "\(label), \($0)" } ?? label
    }
}

struct ProviderColumn: Equatable, Sendable {
    enum Header: Equatable, Sendable {
        case subline(String)
        /// ElevenLabs: the "Your key" button that opens the key popup.
        case yourKey
    }

    let caps: EngineCapabilities
    var id: EngineID { caps.id }
    var name: String { ProviderTableModel.name(of: caps.id) }
    var isLocal: Bool { caps.traits.runsOn == .thisMac }

    var header: Header {
        switch caps.traits.obtainedBy {
        case .builtIn: .subline(String(localized: "Built in"))
        case .ownKey: .yourKey
        case .download: .subline(String(localized: "Download"))
        case .system: .subline(String(localized: "In macOS"))
        }
    }
}

/// Settings > Providers comparison table (03 1.2, design-spec 7.9). Every cell is derived from
/// `EngineCapabilities`; nothing here branches on the engine id except the display name.
struct ProviderTableModel: Equatable, Sendable {
    /// Cloud columns first, then local ones, each in registry order. ElevenLabs only with a saved key.
    let columns: [ProviderColumn]

    init(capabilities: [EngineCapabilities], hasKey: Bool) {
        let shown = capabilities.filter { $0.traits.obtainedBy != .ownKey || hasKey }.map(ProviderColumn.init)
        columns = shown.filter { !$0.isLocal } + shown.filter(\.isLocal)
    }

    var cloudColumns: [ProviderColumn] { columns.filter { !$0.isLocal } }
    var localColumns: [ProviderColumn] { columns.filter(\.isLocal) }
    var hasKeyColumn: Bool { columns.contains { $0.header == .yourKey } }

    /// The five engine records, as the registry builds them today.
    static func current(hasKey: Bool) -> ProviderTableModel {
        let whisper = WhisperModelManager.shared.selectedModel()
        let caps = ProviderRegistry.shared.modules.compactMap { EngineCapabilities.make($0, activeWhisperModel: whisper) }
        return ProviderTableModel(capabilities: caps, hasKey: hasKey)
    }

    /// Engine names in the redesign (03 1.3: "Local Whisper" becomes "Whisper").
    static func name(of id: EngineID) -> String {
        switch id {
        case .didunyCloud: "Diduny Cloud"
        case .elevenLabs: "ElevenLabs"
        case .whisper: "Whisper"
        case .parakeet: "Parakeet V3"
        case .appleSpeech: "Apple Speech"
        }
    }

    // MARK: Cells

    /// The marks of one of the eight capability rows (prototype `ROWS`, with v9 and the Whisper model fact).
    static func marks(_ row: ProviderRowID, _ caps: EngineCapabilities) -> [ProviderMarkPart] {
        switch row {
        case .dictLive:
            switch caps.liveDictation {
            case .final: [.init(kind: .yes)]
            case .preview: [.init(kind: .yes, subline: String(localized: "Preview"))]
            case .none: [.init(kind: .no)]
            }
        case .dictAfterStop:
            // Every engine makes the text after Stop (prototype `()=>'Y'`).
            [.init(kind: .yes)]
        case .dictTranslation:
            switch caps.dictationTranslation {
            case .itself:
                [.init(kind: .yes, subline: liveAnyLanguage(caps))]
            case .englishOnlyItselfPlusDiduny:
                [
                    .init(kind: .no, subline: String(localized: "Itself: only into English")),
                    .init(kind: .byDiduny, subline: String(localized: "Into any language"))
                ]
            case .byDiduny:
                [.init(kind: .byDiduny)]
            }
        case .meetLive:
            switch caps.liveMeetingText {
            case .final: [.init(kind: .yes)]
            case .preview: [.init(kind: .yes, subline: String(localized: "Preview"))]
            case .none: [.init(kind: .no, subline: String(localized: "After Stop only"))]
            }
        case .meetLabels:
            if caps.speakerLabelsLive {
                [.init(kind: .yes, subline: String(localized: "Live"))]
            } else if let afterStop = EngineCaptions.afterStopSpeakerLabels(caps) {
                [.init(kind: .yes, subline: afterStop)]
            } else {
                [.init(kind: .no)]
            }
        case .meetTranslation:
            switch caps.meetingTranslation {
            case .liveBothDirections: [.init(kind: .yes, subline: String(localized: "Live"))]
            case .afterStopIntoSecondLanguage: [.init(kind: .byDiduny, subline: String(localized: "After Stop"))]
            }
        case .translateSelected:
            [.init(kind: caps.dictationTranslation == .itself ? .yes : .byDiduny)]
        case .files:
            // Decision 4: files and URLs run on this Mac only.
            caps.traits.runsOn == .thisMac
                ? [.init(kind: .yes)]
                : [.init(kind: .no, subline: String(localized: "Files run on this Mac"))]
        case .languages, .needs:
            []
        }
    }

    /// "60 languages", or "Set in macOS" when the OS decides.
    static func languagesLabel(_ caps: EngineCapabilities) -> String {
        caps.traits.languages.count.map { String(localized: "\($0) languages") } ?? String(localized: "Set in macOS")
    }

    /// Needs row text, from `traits.needs`.
    static func needs(_ caps: EngineCapabilities, locale: Locale = EngineLanguages.appLocale) -> String {
        let needs = caps.traits.needs
        if needs.contains(.account) { return String(localized: "Diduny account") }
        if needs.contains(.ownKey) { return String(localized: "API key, ElevenLabs billing") }
        if needs.contains(.download) {
            if needs.contains(.appleSilicon), case let .download(bytes) = caps.traits.obtainedBy {
                let size = LocalModelSize.text(bytes: bytes) // the Size column format (POSIX), any app locale
                return String(localized: "About \(size), Apple silicon")
            }
            let sizes = WhisperModelManager.availableModels.sorted { $0.sizeBytes < $1.sizeBytes }
            if let smallest = sizes.first?.sizeDescription, let largest = sizes.last?.sizeDescription {
                return String(localized: "\(smallest) to \(largest)")
            }
        }
        return String(localized: "Nothing")
    }

    /// One accessibility element per cell (design-spec 4.8): "Whisper, Dictation translation: No, Itself: only
    /// into English. By Diduny, Into any language". "By Diduny" is read once.
    static func accessibilityLabel(column: String, row: ProviderRowID, value: String) -> String {
        "\(column), \(row.title): \(value)"
    }

    static func accessibilityValue(_ parts: [ProviderMarkPart]) -> String {
        parts.map(\.accessibilityText).joined(separator: ". ")
    }

    private static func liveAnyLanguage(_ caps: EngineCapabilities) -> String {
        guard let count = caps.traits.languages.count else { return String(localized: "Live") }
        return String(localized: "Live, any of \(count) languages")
    }
}
