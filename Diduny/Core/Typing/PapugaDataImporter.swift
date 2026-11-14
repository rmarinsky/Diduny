import Foundation
import PapugaKit

/// Copies what a standalone Papuga learned into Diduny: never-fix words, replace rules, apps where
/// fixes are off, the typing cadence and the layout-fix history. It only reads Papuga's preferences
/// and folder; it never writes, moves or deletes them. Running it again adds nothing new.
struct PapugaDataImporter {
    struct Result: Equatable {
        var words = 0
        var rules = 0
        var apps = 0
        var fixes = 0
        var skippedLines = 0

        var isEmpty: Bool { words + rules + apps + fixes == 0 }
    }

    static let preferenceDomains = ["ua.com.rmarinsky.papuga", "ua.com.rmarinsky.papuga.dev"]
    static let historyFileName = "replacement-history.jsonl"

    /// Papuga's preferences, one dictionary per domain.
    let sourceDefaults: [[String: Any]]
    /// `~/Library/Application Support/papuga`.
    let sourceDirectory: URL
    /// Diduny's `Typing` folder, where the engine keeps its history.
    let targetDirectory: URL

    static func live() -> PapugaDataImporter {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return PapugaDataImporter(
            sourceDefaults: preferenceDomains.compactMap { domain in
                CFPreferencesCopyMultiple(nil, domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
                    as? [String: Any]
            },
            sourceDirectory: home.appendingPathComponent("Library/Application Support/papuga"),
            targetDirectory: RecordingsLibraryStorage.defaultAppDirectory.appendingPathComponent("Typing")
        )
    }

    /// True when Papuga left anything to import.
    var hasData: Bool {
        !allowlist.isEmpty || !rules.isEmpty || !historyLines.isEmpty
    }

    func run(into settings: SettingsStorage) -> Result {
        var result = Result()

        for word in allowlist {
            let before = settings.typingNeverFixWords.count
            settings.addTypingNeverFixWord(word)
            if settings.typingNeverFixWords.count > before { result.words += 1 }
        }

        var existingRules = settings.typingCustomReplaceRules
        for rule in rules where !existingRules.contains(where: { Self.sameText($0.source, rule.source) }) {
            existingRules.append(rule)
            result.rules += 1
        }
        if result.rules > 0 { settings.typingCustomReplaceRules = existingRules }

        var apps = settings.typingDisabledApps
        for bundleID in disabledApps where !apps.contains(bundleID) {
            apps.append(bundleID)
            result.apps += 1
        }
        if result.apps > 0 { settings.typingDisabledApps = apps }

        if settings.typingCadenceAverageGap <= 0, let gap = cadence, gap > 0 {
            settings.typingCadenceAverageGap = gap
        }

        (result.fixes, result.skippedLines) = mergeHistory()
        return result
    }

    // MARK: - Reading Papuga

    private func values(_ key: String) -> [Any] {
        sourceDefaults.compactMap { $0[key] }
    }

    var allowlist: [String] {
        var seen = Set<String>()
        return values("autoFixAllowlist")
            .flatMap { ($0 as? [String]) ?? [] }
            .filter { seen.insert($0.lowercased()).inserted }
    }

    /// The `Defaults` library stores each rule as a JSON string; older builds may store data.
    var rules: [CustomAutoReplaceRule] {
        values("customAutoReplaceRules").flatMap { ($0 as? [Any]) ?? [] }.compactMap { item in
            let data = (item as? String)?.data(using: .utf8) ?? (item as? Data)
            return data.flatMap { try? JSONDecoder().decode(CustomAutoReplaceRule.self, from: $0) }
        }
    }

    /// Diduny only has "fixes off" per app, so only Papuga's "disabled" and "manual only" carry over.
    var disabledApps: [String] {
        var result: [String] = []
        for value in values("autoFixAppPolicyOverrides") {
            let overrides = (value as? [String: String]) ?? [:]
            for bundleID in overrides.keys.sorted() where ["disabled", "manualOnly"].contains(overrides[bundleID]) {
                result.append(bundleID)
            }
        }
        return result
    }

    var cadence: Double? {
        values("typingCadenceAverageGap").lazy.compactMap { value -> Double? in
            if let number = value as? NSNumber { return number.doubleValue }
            return (value as? String).flatMap(Double.init)
        }.first
    }

    private var historyLines: [String] {
        let url = sourceDirectory.appendingPathComponent(Self.historyFileName)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    // MARK: - History

    private struct EntryID: Decodable { let id: String }

    /// Appends Papuga's history entries that Diduny does not have yet, matched by `id`.
    private func mergeHistory() -> (added: Int, skipped: Int) {
        let target = targetDirectory.appendingPathComponent(Self.historyFileName)
        let existing = Set(((try? String(contentsOf: target, encoding: .utf8)) ?? "")
            .split(separator: "\n")
            .compactMap { Self.entryID(String($0)) })

        var added: [String] = []
        var skipped = 0
        var seen = existing
        for line in historyLines {
            guard let id = Self.entryID(line) else { skipped += 1; continue }
            if seen.insert(id).inserted { added.append(line) }
        }
        guard !added.isEmpty else { return (0, skipped) }

        try? FileManager.default.createDirectory(at: targetDirectory, withIntermediateDirectories: true)
        let chunk = Data((added.joined(separator: "\n") + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: target) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: chunk)
        } else if (try? chunk.write(to: target)) == nil {
            return (0, skipped)
        }
        return (added.count, skipped)
    }

    private static func entryID(_ line: String) -> String? {
        try? JSONDecoder().decode(EntryID.self, from: Data(line.utf8)).id
    }

    private static func sameText(_ lhs: String, _ rhs: String) -> Bool {
        lhs.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(rhs.trimmingCharacters(in: .whitespaces))
            == .orderedSame
    }
}
