import Foundation

struct ManualCorrectionCandidate: Equatable {
    let source: String
    let target: String
    let language: String
    let bundleID: String?
    let confidence: Double
}

final class ManualCorrectionTracker {
    private struct CompletedToken {
        let word: String
        let language: String
        let bundleID: String?
        let timestamp: TimeInterval
    }

    private struct ActiveCorrection {
        let source: CompletedToken
        var deleteCount: Int
        var startedAt: TimeInterval
    }

    private var lastCompleted: CompletedToken?
    private var activeCorrection: ActiveCorrection?

    private let correctionWindow: TimeInterval
    private let minDeleteCount: Int
    private let minWordLength: Int

    init(correctionWindow: TimeInterval = 12, minDeleteCount: Int = 2, minWordLength: Int = 3) {
        self.correctionWindow = correctionWindow
        self.minDeleteCount = minDeleteCount
        self.minWordLength = minWordLength
    }

    func noteCompletedWord(
        _ word: String,
        language: String,
        bundleID: String?,
        timestamp: TimeInterval
    ) -> ManualCorrectionCandidate? {
        let token = CompletedToken(word: word, language: language, bundleID: bundleID, timestamp: timestamp)
        defer { lastCompleted = token }

        guard let active = activeCorrection else { return nil }
        activeCorrection = nil

        guard timestamp - active.startedAt <= correctionWindow else { return nil }
        guard active.deleteCount >= minDeleteCount else { return nil }

        let source = active.source.word
        let target = word
        guard isLikelyCorrection(source: source, target: target) else { return nil }

        return ManualCorrectionCandidate(
            source: source,
            target: target,
            language: language,
            bundleID: bundleID ?? active.source.bundleID,
            confidence: confidence(source: source, target: target)
        )
    }

    func noteBackspace(bufferWasEmpty: Bool, timestamp: TimeInterval) {
        guard bufferWasEmpty else { return }
        if var active = activeCorrection {
            active.deleteCount += 1
            activeCorrection = active
            return
        }
        guard let lastCompleted else { return }
        guard timestamp - lastCompleted.timestamp <= correctionWindow else { return }
        activeCorrection = ActiveCorrection(
            source: lastCompleted,
            deleteCount: 1,
            startedAt: timestamp
        )
    }

    func resetEditingState() {
        activeCorrection = nil
    }

    private func isLikelyCorrection(source: String, target: String) -> Bool {
        let src = Self.normalizedToken(source)
        let tgt = Self.normalizedToken(target)
        guard src.count >= minWordLength, tgt.count >= minWordLength else { return false }
        guard src != tgt else { return false }
        guard !src.contains(where: \.isWhitespace), !tgt.contains(where: \.isWhitespace) else { return false }
        guard AutoFixDecision.shouldSkipWord(src, minLength: minWordLength) == nil else { return false }
        guard AutoFixDecision.shouldSkipWord(tgt, minLength: minWordLength) == nil else { return false }

        let distance = Self.levenshteinDistance(src, tgt)
        let maxLength = max(src.count, tgt.count)
        guard maxLength > 0 else { return false }

        let ratio = Double(distance) / Double(maxLength)
        return distance <= 3 || ratio <= 0.34
    }

    private func confidence(source: String, target: String) -> Double {
        let distance = Self.levenshteinDistance(source.lowercased(), target.lowercased())
        let maxLength = max(source.count, target.count, 1)
        let ratio = Double(distance) / Double(maxLength)
        return max(0.55, min(0.95, 0.95 - ratio))
    }

    /// Whether `token` is one of the whitespace-separated words of `phrase`
    /// (normalized), not merely a substring of one: correcting "the" must not
    /// match a chip for "other".
    static func phrase(_ phrase: String, containsToken token: String) -> Bool {
        let needle = normalizedToken(token)
        guard !needle.isEmpty else { return false }
        return phrase.split(whereSeparator: \.isWhitespace).contains { normalizedToken(String($0)) == needle }
    }

    private static func normalizedToken(_ text: String) -> String {
        BufferedToken.normalizedCore(from: text).lowercased()
    }

    static func levenshteinDistance(_ lhs: String, _ rhs: String) -> Int {
        let a = Array(lhs)
        let b = Array(rhs)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }

        var previous = Array(0...b.count)
        var current = Array(repeating: 0, count: b.count + 1)

        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(
                    previous[j] + 1,
                    current[j - 1] + 1,
                    previous[j - 1] + cost
                )
            }
            previous = current
        }

        return previous[b.count]
    }
}
