import Foundation

/// The optional enrolled voice for speaker labels (spec FR-4): only a normalised voice fingerprint
/// and the date it was saved, kept on this Mac. No audio is stored; nothing is uploaded.
struct VoiceProfileStore {
    struct Profile: Codable, Equatable {
        let embedding: [Float]
        let savedAt: Date
    }

    static let shared = VoiceProfileStore()

    let fileURL: URL

    init(directory: URL? = nil) {
        let base = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "Diduny")
        fileURL = base.appendingPathComponent("voice-profile.json")
    }

    func load() -> Profile? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Profile.self, from: data)
    }

    func save(embedding: [Float], at date: Date = Date()) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(Profile(embedding: embedding, savedAt: date)).write(to: fileURL, options: .atomic)
    }

    func delete() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try FileManager.default.removeItem(at: fileURL)
    }
}
