import Foundation
import PapugaKit

/// Holds the last `TypingSettings` built from storage; the engine reads it on every key.
final class TypingSettingsCache {
    var value: TypingSettings?
}

/// Fixes while typing (the Papuga engine). Every key starts with `typing.`.
extension SettingsStorage {
    enum TypingKey: String, CaseIterable {
        case enabled = "typing.enabled"
        case sensitivity = "typing.sensitivity"
        case switchLayoutAfterFix = "typing.switchLayoutAfterFix"
        case undoHintEnabled = "typing.undoHintEnabled"
        case disabledApps = "typing.disabledApps"
        case cadenceAverageGap = "typing.cadenceAverageGap"
        case neverFixWords = "typing.neverFixWords"
        case customReplaceRules = "typing.customReplaceRules"
    }

    /// "Fix as I type". Off until the user turns it on.
    var typingEnabled: Bool {
        get { defaults.bool(forKey: TypingKey.enabled.rawValue) }
        set { setTyping(newValue, .enabled) }
    }

    var typingSensitivity: AutoFixSensitivityPreset {
        get {
            defaults.string(forKey: TypingKey.sensitivity.rawValue)
                .flatMap(AutoFixSensitivityPreset.init(rawValue:)) ?? .balanced
        }
        set { setTyping(newValue.rawValue, .sensitivity) }
    }

    /// After a fix, switch the keyboard layout to the language of the fixed word.
    var typingSwitchLayoutAfterFix: Bool {
        get { defaults.object(forKey: TypingKey.switchLayoutAfterFix.rawValue) as? Bool ?? true }
        set { setTyping(newValue, .switchLayoutAfterFix) }
    }

    var typingUndoHintEnabled: Bool {
        get { defaults.object(forKey: TypingKey.undoHintEnabled.rawValue) as? Bool ?? true }
        set { setTyping(newValue, .undoHintEnabled) }
    }

    /// Bundle IDs of the apps where nothing is fixed.
    var typingDisabledApps: [String] {
        get { defaults.stringArray(forKey: TypingKey.disabledApps.rawValue) ?? [] }
        set { setTyping(newValue, .disabledApps) }
    }

    /// The typing rhythm the engine measured, kept for the next launch. Written by the engine
    /// when it stops, so it posts no change notification.
    var typingCadenceAverageGap: Double {
        get { defaults.double(forKey: TypingKey.cadenceAverageGap.rawValue) }
        set {
            defaults.set(newValue, forKey: TypingKey.cadenceAverageGap.rawValue)
            typingSettingsCache.value = nil
        }
    }

    /// The words marked "Never replace", in the order they were added. Written by the engine, which
    /// reads them back at once, so it posts no change notification.
    var typingNeverFixWords: [String] {
        get { defaults.stringArray(forKey: TypingKey.neverFixWords.rawValue) ?? [] }
        set {
            defaults.set(newValue, forKey: TypingKey.neverFixWords.rawValue)
            typingSettingsCache.value = nil
        }
    }

    func addTypingNeverFixWord(_ rawWord: String) {
        let word = rawWord.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty,
              !typingNeverFixWords.contains(where: { $0.caseInsensitiveCompare(word) == .orderedSame }) else { return }
        typingNeverFixWords.append(word)
    }

    func removeTypingNeverFixWord(_ rawWord: String) {
        let word = rawWord.trimmingCharacters(in: .whitespacesAndNewlines)
        typingNeverFixWords.removeAll { $0.caseInsensitiveCompare(word) == .orderedSame }
    }

    /// The replace rules made from accepted proposals, stored as JSON. Written by the engine, like
    /// `typingNeverFixWords`.
    var typingCustomReplaceRules: [CustomAutoReplaceRule] {
        get {
            guard let data = defaults.data(forKey: TypingKey.customReplaceRules.rawValue) else { return [] }
            return (try? JSONDecoder().decode([CustomAutoReplaceRule].self, from: data)) ?? []
        }
        set {
            defaults.set(try? JSONEncoder().encode(newValue), forKey: TypingKey.customReplaceRules.rawValue)
            typingSettingsCache.value = nil
        }
    }

    /// What the engine reads. Built once and kept until a typing key is written through this type.
    var typingSettings: TypingSettings {
        if let cached = typingSettingsCache.value { return cached }
        var settings = TypingSettings().applying(typingSensitivity)
        settings.autoFixLayoutSwitchPolicy = (typingSwitchLayoutAfterFix
            ? AutoFixLayoutSwitchPolicy.alwaysSwitchToReplacementLayout : .keepCurrentLayout).rawValue
        settings.autoFixToastEnabled = typingUndoHintEnabled
        settings.autoFixBlocklist = typingDisabledApps
        settings.typingCadenceAverageGap = typingCadenceAverageGap
        // The engine must never "fix" a Vocabulary word either.
        var seen = Set<String>()
        settings.autoFixAllowlist = (typingNeverFixWords + speechVocabularyTerms).filter { seen.insert($0.lowercased()).inserted }
        settings.customAutoReplaceRules = typingCustomReplaceRules
        typingSettingsCache.value = settings
        return settings
    }

    private func setTyping(_ value: Any, _ key: TypingKey) {
        defaults.set(value, forKey: key.rawValue)
        typingSettingsCache.value = nil
        NotificationCenter.default.post(name: .typingSettingsChanged, object: nil)
    }
}

extension Notification.Name {
    static let typingSettingsChanged = Notification.Name("typingSettingsChanged")
}
