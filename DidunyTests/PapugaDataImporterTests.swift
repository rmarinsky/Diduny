@testable import Diduny
import Foundation
import Testing

struct PapugaDataImporterTests {
    private let root = FileManager.default.temporaryDirectory.appendingPathComponent("papuga-import-\(UUID().uuidString)")

    private var source: URL { root.appendingPathComponent("papuga") }
    private var target: URL { root.appendingPathComponent("Typing") }

    private static let history = """
    {"id":"A","kind":"autoFixApplied","original":"vj;yf","converted":"можна"}
    not json
    {"id":"B","kind":"autoFixApplied","original":"ghbdsn","converted":"привіт"}

    """

    private static let defaults: [String: Any] = [
        "autoFixAllowlist": ["npx", "pull", "NPX"],
        "customAutoReplaceRules": [
            #"{"createdAt":807010697.1,"createdFromRecommendation":false,"id":"E707A7D4-2E31-4412-A9F2-1820C05F4C1C","matchesFullToken":true,"source":"nfrj;","target":"також"}"#,
            "broken",
        ],
        "autoFixAppPolicyOverrides": ["com.apple.TextEdit": "suggestOnly", "com.example.term": "disabled"],
        "typingCadenceAverageGap": "0.22",
    ]

    private func makeImporter() throws -> PapugaDataImporter {
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Self.history.write(
            to: source.appendingPathComponent(PapugaDataImporter.historyFileName), atomically: true, encoding: .utf8
        )
        return PapugaDataImporter(sourceDefaults: [Self.defaults], sourceDirectory: source, targetDirectory: target)
    }

    private func makeSettings() -> SettingsStorage {
        SettingsStorage(defaults: UserDefaults(suiteName: "papuga-import-\(UUID().uuidString)")!)
    }

    @Test func importsWordsRulesAppsCadenceAndHistory() throws {
        let importer = try makeImporter()
        let settings = makeSettings()
        #expect(importer.hasData)

        let result = importer.run(into: settings)

        #expect(result == .init(words: 2, rules: 1, apps: 1, fixes: 2, skippedLines: 1))
        #expect(settings.typingNeverFixWords == ["npx", "pull"])
        #expect(settings.typingCustomReplaceRules.map(\.target) == ["також"])
        #expect(settings.typingDisabledApps == ["com.example.term"])
        #expect(settings.typingCadenceAverageGap == 0.22)
        let copied = try String(contentsOf: target.appendingPathComponent(PapugaDataImporter.historyFileName), encoding: .utf8)
        #expect(copied.split(separator: "\n").count == 2)
    }

    @Test func secondRunAddsNothing() throws {
        let importer = try makeImporter()
        let settings = makeSettings()
        _ = importer.run(into: settings)

        let again = importer.run(into: settings)

        #expect(again.isEmpty)
        let copied = try String(contentsOf: target.appendingPathComponent(PapugaDataImporter.historyFileName), encoding: .utf8)
        #expect(copied.split(separator: "\n").count == 2)
    }

    @Test func papugaFilesAreNotChanged() throws {
        let importer = try makeImporter()
        let file = source.appendingPathComponent(PapugaDataImporter.historyFileName)
        let before = try Data(contentsOf: file)
        let listingBefore = try FileManager.default.contentsOfDirectory(atPath: source.path)

        _ = importer.run(into: makeSettings())

        #expect(try Data(contentsOf: file) == before)
        #expect(try FileManager.default.contentsOfDirectory(atPath: source.path) == listingBefore)
    }

    @Test func existingDidunyCadenceWins() throws {
        let importer = try makeImporter()
        let settings = makeSettings()
        settings.typingCadenceAverageGap = 0.3

        _ = importer.run(into: settings)

        #expect(settings.typingCadenceAverageGap == 0.3)
    }

    @Test func nothingFoundWhenPapugaLeftNothing() {
        let importer = PapugaDataImporter(sourceDefaults: [], sourceDirectory: source, targetDirectory: target)
        #expect(!importer.hasData)
        #expect(importer.run(into: makeSettings()).isEmpty)
    }
}
