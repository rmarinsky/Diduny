import Foundation

enum AutoFixProposalOutcome: Equatable {
    case accepted
    case dismissed
    /// The user kept typing while the panel was up. Not a rejection — they were
    /// mid-thought and most likely never read it — so the proposal demotes to a
    /// passive chip that survives typing instead of dying with the panel.
    case typedOver
    case timedOut
    case neverReplace

    var shouldAddToAllowlist: Bool {
        self == .neverReplace
    }

    var shouldOfferRecovery: Bool {
        self == .dismissed || self == .timedOut
    }
}

enum AutoFixProposalPolicy {
    static func shouldSuggest(
        scoreOriginal: Double,
        scoreCandidate: Double,
        threshold: Double,
        window: Double
    ) -> Bool {
        let margin = scoreCandidate - scoreOriginal
        guard margin > 0 else { return false }
        guard margin < threshold else { return false }
        return threshold - margin <= window
    }
}
