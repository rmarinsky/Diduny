@testable import Diduny
import Foundation
import PapugaKit
import Testing

/// Vocabulary > Decisions: the log read from disk, the cards and the actions that reuse Typing's lists.
@MainActor
final class VocabularyDecisionsModelTests {
    private let box = IsolatedSettings("VocabularyDecisionsModelTests")
    private let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    init() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    private func iso(_ secondsAgo: TimeInterval) -> String {
        ISO8601DateFormatter().string(from: now.addingTimeInterval(-secondsAgo))
    }

    private func decision(_ outcome: String, _ source: String, _ target: String, ago: TimeInterval, origin: String = "keyboardLayout") -> String {
        """
        {"id":"\(UUID().uuidString)","timestamp":"\(iso(ago))","source":"\(source)","selectedCandidate":"\(target)","candidates":[],\
        "confidence":0.9,"threshold":0.35,"proposalWindow":0.12,"candidateSeparation":0.15,"minimumWordLength":2,\
        "algorithm":"appleNL","outcome":"\(outcome)","scope":"word","signalKind":"replacement","candidateOrigin":"\(origin)"}
        """
    }

    private func undo(_ source: String, _ target: String, ago: TimeInterval) -> String {
        """
        {"id":"\(UUID().uuidString)","timestamp":"\(iso(ago))","kind":"autoFixUndone","original":"\(source)","converted":"\(target)",\
        "originalTruncated":false,"convertedTruncated":false}
        """
    }

    private func model() throws -> VocabularyDecisionsModel {
        try [
            decision("replaced", "ghbdtn", "привіт", ago: 60),
            decision("proposed", "teh", "the", ago: 3 * 86400, origin: "spelling"),
            decision("ruleApplied", "brb", "be right back", ago: 40 * 86400, origin: "customRule")
        ].joined(separator: "\n").write(to: directory.appendingPathComponent("auto-fix-decisions.jsonl"), atomically: true, encoding: .utf8)
        try undo("ghbdtn", "привіт", ago: 30).write(to: directory.appendingPathComponent("replacement-history.jsonl"), atomically: true, encoding: .utf8)
        return VocabularyDecisionsModel(
            settings: box.settings,
            store: VocabularyStore(settings: box.settings, directory: directory, now: { [now] in now }),
            directory: directory, now: { [now] in now }
        )
    }

    @Test("the cards count the chosen period: signals, replaced and hints as a share, undone")
    func cardsFollowThePeriod() throws {
        let model = try model()
        model.period = .allTime
        #expect(model.counts.signals == 4)
        #expect(model.counts.undone == 1)
        #expect(model.replacedPercent == 50)
        #expect(model.hintsPercent == 25)

        model.period = .month
        #expect(model.counts.signals == 3)
        model.period = .today
        #expect(model.counts.signals == 2)
        #expect(model.decisions.count == 4)
    }

    @Test("the kind filter and the search narrow the list")
    func filters() throws {
        let model = try model()
        model.period = .allTime
        model.kindFilter = .undone
        #expect(model.visible.map(\.kind) == [.undone])
        model.kindFilter = .all
        model.search = "THE"
        #expect(model.visible.map(\.original) == ["teh"])
    }

    @Test("Never fix adds the word to Typing's list once; Make a rule adds a replacement and then hides")
    func actions() throws {
        let model = try model()
        model.period = .allTime
        let fix = try #require(model.visible.first { $0.original == "ghbdtn" && $0.kind == .replaced })
        #expect(model.canMakeRule(fix))
        model.makeRule(fix)
        #expect(box.settings.typingCustomReplaceRules.map(\.source) == ["ghbdtn"])
        #expect(!model.canMakeRule(fix))

        #expect(model.canNeverFix(fix))
        model.neverFix(fix)
        model.neverFix(fix)
        #expect(box.settings.typingNeverFixWords == ["ghbdtn"])
        #expect(!model.canNeverFix(fix))

        let rule = try #require(model.visible.first { $0.origin == .rule })
        #expect(!model.canMakeRule(rule))
    }

    @Test("Clear deletes the log and the retention choice is stored")
    func clearAndRetention() throws {
        let model = try model()
        model.clear()
        #expect(model.decisions.isEmpty)
        model.retention = .threeMonths
        #expect(box.settings.typingHistoryRetention == .threeMonths)
    }
}
