import AppKit
import KeyboardShortcuts

/// Modifier families of a chord, side-agnostic. Raw values are `NSEvent.ModifierFlags` family bits,
/// so the stored JSON reads the same as an `NSEvent` mask.
struct ModifierFamilies: OptionSet, Hashable {
    let rawValue: UInt

    static let shift = Self(rawValue: NSEvent.ModifierFlags.shift.rawValue)
    static let control = Self(rawValue: NSEvent.ModifierFlags.control.rawValue)
    static let option = Self(rawValue: NSEvent.ModifierFlags.option.rawValue)
    static let command = Self(rawValue: NSEvent.ModifierFlags.command.rawValue)

    static let all: Self = [.shift, .control, .option, .command]
    static let optionCommand: Self = [.option, .command]

    init(rawValue: UInt) {
        self.rawValue = rawValue
    }

    /// The families held in `flags`; device side bits, Caps Lock and Fn are dropped.
    init(flags: NSEvent.ModifierFlags) {
        rawValue = flags.rawValue & Self.all.rawValue
    }

    var count: Int {
        [Self.shift, .control, .option, .command].filter(contains).count
    }

    /// ⌘, ⌥ or ⌃: what a key needs to be a shortcut. ⇧ alone does not count (RecorderCocoa rule).
    var hasNonShiftModifier: Bool {
        !intersection([.control, .option, .command]).isEmpty
    }

    /// Standard macOS order: ⌃⌥⇧⌘.
    var displaySymbols: String {
        var result = ""
        if contains(.control) { result += "⌃" }
        if contains(.option) { result += "⌥" }
        if contains(.shift) { result += "⇧" }
        if contains(.command) { result += "⌘" }
        return result
    }
}

/// Which kind of shortcut Translate in place uses (ADR-0012 D8). The key chord itself lives in
/// package storage under `KeyboardShortcuts.Name.inplaceTranslation`; this tag only says which
/// kind is active, so the chord has one source of truth.
enum InplaceTranslationShortcut: Equatable, Codable {
    case modifierChord(ModifierFamilies)
    case keyChord

    /// Today's gesture: ⌥⌘.
    static let `default` = Self.modifierChord(.optionCommand)

    var modifierFamilies: ModifierFamilies? {
        if case let .modifierChord(families) = self { return families }
        return nil
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case modifiers
    }

    private enum Kind: String, Codable {
        case modifierChord
        case keyChord
    }

    struct InvalidChord: Error {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // An untagged `{"modifiers": …}` object (integration-branch builds) is a modifier chord.
        let kind = try container.decodeIfPresent(Kind.self, forKey: .kind) ?? .modifierChord
        switch kind {
        case .keyChord:
            self = .keyChord
        case .modifierChord:
            let families = try ModifierFamilies(
                flags: NSEvent.ModifierFlags(rawValue: container.decode(UInt.self, forKey: .modifiers))
            )
            guard families.count >= 2 else { throw InvalidChord() }
            self = .modifierChord(families)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .modifierChord(families):
            try container.encode(Kind.modifierChord, forKey: .kind)
            try container.encode(families.rawValue, forKey: .modifiers)
        case .keyChord:
            try container.encode(Kind.keyChord, forKey: .kind)
        }
    }
}

/// The rows of Settings > Shortcuts that have keys, a press count and a switch (05 2.5).
/// Mode hotkeys live in Modes and have no switch.
enum ShortcutRow: String, CaseIterable {
    case cancelRecording
    case forceSubmit
    case addMeetingChapter
    case translateSelectedText
    case inplaceTranslation
    case historyPalette

    /// The package name behind the row's keys; nil for the cancel key, which is stored by Diduny.
    var hotkeyName: KeyboardShortcuts.Name? {
        switch self {
        case .cancelRecording: nil
        case .forceSubmit: .forceSubmit
        case .addMeetingChapter: .addMeetingChapter
        case .translateSelectedText: .translateSelectedText
        case .inplaceTranslation: .inplaceTranslation
        case .historyPalette: .toggleHistoryPalette
        }
    }
}

enum ShortcutKeys: Equatable {
    /// A chord in `KeyboardShortcuts` storage (unchanged format).
    case chord(KeyboardShortcuts.Name)
    /// The Cancel row: Esc, a bare F key, or a key with ⌘ ⌥ ⌃ (`escapeCancelShortcut`).
    case cancelKey(RecordingCancelShortcut)
    /// Translate in place: a modifier chord, or a key chord under `.inplaceTranslation`.
    case inplace(InplaceTranslationShortcut)
}

/// One row of Shortcuts (plan 3.5): keys, how many presses, on or off.
struct ShortcutSetting: Equatable {
    let keys: ShortcutKeys
    let pressCount: Int
    let enabled: Bool

    /// 1x is not offered for an in-place modifier chord: it would fire on any lone ⌥⌘ press.
    var allowedPressCounts: ClosedRange<Int> {
        if case .inplace(.modifierChord) = keys { return 2 ... 3 }
        return 1 ... 3
    }
}
