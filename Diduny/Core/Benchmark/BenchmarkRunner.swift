import Foundation
import Observation

struct BenchmarkRun: Codable, Identifiable, Equatable {
    struct Clip: Codable, Equatable, Identifiable {
        let id: UUID
        let title: String
        let durationSeconds: TimeInterval
        let createdAt: Date
    }

    struct Engine: Codable, Equatable, Identifiable {
        let id: String
        let name: String
        let kind: BenchmarkEngineKind
    }

    struct Cell: Codable, Equatable {
        var text: String?
        var seconds: TimeInterval = 0
        var loadSeconds: TimeInterval = 0
        var error: String?
    }

    var id = UUID()
    var createdAt = Date()
    var language: String
    var clips: [Clip]
    var engines: [Engine]
    /// Key: "<clip id>|<engine id>".
    var cells: [String: Cell] = [:]
    /// Key: clip id → engine id the user marked as right.
    var votes: [UUID: String] = [:]
    var referenceEngineID: String
    var cancelled = false

    static func key(_ clip: UUID, _ engine: String) -> String { "\(clip.uuidString)|\(engine)" }
    func cell(_ clip: UUID, _ engine: String) -> Cell? { cells[Self.key(clip, engine)] }
    var audioSeconds: TimeInterval { clips.map(\.durationSeconds).reduce(0, +) }

    struct Summary {
        let rate: Double?
        let seconds: TimeInterval
        let loadSeconds: TimeInterval
        let votes: Int
        let excluded: Int
    }

    func summary(for engine: String) -> Summary {
        var errors = 0, refWords = 0, seconds: TimeInterval = 0, load: TimeInterval = 0, excluded = 0
        for clip in clips {
            guard let mine = cell(clip.id, engine), let text = mine.text else { excluded += 1; continue }
            seconds += mine.seconds
            load += mine.loadSeconds
            guard engine != referenceEngineID, let ref = cell(clip.id, referenceEngineID)?.text else { continue }
            let words = WordDiff.words(ref).count
            errors += Int((WordDiff.compare(text, reference: ref).rate * Double(words)).rounded())
            refWords += words
        }
        let rate: Double? = engine == referenceEngineID || refWords == 0 ? nil : Double(errors) / Double(refWords)
        return Summary(rate: rate, seconds: seconds, loadSeconds: load, votes: votes.values.filter { $0 == engine }.count, excluded: excluded)
    }
}

@MainActor
@Observable
final class BenchmarkRunner {
    static let shared = BenchmarkRunner()
    nonisolated static var defaultLanguage: String {
        let favorites = SettingsStorage.shared.favoriteLanguages
        return favorites.contains("uk") ? "uk" : favorites.first ?? "uk"
    }

    private(set) var runs: [BenchmarkRun] = []
    private(set) var current: BenchmarkRun?
    private(set) var isRunning = false
    private(set) var progress: (done: Int, total: Int) = (0, 0)
    private var task: Task<Void, Never>?

    private let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent(Bundle.main.bundleIdentifier ?? "Diduny").appendingPathComponent("benchmarks")
    }()

    init() { load() }

    func start(recordings: [Recording], engines: [any BenchmarkEngine], language: String) {
        guard !isRunning, !recordings.isEmpty, engines.count >= 2 else { return }
        var run = BenchmarkRun(
            language: language,
            clips: recordings.map { .init(id: $0.id, title: $0.displayTitle, durationSeconds: $0.effectiveDurationSeconds, createdAt: $0.createdAt) },
            engines: engines.map { .init(id: $0.id, name: $0.name, kind: $0.kind) },
            referenceEngineID: engines.first { $0.id == "diduny" }?.id ?? engines[0].id
        )
        current = run
        isRunning = true
        progress = (0, recordings.count * engines.count)
        let urls = recordings.map { RecordingsLibraryStorage.shared.audioFileURL(for: $0) }
        task = Task { [weak self] in
            for (clip, url) in zip(run.clips, urls) {
                for engine in engines {
                    if Task.isCancelled { break }
                    var cell = BenchmarkRun.Cell()
                    do {
                        let out = try await engine.transcribe(url, language: language)
                        cell.text = out.text
                        cell.seconds = out.seconds
                        cell.loadSeconds = out.loadSeconds
                    } catch {
                        cell.error = error.localizedDescription
                    }
                    run.cells[BenchmarkRun.key(clip.id, engine.id)] = cell
                    self?.current = run
                    self?.progress.done += 1
                }
            }
            run.cancelled = Task.isCancelled
            self?.finish(run)
        }
    }

    func cancel() { task?.cancel() }

    func open(_ run: BenchmarkRun) { current = run }
    func close() { current = nil }

    func setReference(_ engineID: String) { mutateCurrent { $0.referenceEngineID = engineID } }

    func vote(clip: UUID, engine: String?) {
        mutateCurrent { $0.votes[clip] = $0.votes[clip] == engine ? nil : engine }
    }

    func delete(_ run: BenchmarkRun) {
        try? FileManager.default.removeItem(at: file(run.id))
        runs.removeAll { $0.id == run.id }
        if current?.id == run.id { current = nil }
    }

    private func finish(_ run: BenchmarkRun) {
        current = run
        isRunning = false
        save(run)
    }

    private func mutateCurrent(_ change: (inout BenchmarkRun) -> Void) {
        guard var run = current else { return }
        change(&run)
        current = run
        if !isRunning { save(run) }
    }

    private func file(_ id: UUID) -> URL { directory.appendingPathComponent("\(id.uuidString).json") }

    private func save(_ run: BenchmarkRun) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(run) { try? data.write(to: file(run.id), options: .atomic) }
        runs.removeAll { $0.id == run.id }
        runs.insert(run, at: 0)
    }

    private func load() {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        runs = files.compactMap { try? JSONDecoder().decode(BenchmarkRun.self, from: Data(contentsOf: $0)) }
            .sorted { $0.createdAt > $1.createdAt }
    }
}
