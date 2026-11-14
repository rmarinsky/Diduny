import Foundation

/// From Papuga's `TextSwitchEngine.sourceLayout`: which layout selected text was typed in.
enum TextSwitchSourceLayout {
    /// The layout that can type the most letters of `text`. The system layout
    /// wins ties, so same-script layouts and letterless text behave as before.
    static func sourceLayout(
        of text: String,
        among layoutIDs: [String],
        systemLayoutID: String,
        canType: (Character, String) -> Bool
    ) -> String {
        let letters = text.filter(\.isLetter)
        func coverage(_ id: String) -> Int { letters.filter { canType($0, id) }.count }
        let systemCoverage = coverage(systemLayoutID)
        let best = layoutIDs.filter { $0 != systemLayoutID }
            .map { (id: $0, coverage: coverage($0)) }
            .max { $0.coverage < $1.coverage }
        guard let best, best.coverage > systemCoverage else { return systemLayoutID }
        return best.id
    }
}
