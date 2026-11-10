import Foundation
import Observation

/// Settings > Modes (05 2.1, design-spec 7.11). Menus, captions and write rules; the view only lays them out.
@MainActor
@Observable
final class ModesViewModel {
    /// Five rows, top to bottom.
    static let jobs: [STTJob] = [.dictation, .dictationTranslation, .meeting, .meetingTranslation, .file]
    static let dictationSilenceOptions: [Double] = [3, 5, 10]
    static let meetingSilenceOptions: [Double] = [30, 60, 120]
    static let otherPairRowID = "pair.other"

    @ObservationIgnored let source: any ModesSettingsSource
    @ObservationIgnored private let rules: any ModeEngineRuleSource
    @ObservationIgnored private let readinessSource: any EngineReadinessSource
    @ObservationIgnored private let engines: [EngineCapabilities]
    @ObservationIgnored private let isSignedIn: () -> Bool

    /// The open expander; one at a time (`openMode`).
    private(set) var expandedJob: STTJob?
    /// Bumped on every write, so reads through `source` refresh the view.
    private var revision = 0
    private var signedIn: Bool

    init(
        source: any ModesSettingsSource,
        rules: any ModeEngineRuleSource = StandardModeEngineRules(),
        readiness: any EngineReadinessSource,
        engines: [EngineCapabilities],
        isSignedIn: @escaping () -> Bool
    ) {
        self.source = source
        self.rules = rules
        readinessSource = readiness
        self.engines = engines
        self.isSignedIn = isSignedIn
        signedIn = isSignedIn()
    }

    /// Re-reads values written elsewhere (sign-in, a key saved in Providers, a download).
    func reload() {
        signedIn = isSignedIn()
        revision += 1
    }

    private func write(_ change: () -> Void) {
        change()
        revision += 1
    }

    // MARK: Page

    var showsSignedOutNotice: Bool { !signedIn }

    /// Opens one expander, as when another page links to it.
    func expand(_ job: STTJob) {
        guard job != .file else { return }
        expandedJob = job
    }

    func toggleExpander(_ job: STTJob) {
        guard job != .file else { return }
        expandedJob = expandedJob == job ? nil : job
    }

    // MARK: Engines

    func caps(_ id: EngineID) -> EngineCapabilities? {
        engines.first { $0.id == id }
    }

    /// Engine name without suffixes ("Whisper", not "Local Whisper"; 05 2.1 Changes).
    func engineName(_ id: EngineID) -> String {
        let name = ProviderRegistry.shared.module(id: id.rawValue)?.displayName ?? id.rawValue
        return name.hasPrefix("Local ") ? String(name.dropFirst("Local ".count)) : name
    }

    /// The row's engine; Meeting reads the "Starts in" segment.
    func engine(for job: STTJob) -> EngineID {
        _ = revision
        return job == .meeting ? source.meetingEngine(for: source.meetingStartsIn) : source.engine(for: job)
    }

    func meetingEngine(for segment: MeetingSegment) -> EngineID {
        _ = revision
        return source.meetingEngine(for: segment)
    }

    func caption(for job: STTJob) -> String {
        caption(job: job, segment: job == .meeting ? startsIn : nil, engine: engine(for: job))
    }

    func caption(job: STTJob, segment: MeetingSegment?, engine: EngineID) -> String {
        guard let caps = caps(engine) else { return "" }
        return EngineCaptions.caption(job: job, segment: segment, caps: caps)
    }

    /// Offered engines after readiness: no key or wrong hardware is hidden; any other "cannot run" state is listed
    /// disabled (plan 2.2 default 6). Not downloaded stays pickable with its own subline.
    func offeredEngines(job: STTJob, segment: MeetingSegment?) -> [EngineCapabilities] {
        _ = revision
        return rules.offeredEngines(job: job, segment: segment, all: engines).filter { caps in
            let state = readinessSource.readiness(of: caps.id)
            return state != .needsKey && state != .unsupportedHardware
        }
    }

    /// Fewer than two engines: the field is static (05 2.1 states proposal).
    func isStatic(job: STTJob, segment: MeetingSegment?) -> Bool {
        offeredEngines(job: job, segment: segment).count < 2
    }

    func engineMenu(job: STTJob, segment: MeetingSegment?) -> PickerMenuModel {
        let offered = offeredEngines(job: job, segment: segment)
        let selected = job == .meeting ? meetingEngine(for: segment ?? startsIn) : engine(for: job)
        let row = { (caps: EngineCapabilities) in self.menuRow(caps) {
            EngineCaptions.menuSubline(job: job, segment: segment, caps: caps, readiness: $0)
        } }
        let cloud = offered.filter { $0.traits.runsOn == .cloud }.map(row)
        let local = offered.filter { $0.traits.runsOn == .thisMac }.map(row)
        let groups: [PickerMenuGroup] = switch (job, segment) {
        case (.file, _):
            [PickerMenuGroup(id: "thisMac", rows: local)]
        case (.meeting, .thisMac), (.meeting, .cloud):
            [PickerMenuGroup(id: "segment", rows: cloud + local)]
        case (.meeting, _):
            [
                PickerMenuGroup(id: "thisMac", header: String(localized: "On this Mac, recommended"), rows: local),
                PickerMenuGroup(id: "cloud", header: String(localized: "Cloud"), rows: cloud),
            ]
        default:
            [
                PickerMenuGroup(id: "cloud", header: String(localized: "Cloud"), rows: cloud),
                PickerMenuGroup(id: "thisMac", header: String(localized: "On this Mac"), rows: local),
            ]
        }
        return PickerMenuModel(groups: groups, selectedID: selected.rawValue, search: .never)
    }

    private func menuRow(_ caps: EngineCapabilities, subline: (EngineReadiness) -> String) -> PickerMenuRow {
        let state = readinessSource.readiness(of: caps.id)
        let pickable = if case .notDownloaded = state { true } else { state != .unavailable }
        return PickerMenuRow(id: caps.id.rawValue, title: engineName(caps.id), subline: subline(state), isEnabled: pickable)
    }

    /// A pick in a row's engine field; Meeting edits the given segment (the row passes "Starts in").
    func pickEngine(_ rowID: String, job: STTJob, segment: MeetingSegment? = nil) {
        guard let engine = EngineID(rawValue: rowID) else { return }
        write {
            if job == .meeting {
                source.setMeetingEngine(engine, for: segment ?? source.meetingStartsIn)
            } else {
                source.setEngine(engine, for: job)
            }
        }
    }

    // MARK: Use one engine for everything (05 section 3)

    /// The one engine every mode uses, or nil for "Different per mode" (`ModeEngineRules`, 05 section 3).
    var uniformEngine: EngineID? {
        ModeEngineRules.displayedUniformEngine(engine: engine(for:), available: engines)
    }

    var uniformEngineValue: String {
        uniformEngine.map(engineName) ?? String(localized: "Different per mode")
    }

    func uniformEngineMenu() -> PickerMenuModel {
        let offered = engines.filter { caps in
            let state = readinessSource.readiness(of: caps.id)
            return state != .needsKey && state != .unsupportedHardware
        }
        let row = { (caps: EngineCapabilities) in self.menuRow(caps) {
            EngineCaptions.withNote(EngineCaptions.blurb(caps), caps: caps, readiness: $0)
        } }
        return PickerMenuModel(
            groups: [
                PickerMenuGroup(id: "cloud", header: String(localized: "Cloud"), rows: offered.filter { $0.traits.runsOn == .cloud }.map(row)),
                PickerMenuGroup(id: "thisMac", header: String(localized: "On this Mac"), rows: offered.filter { $0.traits.runsOn == .thisMac }.map(row)),
            ],
            selectedID: uniformEngine?.rawValue,
            search: .never
        )
    }

    /// Applies `ModeEngineRules.useOneEngineForEverything` through the source.
    func pickUniformEngine(_ rowID: String) {
        guard let engine = EngineID(rawValue: rowID), let caps = caps(engine) else { return }
        write {
            for change in ModeEngineRules.useOneEngineForEverything(caps) {
                switch change {
                case let .engine(job, _): source.setEngine(engine, for: job)
                case let .segmentEngine(segment, _): source.setMeetingEngine(engine, for: segment)
                case let .startsIn(segment): source.meetingStartsIn = segment
                }
            }
        }
    }

    // MARK: Starts in

    var startsIn: MeetingSegment {
        _ = revision
        return source.meetingStartsIn
    }

    var startsInValue: String { EngineCaptions.startsIn(startsIn).title }

    func startsInMenu() -> PickerMenuModel {
        let rows = MeetingSegment.allCases.map { segment in
            let text = EngineCaptions.startsIn(segment)
            return PickerMenuRow(id: segment.rawValue, title: text.title, subline: text.subline)
        }
        return PickerMenuModel(groups: [PickerMenuGroup(id: "startsIn", rows: rows)], selectedID: startsIn.rawValue, search: .never)
    }

    func pickStartsIn(_ rowID: String) {
        guard let segment = MeetingSegment(rawValue: rowID) else { return }
        write { source.meetingStartsIn = segment }
    }

    // MARK: Into and Between

    private static func languageName(_ code: String) -> String {
        SupportedLanguage.language(for: code)?.name ?? code.uppercased()
    }

    var intoValue: String {
        _ = revision
        return Self.languageName(source.dictationTranslationTarget)
    }

    /// The 60 Diduny Cloud languages for every engine, Your languages first, search on (05 2.1 "Into").
    func intoMenu() -> PickerMenuModel {
        _ = revision
        return PickerMenuModel.languages(
            SupportedLanguage.cloudLanguages.map { PickerMenuLanguage(code: $0.code, name: $0.name) },
            yours: source.yourLanguages,
            selectedCode: source.dictationTranslationTarget
        )
    }

    func pickInto(_ rowID: String) {
        let prefix = PickerMenuModel.languageRowID("")
        guard rowID.hasPrefix(prefix) else { return }
        write { source.dictationTranslationTarget = String(rowID.dropFirst(prefix.count)) }
    }

    /// "EN ↔ UK" (`pShort`).
    var betweenValue: String {
        _ = revision
        guard let pair = source.translationPair else { return "—" }
        return pair.codes.map { String($0.prefix(2)).uppercased() }.joined(separator: " ↔ ")
    }

    func betweenMenu() -> PickerMenuModel {
        _ = revision
        let pairs = source.offeredTranslationPairs.map { pair in
            PickerMenuRow(id: pair.id, title: pair.codes.map(Self.languageName).joined(separator: " ↔ "))
        }
        let other = PickerMenuRow(
            id: Self.otherPairRowID,
            title: String(localized: "Other languages..."),
            subline: String(localized: "Add them to Your languages in Settings")
        )
        let selected = source.translationPair.flatMap { current in
            source.offeredTranslationPairs.first { Set($0.codes) == Set(current.codes) }?.id
        }
        return PickerMenuModel(
            groups: [
                PickerMenuGroup(id: "pairs", header: String(localized: "Both directions, between your languages"), rows: pairs),
                PickerMenuGroup(id: "other", rows: [other]),
            ],
            selectedID: selected,
            search: .never
        )
    }

    /// Returns false for "Other languages...": the caller opens Settings > Languages.
    @discardableResult
    func pickBetween(_ rowID: String) -> Bool {
        guard let pair = source.offeredTranslationPairs.first(where: { $0.id == rowID }) else { return false }
        write { source.selectTranslationPair(pair) }
        return true
    }

    // MARK: Parakeet warning (design-spec 12.1.1)

    /// Files when its engine is not downloaded; Meeting when its Record only engine is not, whatever "Starts in" is.
    func notDownloadedBytes(for job: STTJob) -> Int64? {
        _ = revision
        let checked = job == .meeting ? source.meetingEngine(for: .recordOnly) : source.engine(for: job)
        guard case let .notDownloaded(bytes) = readinessSource.readiness(of: checked) else { return nil }
        return bytes
    }

    func downloadLinkTitle(bytes: Int64, locale: Locale = EngineLanguages.appLocale) -> String {
        let size = bytes.formatted(.byteCount(style: .file).locale(locale))
        return String(localized: "Download \(size)")
    }

    // MARK: Expander options

    func pushToTalk(for job: STTJob) -> ModePushToTalk {
        _ = revision
        return source.pushToTalk(for: job)
    }

    /// "Tap to start and stop": 0 = Off, else the tap count.
    func tapSelection(for job: STTJob) -> Int {
        let value = pushToTalk(for: job)
        return value.toggleEnabled ? value.tapCount : 0
    }

    /// Off writes `toggleEnabled = false` and keeps the count; 2 or 3 turns it on with that count.
    func setTapSelection(_ selection: Int, for job: STTJob) {
        var value = source.pushToTalk(for: job)
        value.toggleEnabled = selection != 0
        if selection != 0 { value.tapCount = selection }
        write { source.setPushToTalk(value, for: job) }
    }

    func updatePushToTalk(for job: STTJob, _ change: (inout ModePushToTalk) -> Void) {
        var value = source.pushToTalk(for: job)
        change(&value)
        value.holdDelaySeconds = (min(max(value.holdDelaySeconds, 0.5), 2.0) * 10).rounded() / 10
        write { source.setPushToTalk(value, for: job) }
    }

    func holdForLabel(_ seconds: TimeInterval) -> String {
        String(format: String(localized: "%.1f s"), seconds)
    }

    /// Dictation's key and Translation's key: both Option or both Command keys block in-place translation (Inv 3.3).
    func blocksInplaceTranslation() -> Bool {
        let shortcuts = [STTJob.dictation, .dictationTranslation].map { job in
            let value = pushToTalk(for: job)
            return (key: value.key, active: value.holdEnabled || value.toggleEnabled)
        }
        return PushToTalkKey.blocksInplaceTranslation(PushToTalkKey.reservedForInplaceTranslation(shortcuts))
    }

    func silence(for job: STTJob) -> ModeSilence {
        _ = revision
        return source.silence(for: job)
    }

    func setSilence(_ value: ModeSilence, for job: STTJob) {
        write { source.setSilence(value, for: job) }
    }

    /// Three values per kind; a stored value outside them is added as a fourth item, so it is shown, not changed.
    func silenceOptions(for job: STTJob) -> [Double] {
        let base = job == .meeting || job == .meetingTranslation ? Self.meetingSilenceOptions : Self.dictationSilenceOptions
        let stored = silence(for: job).seconds
        return base.contains(stored) ? base : (base + [stored]).sorted()
    }

    var meetingSuggestionsEnabled: Bool {
        get { _ = revision; return source.meetingSuggestionsEnabled }
        set { write { source.meetingSuggestionsEnabled = newValue } }
    }

    var meetingTranslationShowOriginal: Bool {
        get { _ = revision; return source.meetingTranslationShowOriginal }
        set { write { source.meetingTranslationShowOriginal = newValue } }
    }
}
