import Foundation

/// Sizes as the Size column prints them ("75 MB", "1.5 GB"): decimal units, "." separator, one decimal
/// in GB, whatever the system locale (`ByteCountFormatter` would follow it). Used by "Delete <size>".
enum LocalModelSize {
    static func text(bytes: Int64) -> String {
        let posix = Locale(identifier: "en_US_POSIX")
        if bytes >= 1_000_000_000 {
            return String(format: "%.1f GB", locale: posix, Double(bytes) / 1_000_000_000)
        }
        return String(format: "%.0f MB", locale: posix, Double(bytes) / 1_000_000)
    }
}

/// One mark in a table cell with its optional subline (design-spec 4.8).
struct ModelCellMark: Equatable {
    let kind: CapabilityMark.Kind
    let subline: String?
}

/// The Languages cell (changes/04 §4).
enum ModelLanguagesCell: Equatable {
    /// Link "25" / "100" that opens the list.
    case list(title: String, EngineLanguageList)
    /// Link "macOS": the OS decides.
    case system
    /// Plain text "English", not clickable.
    case englishOnly

    func contains(_ code: String) -> Bool {
        switch self {
        case let .list(_, list): list.languages.contains { $0.code == code }
        case .system: true
        case .englishOnly: code == "en"
        }
    }
}

/// One row of the Local models table (changes/04 §2).
struct LocalModelRow: Identifiable, Equatable {
    enum Kind: Equatable {
        case parakeet
        case appleSpeech
        case whisper(WhisperModelManager.WhisperModel)
    }

    /// Accessibility qualifier: `WhisperModel.name`, `parakeet-v3`, `apple-speech` (test-plan 2.1).
    let id: String
    let kind: Kind
    let name: String
    let isRecommended: Bool
    let live: ModelCellMark
    let translation: [ModelCellMark]
    /// Translates (into English) itself, without Diduny.
    let translatesItself: Bool
    let languages: ModelLanguagesCell
    let speedText: String
    let accuracyText: String
    let sizeText: String
    /// Sort values on the 0...10 scale; a missing value is 0 (changes/04 §6).
    let speed: Double
    let accuracy: Double
    /// RAM and description as help on the name (plan 2.2 default for 04 Q1).
    let help: String?
    let catalogueIndex: Int

    var isWhisper: Bool {
        if case .whisper = kind { true } else { false }
    }
}

/// Rows from the capability records (WP-11): what each engine can do and its languages.
enum LocalModelCatalog {
    static let parakeetID = EngineID.parakeet.rawValue
    static let appleID = EngineID.appleSpeech.rawValue

    static func rows(includeParakeet: Bool, registry: ProviderRegistry = .shared) -> [LocalModelRow] {
        var rows: [LocalModelRow] = []
        if includeParakeet, let row = parakeetRow(registry, index: 0) { rows.append(row) }
        if let row = appleRow(registry, index: 1) { rows.append(row) }
        for (offset, model) in WhisperModelManager.availableModels.enumerated() {
            if let row = whisperRow(model, registry, index: 2 + offset) { rows.append(row) }
        }
        return rows
    }

    private static func capabilities(_ id: EngineID, _ registry: ProviderRegistry,
                                     whisper: WhisperModelManager.WhisperModel? = nil) -> EngineCapabilities? {
        registry.module(id: id.rawValue).flatMap { EngineCapabilities.make($0, activeWhisperModel: whisper) }
    }

    private static func live(_ caps: EngineCapabilities) -> ModelCellMark {
        caps.liveDictation == .none
            ? ModelCellMark(kind: .no, subline: String(localized: "After Stop"))
            : ModelCellMark(kind: .yes, subline: nil)
    }

    private static func translation(_ caps: EngineCapabilities) -> [ModelCellMark] {
        let byDiduny = ModelCellMark(kind: .byDiduny, subline: String(localized: "Any language"))
        switch caps.dictationTranslation {
        case .itself: return [ModelCellMark(kind: .yes, subline: nil)]
        case .englishOnlyItselfPlusDiduny:
            return [ModelCellMark(kind: .no, subline: String(localized: "Itself: English only")), byDiduny]
        case .byDiduny: return [byDiduny]
        }
    }

    private static func languages(_ list: EngineLanguageList) -> ModelLanguagesCell {
        guard let count = list.count else { return .system }
        return .list(title: "\(count)", list)
    }

    private static func parakeetRow(_ registry: ProviderRegistry, index: Int) -> LocalModelRow? {
        guard let caps = capabilities(.parakeet, registry) else { return nil }
        return LocalModelRow(
            id: parakeetID, kind: .parakeet, name: "Parakeet V3", isRecommended: true,
            live: live(caps), translation: translation(caps), translatesItself: caps.dictationTranslation != .byDiduny, languages: languages(caps.traits.languages),
            speedText: String(localized: "Fastest"), accuracyText: "",
            sizeText: LocalModelSize.text(bytes: ParakeetProvider.downloadBytes),
            speed: 10, accuracy: 0, help: nil, catalogueIndex: index
        )
    }

    private static func appleRow(_ registry: ProviderRegistry, index: Int) -> LocalModelRow? {
        guard let caps = capabilities(.appleSpeech, registry) else { return nil }
        return LocalModelRow(
            id: appleID, kind: .appleSpeech, name: "Apple Speech", isRecommended: false,
            live: live(caps), translation: translation(caps), translatesItself: caps.dictationTranslation != .byDiduny, languages: .system,
            speedText: "", accuracyText: String(format: String(localized: "about %@"), "8.5"),
            sizeText: String(localized: "Built in"),
            speed: 0, accuracy: 8.5, help: nil, catalogueIndex: index
        )
    }

    private static func whisperRow(_ model: WhisperModelManager.WhisperModel, _ registry: ProviderRegistry,
                                   index: Int) -> LocalModelRow? {
        guard let caps = capabilities(.whisper, registry, whisper: model) else { return nil }
        let posix = Locale(identifier: "en_US_POSIX")
        return LocalModelRow(
            id: model.name, kind: .whisper(model), name: model.displayName, isRecommended: model.isRecommended,
            live: live(caps), translation: translation(caps),
            translatesItself: caps.dictationTranslation != .byDiduny,
            languages: model.isEnglishOnly ? .englishOnly : languages(caps.traits.languages),
            speedText: String(format: "%.1f", locale: posix, model.speed * 10),
            accuracyText: String(format: "%.1f", locale: posix, model.accuracy * 10),
            sizeText: model.sizeDescription,
            speed: model.speed * 10, accuracy: model.accuracy * 10,
            help: String(format: String(localized: "%1$@. Memory: %2$@"), model.description, model.ramUsage),
            catalogueIndex: index
        )
    }
}

enum LocalModelModeFilter: String, CaseIterable, Identifiable {
    case anything, liveText, translateItself
    var id: String { rawValue }

    var title: String {
        switch self {
        case .anything: String(localized: "do anything")
        case .liveText: String(localized: "show text live")
        case .translateItself: String(localized: "translate into English without Diduny")
        }
    }
}

enum LocalModelSort: String, CaseIterable, Identifiable {
    case speed, accuracy
    var id: String { rawValue }

    var title: String {
        switch self {
        case .speed: String(localized: "Speed")
        case .accuracy: String(localized: "Accuracy")
        }
    }
}

/// What the actions cell shows (design-spec 4.12).
enum ModelActionState: Equatable {
    case download
    case downloading(percent: Int)
    case use
    case active
    case ready
    case builtIn
    /// Apple Speech cannot run on this Mac (plan 2.2 default for 04 Q3).
    case notOnThisMac
    /// Plan 2.2 default for 04 Q7: "Failed" + "Retry", the error as help.
    case failed(message: String)
    /// "Delete <size>" and "Keep".
    case askingDelete(size: String)

    var showsTrash: Bool {
        switch self {
        case .use, .active, .ready: true
        default: false
        }
    }
}

/// The Local models page state: filter, sort, the delete question and the actions (changes/04 §3, §5, §6).
@MainActor
@Observable
final class LocalModelsModel {
    var modeFilter: LocalModelModeFilter = .anything
    /// nil = any language.
    var languageFilter: String?
    var sort: LocalModelSort = .speed
    /// The one row asking "Delete <size>" / "Keep".
    private(set) var askingDeleteID: String?

    let whisper: any WhisperModelStoring
    let parakeet: any ParakeetModelStoring
    let isAppleSpeechAvailable: Bool
    let yourLanguages: [String]
    @ObservationIgnored private let catalogue: [LocalModelRow]

    init(whisper: any WhisperModelStoring, parakeet: any ParakeetModelStoring,
         isAppleSpeechAvailable: Bool, yourLanguages: [String]) {
        self.whisper = whisper
        self.parakeet = parakeet
        self.isAppleSpeechAvailable = isAppleSpeechAvailable
        self.yourLanguages = yourLanguages
        // Parakeet row hidden on Intel (plan 2.2 default for 04 Q2).
        catalogue = LocalModelCatalog.rows(includeParakeet: parakeet.isSupportedHardware)
    }

    /// Filtered, then sorted: recommended first (by the value among themselves, T4-SORT-02), then engines
    /// that are not Whisper, then by the value, ties in catalogue order. Rows do not depend on download
    /// state, so they never move on a click.
    var rows: [LocalModelRow] {
        let key: (LocalModelRow) -> Double = sort == .speed ? { $0.speed } : { $0.accuracy }
        return catalogue.filter(passes).sorted { a, b in
            if a.isRecommended != b.isRecommended { return a.isRecommended }
            if !a.isRecommended, a.isWhisper != b.isWhisper { return !a.isWhisper }
            if key(a) != key(b) { return key(a) > key(b) }
            return a.catalogueIndex < b.catalogueIndex
        }
    }

    private func passes(_ row: LocalModelRow) -> Bool {
        switch modeFilter {
        case .anything: break
        case .liveText: if row.live.kind != .yes { return false }
        case .translateItself: if !row.translatesItself { return false }
        }
        if let languageFilter, !row.languages.contains(languageFilter) { return false }
        return true
    }

    /// Union of every local model's languages, Your languages first (plan 2.2 default for 04 Q5).
    var languageOptions: [String] {
        var codes: [String] = []
        for row in catalogue {
            switch row.languages {
            case let .list(_, list): codes += list.languages.map(\.code)
            case .englishOnly: codes.append("en")
            case .system: break
            }
        }
        var seen = Set<String>()
        let unique = codes.filter { seen.insert($0).inserted }
        let mine = yourLanguages.filter { seen.contains($0) }
        let rest = unique.filter { !mine.contains($0) }
            .sorted { EngineLanguages.name(of: EngineLanguage($0)) < EngineLanguages.name(of: EngineLanguage($1)) }
        return mine + rest
    }

    func action(for row: LocalModelRow) -> ModelActionState {
        let settled = settledAction(for: row)
        if settled.showsTrash, askingDeleteID == row.id { return .askingDelete(size: row.sizeText) }
        return settled
    }

    /// The cell without the delete question: what stays visible beside the popover (option A).
    func settledAction(for row: LocalModelRow) -> ModelActionState {
        if case .appleSpeech = row.kind { return isAppleSpeechAvailable ? .builtIn : .notOnThisMac }
        let state = downloadState(row)
        switch state {
        case .notDownloaded: return .download
        case let .downloading(fraction): return .downloading(percent: Int((fraction * 100).rounded(.down)))
        case let .failed(message): return .failed(message: message)
        case .downloaded:
            if case let .whisper(model) = row.kind { return whisper.selectedModelName == model.name ? .active : .use }
            return .ready
        }
    }

    private func downloadState(_ row: LocalModelRow) -> ModelDownloadState {
        switch row.kind {
        case .parakeet: parakeet.state
        case let .whisper(model): whisper.state(of: model)
        case .appleSpeech: .downloaded
        }
    }

    // MARK: Actions

    func download(_ row: LocalModelRow) {
        switch row.kind {
        case .parakeet: parakeet.download()
        case let .whisper(model): whisper.download(model)
        case .appleSpeech: break
        }
    }

    func cancel(_ row: LocalModelRow) {
        switch row.kind {
        case .parakeet: parakeet.cancel()
        case let .whisper(model): whisper.cancel(model)
        case .appleSpeech: break
        }
    }

    /// Only one Whisper model is Active.
    func use(_ row: LocalModelRow) {
        guard case let .whisper(model) = row.kind else { return }
        whisper.selectedModelName = model.name
    }

    /// Step 1: asking moves here from any other row.
    func askToDelete(_ row: LocalModelRow) {
        guard action(for: row).showsTrash else { return }
        askingDeleteID = row.id
    }

    /// "Keep", Escape and leaving the page.
    func keep() {
        askingDeleteID = nil
    }

    /// Step 2. Deleting the Active model leaves none Active; nothing is promoted.
    func confirmDelete(_ row: LocalModelRow) {
        guard askingDeleteID == row.id else { return }
        askingDeleteID = nil
        switch row.kind {
        case .parakeet: parakeet.delete()
        case let .whisper(model): whisper.delete(model)
        case .appleSpeech: break
        }
    }
}
