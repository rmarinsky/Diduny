import Foundation

/// One row of the typing decision log, for a host app to show. Texts are the short words the engine
/// already stored; labels are the host's job (the engine's own display names are Ukrainian).
public struct TypingDecision: Identifiable, Equatable, Sendable {
    public enum Kind: Sendable { case hint, replaced, undone }
    public enum Origin: Sendable { case layout, spelling, rule }

    public let id: UUID
    public let timestamp: Date
    public let kind: Kind
    /// Nil for an undo, which the history does not tag.
    public let origin: Origin?
    public let original: String
    public let converted: String
    public let bundleID: String?
    /// 0...1; nil when the engine did not score it.
    public let confidence: Double?
}

public struct TypingDecisionCounts: Equatable, Sendable {
    public let signals: Int
    public let replaced: Int
    public let hints: Int
    public let undone: Int

    public init(_ decisions: [TypingDecision]) {
        signals = decisions.count
        replaced = decisions.filter { $0.kind == .replaced }.count
        hints = decisions.filter { $0.kind == .hint }.count
        undone = decisions.filter { $0.kind == .undone }.count
    }
}

/// Reads and clears the decision log from the engine's storage directory, so the page works while the
/// engine is not running.
public enum TypingDecisionLog {
    private static let decisionsFile = "auto-fix-decisions.jsonl"
    private static let aggregatesFile = "auto-fix-decision-aggregates.json"
    private static let historyFile = "replacement-history.jsonl"

    /// Newest first: shown decisions (a proposal or a completed fix) and the fixes you undid.
    public static func load(directory: URL) -> [TypingDecision] {
        let observations: [AutoFixDecisionObservation] = records(directory.appendingPathComponent(decisionsFile))
        let history: [ReplacementHistoryEntry] = records(directory.appendingPathComponent(historyFile))

        let decisions = observations.filter(\.isDisplayableHistorySignal).compactMap { observation -> TypingDecision? in
            guard let converted = observation.selectedCandidate else { return nil }
            let kind: TypingDecision.Kind = observation.outcome == .proposed ? .hint : .replaced
            let origin: TypingDecision.Origin
            if observation.outcome == .ruleApplied || observation.candidateOrigin == .customRule {
                origin = .rule
            } else {
                origin = observation.candidateOrigin == .spelling ? .spelling : .layout
            }
            return TypingDecision(
                id: observation.id, timestamp: observation.timestamp, kind: kind, origin: origin,
                original: observation.source, converted: converted,
                bundleID: observation.bundleID, confidence: observation.resolvedConfidence
            )
        }
        let undone = history.filter { $0.kind == .autoFixUndone }.map {
            TypingDecision(
                id: $0.id, timestamp: $0.timestamp, kind: .undone, origin: nil,
                original: $0.original, converted: $0.converted, bundleID: $0.bundleID, confidence: nil
            )
        }
        return (decisions + undone).sorted { $0.timestamp > $1.timestamp }
    }

    /// Deletes the stored decisions, undos and their daily counts. A running engine keeps its in-memory
    /// copy until it restarts.
    public static func clear(directory: URL) {
        for name in [decisionsFile, aggregatesFile, historyFile] {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    private static func records<T: Decodable>(_ url: URL) -> [T] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return data.split(separator: UInt8(ascii: "\n")).compactMap { try? decoder.decode(T.self, from: Data($0)) }
    }
}
