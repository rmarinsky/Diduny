@testable import Diduny
import Foundation
import PapugaKit
import Testing

/// Words from typing on "Vocabulary & context" (spec 03): the auto-add rule and the store around it.
@MainActor
final class VocabularyLearningTests {
    private let box = IsolatedSettings("VocabularyLearningTests")
    private let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    private var clock = Date(timeIntervalSince1970: 1_800_000_000)
    private var known: Set<String> = []
    private var secure = false

    deinit { try? FileManager.default.removeItem(at: directory) }

    private func makeStore() -> VocabularyStore {
        VocabularyStore(
            settings: box.settings, directory: directory,
            now: { [unowned self] in clock },
            isKnownWord: { [unowned self] word, _ in known.contains(word.lowercased()) },
            isPrivateField: { [unowned self] in secure }
        )
    }

    private func typed(_ store: VocabularyStore, _ word: String, times: Int) {
        for _ in 0 ..< times { store.observe(.typed(word: word, language: "en")) }
    }

    @Test("3 times on 2 days adds the word automatically, with its line, and never to the speller")
    func strongEvidenceAddsAutomatically() {
        let store = makeStore()
        typed(store, "Supabase", times: 2)
        clock += 86400
        typed(store, "Supabase", times: 1)
        #expect(box.settings.speechVocabularyTerms == ["Supabase"])
        let meta = store.meta(for: "supabase")
        #expect(meta?.source == .addedAutomatically)
        #expect(meta?.evidence == VocabularyEvidence(signal: .typed, count: 3, days: 2))
        #expect(store.extras.pending.isEmpty)
    }

    @Test("3 times on one day waits for a click")
    func weakEvidenceWaits() {
        let store = makeStore()
        typed(store, "Supabase", times: 3)
        #expect(box.settings.speechVocabularyTerms.isEmpty)
        #expect(store.extras.pending.map(\.kind) == [.word("Supabase")])
    }

    @Test("a word the speller knows, a non-word and a secure field are never counted")
    func filters() {
        known = ["hello"]
        let store = makeStore()
        typed(store, "hello", times: 3)
        typed(store, "abc123", times: 3)
        secure = true
        typed(store, "Supabase", times: 3)
        #expect(store.extras.pending.isEmpty)
        #expect(box.settings.speechVocabularyTerms.isEmpty)
    }

    @Test("with the switch off nothing typed is counted")
    func switchOff() {
        box.settings.typingLearnVocabulary = false
        let store = makeStore()
        typed(store, "Supabase", times: 3)
        #expect(store.extras.pending.isEmpty)
    }

    @Test("undo and Convert learn nothing while the switch is off or the field is private")
    func everySignalIsGated() {
        let store = makeStore()
        secure = true
        for _ in 0 ..< 3 {
            store.observe(.undone(original: "yoyo", replacement: "нщнщ"))
            store.observeManualSwitch(from: "ыгзф", to: "supa")
        }
        secure = false
        box.settings.typingLearnVocabulary = false
        for _ in 0 ..< 3 {
            store.observe(.undone(original: "yoyo", replacement: "нщнщ"))
            store.observeManualSwitch(from: "ыгзф", to: "supa")
        }
        #expect(store.extras.pending.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("vocabulary_evidence.json").path))
    }

    @Test("turning learning off deletes every counter and the evidence file")
    func clearDeletesAllCounters() {
        let store = makeStore()
        typed(store, "Supabase", times: 2)
        store.observe(.undone(original: "yoyo", replacement: "нщнщ"))
        store.observeManualSwitch(from: "ыгзф", to: "supa")
        let file = directory.appendingPathComponent("vocabulary_evidence.json").path
        #expect(FileManager.default.fileExists(atPath: file))
        store.clearTypedEvidence()
        #expect(!FileManager.default.fileExists(atPath: file))
        // One more sighting each must start from zero, so nothing reaches 3.
        typed(store, "Supabase", times: 1)
        store.observe(.undone(original: "yoyo", replacement: "нщнщ"))
        #expect(store.extras.pending.isEmpty)
    }

    @Test("undo: proposed at 3, but not when the fix gave a real word")
    func undoSignal() {
        known = ["привіт"]
        let store = makeStore()
        for _ in 0 ..< 3 { store.observe(.undone(original: "ghbdsn", replacement: "привіт")) }
        #expect(store.extras.pending.isEmpty)
        for _ in 0 ..< 3 { store.observe(.undone(original: "yoyo", replacement: "нщнщ")) }
        #expect(store.extras.pending.map(\.kind) == [.word("yoyo")])
        #expect(store.extras.pending.first?.evidence.signal == .undo)
    }

    @Test("Add puts a waiting word last with From typing; Ignore never brings it back")
    func acceptAndIgnore() throws {
        box.settings.speechVocabularyTerms = ["Diduny"]
        let store = makeStore()
        typed(store, "Supabase", times: 3)
        store.accept(try #require(store.extras.pending.first))
        #expect(box.settings.speechVocabularyTerms == ["Diduny", "Supabase"])
        #expect(store.meta(for: "Supabase")?.source == .fromTyping)
        #expect(store.meta(for: "Diduny") == nil)

        typed(store, "Hono", times: 3)
        store.ignore(try #require(store.extras.pending.first))
        typed(store, "Hono", times: 5)
        #expect(store.extras.pending.isEmpty)
        #expect(!box.settings.speechVocabularyTerms.contains("Hono"))
    }

    @Test("a deleted automatic word is not added again")
    func deletedAutomaticWordStaysOut() {
        let store = makeStore()
        typed(store, "Supabase", times: 2)
        clock += 86400
        typed(store, "Supabase", times: 1)
        box.settings.speechVocabularyTerms = []
        store.wordDeleted("Supabase")
        clock += 86400
        typed(store, "Supabase", times: 6)
        #expect(box.settings.speechVocabularyTerms.isEmpty)
        #expect(store.extras.pending.isEmpty)
    }

    @Test("from 250 words strong evidence waits instead, and nothing is pushed out")
    func ceiling() {
        let full = (0 ..< 250).map { "word\($0)" }
        box.settings.speechVocabularyTerms = full
        let store = makeStore()
        typed(store, "Supabase", times: 2)
        clock += 86400
        typed(store, "Supabase", times: 1)
        #expect(box.settings.speechVocabularyTerms == full)
        #expect(store.extras.pending.map(\.kind) == [.word("Supabase")])
    }

    @Test("Convert 3 times proposes a typing replacement; Add makes it a rule")
    func manualSwitch() throws {
        let store = makeStore()
        for _ in 0 ..< 3 { store.observeManualSwitch(from: "ыгзф", to: "supa") }
        let item = try #require(store.extras.pending.first)
        #expect(item.kind == .replacement(from: "ыгзф", to: "supa"))
        store.accept(item)
        #expect(box.settings.typingCustomReplaceRules.map(\.source) == ["ыгзф"])
        #expect(box.settings.typingCustomReplaceRules.map(\.target) == ["supa"])
    }

    @Test("the side files survive a relaunch; a meta entry with no word is dropped")
    func persistence() {
        let store = makeStore()
        typed(store, "Supabase", times: 3)
        store.accept(store.extras.pending[0])
        #expect(makeStore().meta(for: "Supabase")?.source == .fromTyping)
        box.settings.speechVocabularyTerms = []
        #expect(makeStore().meta(for: "Supabase") == nil)
    }

    @Test("counters older than 30 days are dropped")
    func pruning() {
        let now = Date()
        let counters = [
            "old": VocabularyCounter(spelling: "old", count: 2, lastSeen: now.addingTimeInterval(-31 * 86400)),
            "new": VocabularyCounter(spelling: "new", count: 2, lastSeen: now),
        ]
        #expect(Array(VocabularyRules.pruned(counters, now: now).keys) == ["new"])
    }

    @Test("the Whisper prompt starts with the newest Vocabulary words")
    func whisperPrompt() throws {
        let prompt = try #require(ProtectedLexiconPromptBuilder.mergedPrompt(
            userPrompt: "", language: "en", userTerms: ["Older", "Newest"]
        ))
        #expect(prompt.hasPrefix("Use exact spelling for these names when relevant: Newest, Older, "))
    }

    @Test("three layout fixes on two days become a rule; a cut-off row and a project word do not")
    func typingReviewLabels() {
        let day = Date(timeIntervalSince1970: 1_800_000_000)
        let next = day.addingTimeInterval(86_400)
        func event(_ kind: String, _ from: String, _ to: String, _ at: Date, origin: String = "layout", truncated: Bool = false) -> TypingEvent {
            TypingEvent(at: at, kind: kind, from: from, to: to, origin: origin, app: nil, truncated: truncated)
        }
        let pairs = TypingReview.pairs(from: [
            event("replaced", "ghbdtn", "привіт", day),
            event("replaced", "ghbdtn", "привіт", day),
            event("replaced", "ghbdtn", "привіт", next),
            event("replaced", "long", "cut", day, truncated: true),
            event("replaced", "long", "cut", next, truncated: true),
            event("replaced", "long", "cut", next, truncated: true),
            event("kept", "Diduny", "", day, origin: "spelling"),
            event("kept", "Diduny", "", day, origin: "spelling"),
            event("kept", "Diduny", "", next, origin: "spelling"),
        ], context: ["Diduny standup"])
        #expect(pairs.first { $0.from == "ghbdtn" }?.suggestion == "rule")
        #expect(pairs.first { $0.from == "ghbdtn" }?.days == 2)
        #expect(pairs.first { $0.from == "long" }?.suggestion == "leave")
        let word = pairs.first { $0.from == "Diduny" }
        #expect(word?.suggestion == "vocabulary")
        #expect(word?.term == "Diduny")
    }

    @Test("undoing a spelling fix of a known project word keeps that word")
    func undoneProjectWord() {
        let day = Date(timeIntervalSince1970: 1_800_000_000)
        let next = day.addingTimeInterval(86_400)
        let events = (0 ..< 3).map { index in
            TypingEvent(at: index == 2 ? next : day, kind: "undone", from: "Saqara", to: "Sakara",
                        origin: "spelling", app: nil, truncated: false)
        }
        let pairs = TypingReview.pairs(from: events, context: ["Project Saqara"], savedTerms: [])
        #expect(pairs.first?.suggestion == "vocabulary")
        #expect(pairs.first?.term == "Saqara")
        let saved = TypingReview.pairs(from: events, context: ["Project Saqara"], savedTerms: ["Saqara"])
        #expect(saved.first?.suggestion == "saved")
    }

    @Test("accepting a word writes it once")
    func acceptWord() {
        let store = makeStore()
        #expect(store.acceptWord("Diduny").ok)
        #expect(box.settings.speechVocabularyTerms == ["Diduny"])
        #expect(store.acceptWord("Diduny").message.contains("already"))
        #expect(box.settings.speechVocabularyTerms == ["Diduny"])
    }

    @Test("the date on an automatic line has no year in the current year")
    func shortDate() {
        let calendar = Calendar(identifier: .gregorian)
        let now = Date()
        let lastYear = calendar.date(byAdding: .year, value: -1, to: now)!
        #expect(!VocabularyText.shortDate(now, now: now).contains(String(calendar.component(.year, from: now))))
        #expect(VocabularyText.shortDate(lastYear, now: now).contains(String(calendar.component(.year, from: lastYear))))
    }
}
