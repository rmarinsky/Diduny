import Foundation

struct ReleaseHighlights: Decodable, Equatable {
    struct Entry: Decodable, Equatable {
        let headline: String
        let highlights: [String]
    }

    let schemaVersion: Int
    let english: Entry
    let ukrainian: Entry
    /// Language the app UI runs in; picks which entry `headline`/`highlights` return.
    var languageCode = Bundle.main.preferredLocalizations.first ?? "en"

    var headline: String { entry.headline }
    var highlights: [String] { entry.highlights }

    private var entry: Entry { languageCode.hasPrefix("uk") ? ukrainian : english }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case english = "en"
        case ukrainian = "uk"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)

        guard schemaVersion == 2 else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: container,
                debugDescription: "Unsupported release highlights schema"
            )
        }
        english = try Self.decodeEntry(from: container, forKey: .english)
        ukrainian = try Self.decodeEntry(from: container, forKey: .ukrainian)
    }

    private static func decodeEntry(
        from container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) throws -> Entry {
        let entry = try container.decode(Entry.self, forKey: key)
        guard !entry.headline.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: container,
                debugDescription: "Release headline must not be empty"
            )
        }
        guard (1...3).contains(entry.highlights.count),
              entry.highlights.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: container,
                debugDescription: "Release highlights must contain one to three non-empty items"
            )
        }
        return entry
    }

    static func bundled(in bundle: Bundle = .main) -> ReleaseHighlights? {
        load(from: bundle.url(forResource: "ReleaseHighlights", withExtension: "json"))
    }

    static func load(from url: URL?) -> ReleaseHighlights? {
        guard let url else {
            NSLog("[Updates] ReleaseHighlights.json is missing")
            return nil
        }
        do {
            return try JSONDecoder().decode(ReleaseHighlights.self, from: Data(contentsOf: url))
        } catch {
            NSLog("[Updates] Invalid release highlights: %@", error.localizedDescription)
            return nil
        }
    }
}
