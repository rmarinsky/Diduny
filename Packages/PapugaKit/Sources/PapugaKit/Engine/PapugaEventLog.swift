import Foundation

final class PapugaEventLog {
    private let queue = DispatchQueue(label: "ua.com.rmarinsky.papuga.eventlog", qos: .utility)
    private let fileURL: URL
    private let logger = AppLogger.analytics
    /// Long-lived append handle, opened lazily and reused so each event is a single write() rather
    /// than open/seek/write/close per line. Only touched on `queue`. Invalidated when pruneSync
    /// rewrites the file (which replaces the inode the handle points at).
    private var handle: FileHandle?

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.withoutEscapingSlashes]
        return e
    }()

    private static let retentionInterval: TimeInterval = 30 * 24 * 60 * 60
    private static let maxFileSizeBytes: Int = 50 * 1024 * 1024

    /// `directory` replaces Papuga's hard-coded `~/Library/Application Support/papuga`.
    init(directory dir: URL) {
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        self.fileURL = dir.appendingPathComponent("events.jsonl")
        AppLogger.post(logger, "PapugaEventLog initialized at \(fileURL.path)")
    }

    func track(_ event: AnalyticsEvent) {
        queue.async { [weak self] in
            self?.appendSync(event)
        }
    }

    private func appendSync(_ event: AnalyticsEvent) {
        do {
            let data = try encoder.encode(event)
            var line = data
            line.append(0x0A) // newline
            let handle = try openHandle()
            try handle.write(contentsOf: line)
        } catch {
            AppLogger.warn(logger, "PapugaEventLog append failed: \(error.localizedDescription)")
            // The handle may be stale/broken; drop it so the next append re-opens.
            try? handle?.close()
            handle = nil
        }
    }

    private func openHandle() throws -> FileHandle {
        if let handle { return handle }
        let fm = FileManager.default
        if !fm.fileExists(atPath: fileURL.path) {
            fm.createFile(atPath: fileURL.path, contents: nil)
        }
        let opened = try FileHandle(forWritingTo: fileURL)
        try opened.seekToEnd()
        handle = opened
        return opened
    }

    /// Deletes the log outright. Until this existed the file survived every clear the app
    /// offered — "Очистити журнал рішень" emptied the replacement and decision stores and
    /// left `events.jsonl` in place.
    func clearAll() {
        queue.async { [weak self] in
            guard let self else { return }
            try? self.handle?.close()
            self.handle = nil
            do {
                try FileManager.default.removeItem(at: self.fileURL)
            } catch CocoaError.fileNoSuchFile {
                // Already gone — that is a successful clear.
            } catch {
                AppLogger.error(self.logger, "PapugaEventLog clear failed: \(error.localizedDescription)")
                return
            }
            AppLogger.action(self.logger, "PapugaEventLog cleared")
        }
    }

    func pruneOldEntries() {
        queue.async { [weak self] in
            self?.pruneSync()
        }
    }

    private func pruneSync() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: fileURL.path) else { return }

        let attrs = try? fm.attributesOfItem(atPath: fileURL.path)
        let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
        let cutoff = Date().addingTimeInterval(-Self.retentionInterval)

        guard size > 1024 * 1024 || size > Self.maxFileSizeBytes else {
            return
        }

        guard let data = try? Data(contentsOf: fileURL),
              let text = String(data: data, encoding: .utf8) else {
            return
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        var keptLines: [String] = []
        for line in lines {
            guard let lineData = line.data(using: .utf8),
                  let event = try? decoder.decode(AnalyticsEvent.self, from: lineData) else {
                continue
            }
            if event.timestamp >= cutoff {
                keptLines.append(String(line))
            }
        }

        if size > Self.maxFileSizeBytes {
            let target = Self.maxFileSizeBytes / 2
            var totalBytes = 0
            var trimmed: [String] = []
            for line in keptLines.reversed() {
                totalBytes += line.utf8.count + 1
                if totalBytes > target { break }
                trimmed.append(line)
            }
            keptLines = trimmed.reversed()
        }

        let newContent = keptLines.joined(separator: "\n") + (keptLines.isEmpty ? "" : "\n")
        do {
            try newContent.write(to: fileURL, atomically: true, encoding: .utf8)
            // The atomic write replaced the file the append handle points at; reopen on next write.
            try? handle?.close()
            handle = nil
            AppLogger.action(logger, "PapugaEventLog pruned: kept \(keptLines.count) entries")
        } catch {
            AppLogger.warn(logger, "PapugaEventLog prune failed: \(error.localizedDescription)")
        }
    }

    deinit {
        try? handle?.close()
    }
}
