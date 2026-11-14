import Foundation

enum ProtectedLexiconCategory: String, Codable, Equatable {
    case brand
    case product
    case domain
    case acronym
    case command
    case person
    case organization
    case localTerm
}

enum ProtectedLexiconMatchMode: String, Codable, Equatable {
    case exact
    case caseInsensitive
    case domainLabel
    case acronymCaseSensitive
}

enum ProtectedLexiconAction: String, Codable, Equatable {
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
    let category: ProtectedLexiconCategory
    let matchModes: [ProtectedLexiconMatchMode]
    let actions: [ProtectedLexiconAction]
    let languages: [String]
    let source: String
    let confidence: Double
    let version: Int
}

struct ProtectedLexiconPack: Codable, Equatable {
    let schemaVersion: Int
    let packID: String
    let version: String
    let sourceRevisions: [String: String]
    let entries: [ProtectedLexiconEntry]
}

struct ProtectedLexiconMatch: Equatable {
    let entry: ProtectedLexiconEntry
    let token: String
    let matchedValue: String
    let mode: ProtectedLexiconMatchMode

    var protectsSource: Bool {
        entry.actions.contains(.protectSource)
    }

    var boostsCandidate: Bool {
        entry.actions.contains(.boostCandidate)
    }

    var preservesCasing: Bool {
        entry.actions.contains(.preserveCasing)
    }

    var supportsGrammarPrediction: Bool {
        entry.actions.contains(.grammarPredictionHint)
    }

    var supportsSpellingPrediction: Bool {
        entry.actions.contains(.spellingPredictionHint)
    }
}

final class ProtectedLexiconMatcher {
    static let empty = ProtectedLexiconMatcher(entries: [])

    private let entries: [ProtectedLexiconEntry]
    private let exactIndex: [String: ProtectedLexiconEntry]
    private let foldedIndex: [String: ProtectedLexiconEntry]
    private let domainLabelIndex: [String: ProtectedLexiconEntry]

    init(entries: [ProtectedLexiconEntry]) {
        self.entries = entries

        var exact = [String: ProtectedLexiconEntry]()
        var folded = [String: ProtectedLexiconEntry]()
        var domains = [String: ProtectedLexiconEntry]()

        for entry in entries {
            let values = [entry.canonical] + entry.aliases
            for value in values {
                let normalized = Self.normalizedToken(value)
                guard !normalized.isEmpty else { continue }

                if entry.matchModes.contains(.exact) || entry.matchModes.contains(.acronymCaseSensitive) {
                    exact[normalized] = entry
                }

                if entry.matchModes.contains(.caseInsensitive) {
                    folded[normalized.lowercased()] = entry
                }

                if entry.matchModes.contains(.domainLabel) {
                    if let label = Self.domainLabel(from: normalized) {
                        domains[label.lowercased()] = entry
                    }
                    domains[normalized.lowercased()] = entry
                }
            }
        }

        self.exactIndex = exact
        self.foldedIndex = folded
        self.domainLabelIndex = domains
    }

    var allEntries: [ProtectedLexiconEntry] {
        entries
    }

    func match(_ token: String) -> ProtectedLexiconMatch? {
        let normalized = Self.normalizedToken(token)
        guard !normalized.isEmpty else { return nil }

        if let entry = exactIndex[normalized] {
            return ProtectedLexiconMatch(
                entry: entry,
                token: token,
                matchedValue: normalized,
                mode: entry.matchModes.contains(.acronymCaseSensitive) ? .acronymCaseSensitive : .exact
            )
        }

        let folded = normalized.lowercased()
        if let entry = foldedIndex[folded] {
            return ProtectedLexiconMatch(
                entry: entry,
                token: token,
                matchedValue: folded,
                mode: .caseInsensitive
            )
        }

        if let label = Self.domainLabel(from: normalized)?.lowercased(),
           let entry = domainLabelIndex[label] ?? domainLabelIndex[folded] {
            return ProtectedLexiconMatch(
                entry: entry,
                token: token,
                matchedValue: label,
                mode: .domainLabel
            )
        }

        return nil
    }

    func isProtectedSource(_ token: String) -> Bool {
        match(token)?.protectsSource == true
    }

    func isBoostedCandidate(_ token: String) -> Bool {
        match(token)?.boostsCandidate == true
    }

    func vocabularyHints(
        languages: Set<String>,
        limit: Int,
        action: ProtectedLexiconAction = .didunyVocabularyHint
    ) -> [String] {
        entries
            .filter { $0.actions.contains(action) }
            .filter { entry in
                languages.isEmpty || !Set(entry.languages).isDisjoint(with: languages)
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

    static func normalizedToken(_ token: String) -> String {
        token
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: tokenEdgePunctuation)
    }

    static func isURLLike(_ token: String) -> Bool {
        let normalized = normalizedToken(token).lowercased()
        return normalized.contains("://")
            || normalized.hasPrefix("www.")
            || normalized.hasPrefix("http:")
            || normalized.hasPrefix("https:")
    }

    static func isEmailLike(_ token: String) -> Bool {
        let normalized = normalizedToken(token)
        guard normalized.contains("@"), !normalized.hasPrefix("@"), !normalized.hasSuffix("@") else {
            return false
        }
        return normalized.split(separator: "@").count == 2
    }

    static func isDomainLike(_ token: String) -> Bool {
        domainLabel(from: normalizedToken(token)) != nil
    }

    static func domainLabel(from token: String) -> String? {
        let normalized = token.lowercased()
        guard normalized.contains("."),
              !normalized.contains(".."),
              !normalized.contains("@"),
              !normalized.contains("://") else {
            return nil
        }

        let parts = normalized.split(separator: ".").map(String.init)
        guard parts.count >= 2,
              let suffix = parts.last,
              knownTLDs.contains(suffix),
              let label = parts.dropLast().last,
              !label.isEmpty else {
            return nil
        }
        return label
    }

    private static let tokenEdgePunctuation = CharacterSet(charactersIn: " \t\n\r.,;:!?()[]{}<>\"'`“”‘’")

    private static let knownTLDs: Set<String> = [
        "ai", "app", "biz", "co", "com", "dev", "de", "edu", "fr", "io",
        "me", "net", "org", "ua", "uk", "us"
    ]
}

enum ProtectedLexiconStore {
    private static let bundledResourceName = "protected-lexicon-core"

    /// Directory of cached lexicon packs. `nil` (default) = no cached packs. The host sets it
    /// before the first use of `shared`; Papuga used
    /// `~/Library/Application Support/Papuga/ProtectedLexicon/Packs`.
    static var cachedPacksDirectory: URL?

    static let shared = ProtectedLexiconMatcher(entries: loadEntries())

    static func makeForTesting(entries: [ProtectedLexiconEntry]) -> ProtectedLexiconMatcher {
        ProtectedLexiconMatcher(entries: entries)
    }

    private static func loadEntries() -> [ProtectedLexiconEntry] {
        let bundledEntries = loadBundledPack()?.entries ?? BuiltInProtectedLexicon.entries
        let cachedEntries = loadCachedPacks().flatMap(\.entries)
        guard !cachedEntries.isEmpty else {
            return bundledEntries
        }

        return mergeEntries(bundledEntries + cachedEntries)
    }

    private static func mergeEntries(_ entries: [ProtectedLexiconEntry]) -> [ProtectedLexiconEntry] {
        var index = [String: ProtectedLexiconEntry]()
        var order = [String]()

        for entry in entries {
            if index[entry.id] == nil {
                order.append(entry.id)
            }
            index[entry.id] = entry
        }

        return order.compactMap { index[$0] }
    }

    private static func loadBundledPack() -> ProtectedLexiconPack? {
        let bundles: [Bundle] = [.module]

        for bundle in bundles {
            guard let url = bundle.url(forResource: bundledResourceName, withExtension: "json"),
                  let data = try? Data(contentsOf: url),
                  let pack = try? JSONDecoder().decode(ProtectedLexiconPack.self, from: data) else {
                continue
            }
            return pack
        }

        return nil
    }

    private static func loadCachedPacks() -> [ProtectedLexiconPack] {
        guard let packsDirectory = cachedPacksDirectory else {
            return []
        }

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

enum BuiltInProtectedLexicon {
    static let entries: [ProtectedLexiconEntry] = [
        entry(
            id: "brand.payoneer",
            canonical: "Payoneer",
            aliases: ["payoneer", "payoneer.com"],
            category: .brand,
            confidence: 0.98
        ),
        entry(
            id: "brand.github",
            canonical: "GitHub",
            aliases: ["github", "github.com"],
            category: .product,
            confidence: 0.98
        ),
        entry(
            id: "brand.openai",
            canonical: "OpenAI",
            aliases: ["openai", "open ai", "openai.com"],
            category: .organization,
            confidence: 0.98
        ),
        entry(
            id: "product.chatgpt",
            canonical: "ChatGPT",
            aliases: ["chatgpt", "chat gpt"],
            category: .product,
            confidence: 0.97
        ),
        entry(
            id: "product.ios",
            canonical: "iOS",
            aliases: ["ios"],
            category: .product,
            confidence: 0.97
        ),
        entry(
            id: "product.macos",
            canonical: "macOS",
            aliases: ["macos"],
            category: .product,
            confidence: 0.97
        ),
        entry(
            id: "product.watchos",
            canonical: "watchOS",
            aliases: ["watchos"],
            category: .product,
            confidence: 0.95
        ),
        entry(
            id: "product.tvos",
            canonical: "tvOS",
            aliases: ["tvos"],
            category: .product,
            confidence: 0.95
        ),
        entry(
            id: "product.swiftui",
            canonical: "SwiftUI",
            aliases: ["swiftui", "swift ui"],
            category: .product,
            confidence: 0.97
        ),
        entry(
            id: "product.appkit",
            canonical: "AppKit",
            aliases: ["appkit", "app kit"],
            category: .product,
            confidence: 0.96
        ),
        entry(
            id: "product.uikit",
            canonical: "UIKit",
            aliases: ["uikit", "ui kit"],
            category: .product,
            confidence: 0.96
        ),
        entry(
            id: "product.xcode",
            canonical: "Xcode",
            aliases: ["xcode"],
            category: .product,
            confidence: 0.96
        ),
        entry(
            id: "product.vscode",
            canonical: "VS Code",
            aliases: ["vscode", "vs code", "visual studio code"],
            category: .product,
            confidence: 0.95
        ),
        entry(
            id: "product.typescript",
            canonical: "TypeScript",
            aliases: ["typescript", "ts"],
            category: .product,
            confidence: 0.95
        ),
        entry(
            id: "product.javascript",
            canonical: "JavaScript",
            aliases: ["javascript", "js"],
            category: .product,
            confidence: 0.95
        ),
        entry(
            id: "product.nodejs",
            canonical: "Node.js",
            aliases: ["node.js", "nodejs", "node"],
            category: .product,
            confidence: 0.94
        ),
        entry(
            id: "product.react",
            canonical: "React",
            aliases: ["react", "react.js", "reactjs"],
            category: .product,
            confidence: 0.93
        ),
        entry(
            id: "product.nextjs",
            canonical: "Next.js",
            aliases: ["next.js", "nextjs"],
            category: .product,
            confidence: 0.93
        ),
        entry(
            id: "brand.wayforpay",
            canonical: "WayForPay",
            aliases: ["wayforpay", "way for pay", "wayforpay.com"],
            category: .brand,
            confidence: 0.95
        ),
        entry(
            id: "brand.monobank",
            canonical: "Monobank",
            aliases: ["monobank", "mono", "monobank.ua"],
            category: .brand,
            confidence: 0.95
        ),
        entry(
            id: "brand.liqpay",
            canonical: "LiqPay",
            aliases: ["liqpay", "liq pay", "liqpay.ua"],
            category: .brand,
            confidence: 0.94
        ),
        entry(
            id: "brand.figma",
            canonical: "Figma",
            aliases: ["figma", "figma.com"],
            category: .product,
            confidence: 0.95
        ),
        entry(
            id: "brand.cursor",
            canonical: "Cursor",
            aliases: ["cursor", "cursor.com"],
            category: .product,
            confidence: 0.92
        ),
        acronym("acronym.api", "API"),
        acronym("acronym.rest", "REST"),
        acronym("acronym.json", "JSON"),
        acronym("acronym.yaml", "YAML"),
        acronym("acronym.http", "HTTP"),
        acronym("acronym.https", "HTTPS"),
        acronym("acronym.oauth", "OAuth"),
        acronym("acronym.jwt", "JWT"),
        acronym("acronym.qa", "QA"),
        acronym("acronym.ci", "CI"),
        acronym("acronym.cd", "CD"),
        acronym("acronym.cli", "CLI"),
        acronym("acronym.ui", "UI"),
        acronym("acronym.ux", "UX")
    ]

    private static func entry(
        id: String,
        canonical: String,
        aliases: [String],
        category: ProtectedLexiconCategory,
        confidence: Double
    ) -> ProtectedLexiconEntry {
        ProtectedLexiconEntry(
            id: id,
            canonical: canonical,
            aliases: aliases,
            category: category,
            matchModes: [.exact, .caseInsensitive, .domainLabel],
            actions: [
                .protectSource,
                .boostCandidate,
                .preserveCasing,
                .didunyVocabularyHint,
                .didunyPostprocess,
                .grammarPredictionHint,
                .spellingPredictionHint
            ],
            languages: ["en", "uk"],
            source: "built_in_seed",
            confidence: confidence,
            version: 1
        )
    }

    private static func acronym(_ id: String, _ canonical: String) -> ProtectedLexiconEntry {
        ProtectedLexiconEntry(
            id: id,
            canonical: canonical,
            aliases: [],
            category: .acronym,
            matchModes: [.exact, .acronymCaseSensitive],
            actions: [
                .protectSource,
                .boostCandidate,
                .preserveCasing,
                .grammarPredictionHint,
                .spellingPredictionHint
            ],
            languages: ["en", "uk"],
            source: "built_in_seed",
            confidence: 0.96,
            version: 1
        )
    }
}
