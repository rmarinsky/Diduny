import Foundation
import OSLog

@Observable
final class ReplacementHistoryStore {
    private(set) var entries: [ReplacementHistoryEntry] = [] {
        didSet { PersonalLayoutModel.shared.replaceHistory(entries) }
    }

    private let ioQueue = DispatchQueue(label: "ua.com.rmarinsky.papuga.replacement-history", qos: .utility)
    private let fileURL: URL
    private let logger: Logger

    /// Was the Papuga setting `replacementHistoryEnabled` (default `true`). Read on every `record`.
    @ObservationIgnored var isEnabled: Bool
    /// Was the Papuga setting `replacementHistoryRetention` (default `.oneMonth`). Read on every prune.
    @ObservationIgnored var retention: ReplacementHistoryRetention

    private let memoryCap = 5000
    private let fileSizeCap = 50 * 1024 * 1024

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.withoutEscapingSlashes]
        return e
    }()

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// `directory` replaces Papuga's hard-coded `~/Library/Application Support/papuga`.
    init(
        directory dir: URL,
        isEnabled: Bool = true,
        retention: ReplacementHistoryRetention = .oneMonth,
        logSubsystem: String = Constants.bundleIdentifier
    ) {
        self.isEnabled = isEnabled
        self.retention = retention
        self.logger = Logger(subsystem: logSubsystem, category: "History")
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        self.fileURL = dir.appendingPathComponent("replacement-history.jsonl")
    }

    func bootstrap() {
        ioQueue.async { [weak self] in
            guard let self else { return }
            let loaded = self.loadEntriesFromDisk(limit: self.memoryCap)
            DispatchQueue.main.async {
                self.entries = loaded
                self.logger.notice("ReplacementHistoryStore bootstrapped with \(loaded.count, privacy: .public) entries")
            }
            self.pruneSync()
        }
    }

    func record(_ entry: ReplacementHistoryEntry) {
        guard isEnabled else { return }

        if Thread.isMainThread {
            self.entries.insert(entry, at: 0)
            self.enforceMemoryCap()
        } else {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.entries.insert(entry, at: 0)
                self.enforceMemoryCap()
            }
        }

        ioQueue.async { [weak self] in
            self?.appendToDisk(entry)
        }
    }

    func clearAll() {
        entries = []
        ioQueue.async { [weak self] in
            guard let self else { return }
            try? FileManager.default.removeItem(at: self.fileURL)
            self.logger.notice("ReplacementHistoryStore cleared")
        }
    }

    func clear(where shouldRemove: (ReplacementHistoryEntry) -> Bool) {
        let remaining = entries.filter { !shouldRemove($0) }
        guard remaining.count != entries.count else { return }

        entries = remaining
        ioQueue.async { [weak self, remaining] in
            self?.rewriteDisk(with: remaining)
        }
    }

    func pruneByRetentionAsync() {
        ioQueue.async { [weak self] in
            self?.pruneSync()
        }
    }

    /// Synchronously reads and decodes every entry straight from disk, bypassing
    /// the in-memory cache. Used by the analytics recovery backfill at launch,
    /// which may run before `bootstrap()` has populated `entries`.
    func loadEntriesSync() -> [ReplacementHistoryEntry] {
        ioQueue.sync {
            loadEntriesFromDisk(limit: nil)
        }
    }

    func entries(filter kind: ReplacementHistoryEntry.Kind? = nil, since: Date? = nil) -> [ReplacementHistoryEntry] {
        entries.filter { entry in
            if let kind, entry.kind != kind { return false }
            if let since, entry.timestamp < since { return false }
            return true
        }
    }

    private func enforceMemoryCap() {
        guard entries.count > memoryCap else { return }
        entries.removeLast(entries.count - memoryCap)
    }

    private func appendToDisk(_ entry: ReplacementHistoryEntry) {
        do {
            let data = try encoder.encode(entry)
            var line = data
            line.append(0x0A)

            let fm = FileManager.default
            if !fm.fileExists(atPath: fileURL.path) {
                try line.write(to: fileURL)
            } else {
                let handle = try FileHandle(forWritingTo: fileURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
            }
        } catch {
            logger.warning("ReplacementHistoryStore append failed: \(error.localizedDescription, privacy: .private)")
        }
    }

    private func rewriteDisk(with entries: [ReplacementHistoryEntry]) {
        do {
            if entries.isEmpty {
                try? FileManager.default.removeItem(at: fileURL)
                logger.notice("ReplacementHistoryStore cleared")
                return
            }

            var data = Data()
            for entry in entries {
                data.append(try encoder.encode(entry))
                data.append(0x0A)
            }
            try data.write(to: fileURL, options: [.atomic])
            logger.notice("ReplacementHistoryStore rewritten with \(entries.count, privacy: .public) entries")
        } catch {
            logger.warning("ReplacementHistoryStore rewrite failed: \(error.localizedDescription, privacy: .private)")
        }
    }

    private func loadEntriesFromDisk(limit: Int? = nil) -> [ReplacementHistoryEntry] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              let text = String(data: data, encoding: .utf8) else {
            return []
        }

        var result: [ReplacementHistoryEntry] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let lineData = line.data(using: .utf8),
                  let entry = try? decoder.decode(ReplacementHistoryEntry.self, from: lineData) else {
                continue
            }
            result.append(entry)
        }
        result.sort { $0.timestamp > $1.timestamp }
        if let limit, result.count > limit {
            let cap = max(0, limit)
            result = Array(result.prefix(cap))
        }
        return result
    }

    private func pruneSync() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: fileURL.path) else { return }

        let cutoff = retention.timeInterval.map { Date().addingTimeInterval(-$0) }

        let attrs = try? fm.attributesOfItem(atPath: fileURL.path)
        let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
        if cutoff == nil && size < fileSizeCap {
            return
        }

        guard let data = try? Data(contentsOf: fileURL),
              let text = String(data: data, encoding: .utf8) else {
            return
        }

        var keptLines: [String] = []
        var keptEntries: [ReplacementHistoryEntry] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let lineData = line.data(using: .utf8),
                  let entry = try? decoder.decode(ReplacementHistoryEntry.self, from: lineData) else {
                continue
            }
            if let cutoff, entry.timestamp < cutoff { continue }
            keptLines.append(String(line))
            keptEntries.append(entry)
        }

        if size > fileSizeCap {
            let target = fileSizeCap / 2
            var totalBytes = 0
            var trimmed: [String] = []
            var trimmedEntries: [ReplacementHistoryEntry] = []
            for (line, entry) in zip(keptLines, keptEntries).reversed() {
                totalBytes += line.utf8.count + 1
                if totalBytes > target { break }
                trimmed.append(line)
                trimmedEntries.append(entry)
            }
            keptLines = trimmed.reversed()
            keptEntries = trimmedEntries.reversed()
        }

        let newContent = keptLines.joined(separator: "\n") + (keptLines.isEmpty ? "" : "\n")
        do {
            try newContent.write(to: fileURL, atomically: true, encoding: .utf8)
            keptEntries.sort { $0.timestamp > $1.timestamp }
            let snapshot = keptEntries
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.entries = snapshot
            }
            logger.notice("ReplacementHistoryStore pruned: kept \(keptLines.count, privacy: .public) entries")
        } catch {
            logger.warning("ReplacementHistoryStore prune failed: \(error.localizedDescription, privacy: .private)")
        }
    }
}
