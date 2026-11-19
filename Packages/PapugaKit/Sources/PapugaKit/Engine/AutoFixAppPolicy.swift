import Foundation

enum AutoFixAppPolicy: String, Codable, CaseIterable {
    case autoMutate
    case suggestOnly
    case manualOnly
    case disabled

    var title: String {
        switch self {
        case .autoMutate:
            return "Автозамінювати"
        case .suggestOnly:
            return "Лише пропонувати"
        case .manualOnly:
            return "Лише вручну"
        case .disabled:
            return "Вимкнено"
        }
    }

    var allowsAutomaticMutation: Bool {
        self == .autoMutate
    }

    var allowsProposal: Bool {
        self == .autoMutate || self == .suggestOnly
    }
}

enum AutoFixAppPolicyResolver {
    static func policy(for bundleID: String?, overrides: [String: String] = [:]) -> AutoFixAppPolicy {
        guard let bundleID, !bundleID.isEmpty else { return .suggestOnly }

        if let override = overrides[bundleID],
           let policy = AutoFixAppPolicy(rawValue: override) {
            return policy
        }

        return defaultPolicy(for: bundleID)
    }

    /// Every app auto-mutates by default. There are no hardcoded per-app exceptions: users exclude
    /// or soften specific apps themselves via the blocklist (full off) or per-app overrides
    /// (`autoFixAppPolicyOverrides`, checked ahead of this in `policy(for:)`).
    static func defaultPolicy(for _: String) -> AutoFixAppPolicy {
        .autoMutate
    }
}
