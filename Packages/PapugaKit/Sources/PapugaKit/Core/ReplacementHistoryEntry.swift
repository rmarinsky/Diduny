import Foundation

struct ReplacementHistoryEntry: Codable, Identifiable, Equatable {
    static let maxStoredCharCount = 80

    enum Kind: String, Codable, CaseIterable {
        case manualSwitch
        case autoFixApplied
        case autoRuleApplied
        case autoFixUndone

        var displayName: String {
            switch self {
            case .manualSwitch: return "Ручне"
            case .autoFixApplied: return "Автозаміна"
            case .autoRuleApplied: return "Правило задіяно"
            case .autoFixUndone: return "Скасована автозаміна"
            }
        }

        var systemImage: String {
            switch self {
            case .manualSwitch: return "arrow.left.arrow.right"
            case .autoFixApplied: return "wand.and.stars"
            case .autoRuleApplied: return "checkmark.seal"
            case .autoFixUndone: return "arrow.uturn.backward"
            }
        }
    }

    let id: UUID
    let timestamp: Date
    let kind: Kind
    let original: String
    let converted: String
    let originalTruncated: Bool
    let convertedTruncated: Bool
    let sourceLayoutID: String?
    let targetLayoutID: String?
    let bundleID: String?
    /// Nil for legacy records; false for copy-only or unverified insertion.
    let verificationSucceeded: Bool?

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        kind: Kind,
        original: String,
        converted: String,
        sourceLayoutID: String? = nil,
        targetLayoutID: String? = nil,
        bundleID: String? = nil,
        verificationSucceeded: Bool? = nil
    ) {
        let (origStored, origTruncated) = Self.truncated(original)
        let (convStored, convTruncated) = Self.truncated(converted)
        self.id = id
        self.timestamp = timestamp
        self.kind = kind
        self.original = origStored
        self.converted = convStored
        self.originalTruncated = origTruncated
        self.convertedTruncated = convTruncated
        self.sourceLayoutID = sourceLayoutID
        self.targetLayoutID = targetLayoutID
        self.bundleID = bundleID
        self.verificationSucceeded = verificationSucceeded
    }

    static func truncated(_ text: String) -> (String, Bool) {
        guard text.count > maxStoredCharCount else { return (text, false) }
        let visibleCount = max(0, maxStoredCharCount - 1)
        let prefix = String(text.prefix(visibleCount))
        return (prefix + "…", true)
    }
}
