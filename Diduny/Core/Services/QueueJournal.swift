import Foundation

/// The recordings the queue still has to process, on disk, so quitting or a crash does not drop them.
/// A cloud item keeps its job ID: at the next launch the app waits for that job instead of uploading again.
struct QueueJournal {
    struct Entry: Codable, Equatable {
        enum Action: String, Codable {
            case transcribe, transcribeDiarize, translate
        }

        var recordingID: UUID
        var action: Action
        var providerOverride: String?
        var whisperModelOverride: String?
        var targetLanguage: String?
        var engineOverride: EngineID?
        var speakerLabels: Bool?
        var cloudJobID: String?
    }

    let url: URL

    init(directory: URL) {
        url = directory.appendingPathComponent("processing_queue.json")
    }

    func load() -> [Entry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
    }

    func save(_ entries: [Entry]) {
        if entries.isEmpty {
            try? FileManager.default.removeItem(at: url)
            return
        }
        do {
            try JSONEncoder().encode(entries).write(to: url, options: .atomic)
        } catch {
            Log.app.error("Queue journal could not be saved: \(error.localizedDescription)")
        }
    }
}
