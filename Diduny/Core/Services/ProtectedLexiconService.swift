import Foundation

enum ProtectedLexiconAction: String, Codable {
    case protectSource
    case boostCandidate
    case preserveCasing
    case didunyVocabularyHint
    case didunyPostprocess
    case grammarPredictionHint
    case spellingPredictionHint
}

struct ProtectedLexiconEntry: Codable, Equatable, Identifiable {
    let id: String
    let canonical: String
    let aliases: [String]
    let actions: [ProtectedLexiconAction]
    let languages: [String]
    let confidence: Double
}

private struct ProtectedLexiconPack: Codable {
    let entries: [ProtectedLexiconEntry]
}

enum ProtectedLexiconService {
    static let shared = ProtectedLexiconMatcher(entries: loadEntries())

    private static let builtInEntries: [ProtectedLexiconEntry] = [
        entry("brand.payoneer", "Payoneer", ["pay one ear", "payoneer"]),
        entry("brand.github", "GitHub", ["git hub", "github"]),
        entry("brand.openai", "OpenAI", ["open ai", "openai"]),
        entry("product.chatgpt", "ChatGPT", ["chat gpt", "chatgpt"]),
        entry("product.swiftui", "SwiftUI", ["swift ui", "swiftui"]),
        entry("product.appkit", "AppKit", ["app kit", "appkit"]),
        entry("product.uikit", "UIKit", ["ui kit", "uikit"]),
        entry("product.xcode", "Xcode", ["x code", "xcode"]),
        entry("product.vscode", "VS Code", ["vs code", "visual studio code", "vscode"]),
        entry("brand.wayforpay", "WayForPay", ["way for pay", "wayforpay"]),
        entry("brand.liqpay", "LiqPay", ["liq pay", "liqpay"]),
        entry("brand.figma", "Figma", ["figma"]),
        entry("brand.cursor", "Cursor", ["cursor"])
    ]

    private static func entry(
        _ id: String,
        _ canonical: String,
        _ aliases: [String],
        confidence: Double = 0.96
    ) -> ProtectedLexiconEntry {
        ProtectedLexiconEntry(
            id: id,
            canonical: canonical,
            aliases: aliases,
            actions: [
                .didunyVocabularyHint,
                .didunyPostprocess,
                .grammarPredictionHint,
                .spellingPredictionHint,
                .preserveCasing
            ],
            languages: ["en", "uk"],
            confidence: confidence
        )
    }

    private static func loadEntries() -> [ProtectedLexiconEntry] {
        let cachedEntries = loadCachedPacks().flatMap(\.entries)
        guard !cachedEntries.isEmpty else {
            return builtInEntries
        }

        var index = [String: ProtectedLexiconEntry]()
        var order = [String]()

        for entry in builtInEntries + cachedEntries {
            if index[entry.id] == nil {
                order.append(entry.id)
            }
            index[entry.id] = entry
        }

        return order.compactMap { index[$0] }
    }

    private static func loadCachedPacks() -> [ProtectedLexiconPack] {
        guard let root = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            return []
        }

        let packsDirectory = root
            .appendingPathComponent("Diduny", isDirectory: true)
            .appendingPathComponent("ProtectedLexicon", isDirectory: true)
            .appendingPathComponent("Packs", isDirectory: true)

        guard let files = try? FileManager.default.contentsOfDirectory(
            at: packsDirectory,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }

        let decoder = JSONDecoder()
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? decoder.decode(ProtectedLexiconPack.self, from: data)
            }
    }
}

final class ProtectedLexiconMatcher {
    private let entries: [ProtectedLexiconEntry]

    init(entries: [ProtectedLexiconEntry]) {
        self.entries = entries
    }

    func vocabularyHints(language: String?, limit: Int) -> [String] {
        let requestedLanguages = Set([language, "en", "uk"].compactMap { $0?.lowercased() })

        return entries
            .filter { $0.actions.contains(.didunyVocabularyHint) }
            .filter { entry in
                requestedLanguages.isEmpty || !Set(entry.languages.map { $0.lowercased() }).isDisjoint(with: requestedLanguages)
            }
            .sorted { lhs, rhs in
                if lhs.confidence == rhs.confidence {
                    return lhs.canonical.localizedCaseInsensitiveCompare(rhs.canonical) == .orderedAscending
                }
                return lhs.confidence > rhs.confidence
            }
            .prefix(limit)
            .map(\.canonical)
    }

    func postprocessTranscript(_ text: String) -> String {
        var result = text

        for entry in entries where entry.actions.contains(.didunyPostprocess) {
            for alias in entry.aliases where alias.contains(" ") {
                result = replacePhrase(alias, with: entry.canonical, in: result)
            }
        }

        return result
    }

    private func replacePhrase(_ phrase: String, with replacement: String, in text: String) -> String {
        let escaped = NSRegularExpression.escapedPattern(for: phrase)
            .replacingOccurrences(of: "\\ ", with: "\\s+")
        let pattern = #"(?i)(?<![\p{L}\p{N}])"# + escaped + #"(?![\p{L}\p{N}])"#

        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return text
        }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(
            in: text,
            options: [],
            range: range,
            withTemplate: replacement
        )
    }
}

enum ProtectedLexiconPromptBuilder {
    static func mergedPrompt(userPrompt: String, language: String?) -> String? {
        let trimmedUserPrompt = userPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let hints = ProtectedLexiconService.shared.vocabularyHints(language: language, limit: 32)
        guard !hints.isEmpty else {
            return trimmedUserPrompt.isEmpty ? nil : trimmedUserPrompt
        }

        let lexiconPrompt = "Use exact spelling for these names when relevant: \(hints.joined(separator: ", "))."
        guard !trimmedUserPrompt.isEmpty else {
            return lexiconPrompt
        }

        return "\(trimmedUserPrompt)\n\(lexiconPrompt)"
    }
}
