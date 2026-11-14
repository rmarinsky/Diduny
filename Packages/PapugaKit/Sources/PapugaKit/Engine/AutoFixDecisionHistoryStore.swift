import Foundation
import OSLog

protocol AutoFixDecisionRecording: AnyObject {
    func record(_ entry: AutoFixDecisionObservation)
}

@Observable
final class AutoFixDecisionHistoryStore: AutoFixDecisionRecording {
    private enum AggregateMemoryMutation {
        case add(revision: Int, aggregate: AutoFixDecisionAggregate)
        case replace(revision: Int, aggregates: [AutoFixDecisionAggregate])

        var revision: Int {
            switch self {
            case .add(let revision, _), .replace(let revision, _): return revision
            }
        }
    }

    private struct DiskPruneResult {
        let entries: [AutoFixDecisionObservation]
        let aggregates: [AutoFixDecisionAggregate]
        let snapshotStartedAt: Date
    }

    private(set) var entries: [AutoFixDecisionObservation] = []
    private(set) var aggregates: [AutoFixDecisionAggregate] = []

    private let ioQueue = DispatchQueue(label: "ua.com.rmarinskyi.papuga.auto-fix-decisions", qos: .utility)
    private let fileURL: URL
    private let aggregateFileURL: URL
    private let logger: Logger

    /// Was the Papuga setting `replacementHistoryEnabled` (default `true`). Read on every `record`.
    @ObservationIgnored var isEnabled: Bool = true
    /// Was the Papuga setting `replacementHistoryRetention` (default `.oneMonth`). Read on every prune.
    @ObservationIgnored var retention: ReplacementHistoryRetention = .oneMonth
    private let memoryCap = 5000
    private let fileSizeCap = 50 * 1024 * 1024
    private let aggregateMemoryCap: Int
    private let aggregateFileSizeCap: Int
    private var lastRetentionPruneAt: Date?
    private let retentionPruneInterval: TimeInterval = 6 * 60 * 60
    private var aggregateRevision = 0
    private var aggregateMemoryMutations: [AggregateMemoryMutation] = []
    private var aggregateSnapshotsInFlight: [Int] = []

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return encoder
    }()

    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// `directory` replaces Papuga's hard-coded `~/Library/Application Support/papuga`.
    init(
        directory: URL,
        isEnabled: Bool = true,
        retention: ReplacementHistoryRetention = .oneMonth,
        logSubsystem: String = Constants.bundleIdentifier
    ) {
        self.isEnabled = isEnabled
        self.retention = retention
        logger = Logger(subsystem: logSubsystem, category: "DecisionHistory")
        aggregateMemoryCap = 3_000
        aggregateFileSizeCap = 5 * 1024 * 1024
        let manager = FileManager.default
        if !manager.fileExists(atPath: directory.path) {
            try? manager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        fileURL = directory.appendingPathComponent("auto-fix-decisions.jsonl")
        aggregateFileURL = directory.appendingPathComponent("auto-fix-decision-aggregates.json")
    }

    #if DEBUG
    init(
        testFileURL: URL,
        testAggregateFileURL: URL? = nil,
        aggregateMemoryCap: Int = 3_000,
        aggregateFileSizeCap: Int = 5 * 1024 * 1024
    ) {
        logger = Logger(subsystem: Constants.bundleIdentifier, category: "DecisionHistory")
        fileURL = testFileURL
        aggregateFileURL = testAggregateFileURL
            ?? testFileURL.deletingLastPathComponent().appendingPathComponent("decision-aggregates.json")
        self.aggregateMemoryCap = aggregateMemoryCap
        self.aggregateFileSizeCap = aggregateFileSizeCap
    }

    func waitForPendingWritesForTesting() {
        ioQueue.sync {}
    }
    #endif

    func bootstrap() {
        let aggregateRevisionAtStart = aggregateRevision
        aggregateSnapshotsInFlight.append(aggregateRevisionAtStart)
        ioQueue.async { [weak self] in
            guard let self else { return }
            let snapshotStartedAt = Date()
            let pruneResult = pruneDiskSync(forceRetention: true)
            let loaded = pruneResult?.entries ?? loadEntriesSync()
            let loadedAggregates = pruneResult?.aggregates ?? loadAggregatesSync()
            DispatchQueue.main.async {
                self.replaceMemory(with: loaded, preservingEntriesAfter: pruneResult?.snapshotStartedAt ?? snapshotStartedAt)
                self.replaceAggregateMemory(
                    with: loadedAggregates,
                    preservingMutationsAfter: aggregateRevisionAtStart
                )
                self.logger.notice("Decision history bootstrapped with \(loaded.count, privacy: .public) entries")
            }
        }
    }

    func record(_ entry: AutoFixDecisionObservation) {
        guard isEnabled else { return }
        guard entry.reason != AutoFixSkipReason.blocklist.rawValue else { return }

        guard entry.isReviewableSignal else {
            recordAggregate(for: entry)
            return
        }

        if Thread.isMainThread {
            insertIntoMemory(entry)
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.insertIntoMemory(entry)
            }
        }

        ioQueue.async { [weak self] in
            self?.appendToDisk(entry)
        }
    }

    func clearAll() {
        entries = []
        aggregates = []
        recordAggregateReplacementMutation()
        ioQueue.async { [weak self] in
            guard let self else { return }
            try? FileManager.default.removeItem(at: fileURL)
            try? FileManager.default.removeItem(at: aggregateFileURL)
            logger.notice("Decision history cleared")
        }
    }

    func clear(
        where shouldRemove: @escaping (AutoFixDecisionObservation) -> Bool,
        aggregateWhere shouldRemoveAggregate: ((AutoFixDecisionAggregate) -> Bool)? = nil
    ) {
        let remaining = entries.filter { !shouldRemove($0) }
        entries = remaining
        if let shouldRemoveAggregate {
            aggregates.removeAll(where: shouldRemoveAggregate)
            recordAggregateReplacementMutation()
        }
        ioQueue.async { [weak self] in
            guard let self else { return }
            let allRemaining = loadAllEntriesSync().filter { !shouldRemove($0) }
            rewriteDisk(with: allRemaining)
            if let shouldRemoveAggregate {
                let remainingAggregates = loadAggregatesSync().filter { !shouldRemoveAggregate($0) }
                rewriteAggregates(with: remainingAggregates)
            }
        }
    }

    func pruneByRetentionAsync() {
        let aggregateRevisionAtStart = aggregateRevision
        aggregateSnapshotsInFlight.append(aggregateRevisionAtStart)
        ioQueue.async { [weak self] in
            guard let self else { return }
            let snapshotStartedAt = Date()
            let pruneResult = pruneDiskSync(forceRetention: true)
            let loaded = pruneResult?.entries ?? loadEntriesSync()
            let loadedAggregates = pruneResult?.aggregates ?? loadAggregatesSync()
            DispatchQueue.main.async {
                self.replaceMemory(with: loaded, preservingEntriesAfter: pruneResult?.snapshotStartedAt ?? snapshotStartedAt)
                self.replaceAggregateMemory(
                    with: loadedAggregates,
                    preservingMutationsAfter: aggregateRevisionAtStart
                )
            }
        }
    }

    func loadEntriesSync() -> [AutoFixDecisionObservation] {
        loadAllEntriesSync()
    }

    private func loadAllEntriesSync() -> [AutoFixDecisionObservation] {
        guard let data = try? Data(contentsOf: fileURL),
              let text = String(data: data, encoding: .utf8) else {
            return []
        }
        var result = text.split(separator: "\n").compactMap { line -> AutoFixDecisionObservation? in
            guard let data = line.data(using: .utf8) else { return nil }
            return try? decoder.decode(AutoFixDecisionObservation.self, from: data)
        }
        result.sort { $0.timestamp > $1.timestamp }
        return result
    }

    private func insertIntoMemory(_ entry: AutoFixDecisionObservation) {
        let insertionIndex = entries.firstIndex { $0.timestamp <= entry.timestamp } ?? entries.endIndex
        entries.insert(entry, at: insertionIndex)
        enforceMemoryCap()
    }

    private func recordAggregate(for entry: AutoFixDecisionObservation) {
        let aggregate = AutoFixDecisionAggregate(observation: entry)
        if Thread.isMainThread {
            mergeAggregateIntoMemory(aggregate)
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.mergeAggregateIntoMemory(aggregate)
            }
        }
        ioQueue.async { [weak self] in
            self?.mergeAggregateOnDisk(aggregate)
        }
    }

    private func mergeAggregateIntoMemory(_ aggregate: AutoFixDecisionAggregate) {
        aggregateRevision += 1
        if !aggregateSnapshotsInFlight.isEmpty {
            aggregateMemoryMutations.append(.add(revision: aggregateRevision, aggregate: aggregate))
        }
        if let index = aggregates.firstIndex(where: { $0.id == aggregate.id }) {
            aggregates[index].count += aggregate.count
        } else {
            aggregates.append(aggregate)
        }
        aggregates = boundedAggregates(aggregates)
    }

    private func replaceMemory(
        with diskEntries: [AutoFixDecisionObservation],
        preservingEntriesAfter snapshotStartedAt: Date
    ) {
        let diskIDs = Set(diskEntries.map(\.id))
        let pendingEntries = entries.filter {
            $0.timestamp > snapshotStartedAt && !diskIDs.contains($0.id)
        }
        entries = (pendingEntries + diskEntries).sorted { $0.timestamp > $1.timestamp }
        enforceMemoryCap()
    }

    private func enforceMemoryCap() {
        guard entries.count > memoryCap else { return }
        entries.removeLast(entries.count - memoryCap)
    }

    private func recordAggregateReplacementMutation() {
        aggregateRevision += 1
        if !aggregateSnapshotsInFlight.isEmpty {
            aggregateMemoryMutations.append(.replace(
                revision: aggregateRevision,
                aggregates: aggregates
            ))
        }
    }

    private func replaceAggregateMemory(
        with diskAggregates: [AutoFixDecisionAggregate],
        preservingMutationsAfter revision: Int
    ) {
        var merged = diskAggregates
        for mutation in aggregateMemoryMutations where mutation.revision > revision {
            switch mutation {
            case .add(_, let aggregate):
                if let index = merged.firstIndex(where: { $0.id == aggregate.id }) {
                    merged[index].count += aggregate.count
                } else {
                    merged.append(aggregate)
                }
            case .replace(_, let replacement):
                merged = replacement
            }
        }
        aggregates = boundedAggregates(merged)
        if let index = aggregateSnapshotsInFlight.firstIndex(of: revision) {
            aggregateSnapshotsInFlight.remove(at: index)
        }
        if let oldestSnapshotRevision = aggregateSnapshotsInFlight.min() {
            aggregateMemoryMutations.removeAll { $0.revision <= oldestSnapshotRevision }
        } else {
            aggregateMemoryMutations.removeAll(keepingCapacity: true)
        }
    }

    private func appendToDisk(_ entry: AutoFixDecisionObservation) {
        do {
            var line = try encoder.encode(entry)
            line.append(0x0A)
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                try line.write(to: fileURL)
            } else {
                let handle = try FileHandle(forWritingTo: fileURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
            }
            if let retained = pruneDiskSync() {
                DispatchQueue.main.async { [weak self] in
                    self?.replaceMemory(
                        with: retained.entries,
                        preservingEntriesAfter: retained.snapshotStartedAt
                    )
                }
            }
        } catch {
            logger.warning("Decision history append failed: \(error.localizedDescription, privacy: .private)")
        }
    }

    private func rewriteDisk(with entries: [AutoFixDecisionObservation]) {
        do {
            guard !entries.isEmpty else {
                try? FileManager.default.removeItem(at: fileURL)
                return
            }
            var data = Data()
            for entry in entries.reversed() {
                data.append(try encoder.encode(entry))
                data.append(0x0A)
            }
            try data.write(to: fileURL, options: .atomic)
        } catch {
            logger.warning("Decision history rewrite failed: \(error.localizedDescription, privacy: .private)")
        }
    }

    private func loadAggregatesSync() -> [AutoFixDecisionAggregate] {
        guard let data = try? Data(contentsOf: aggregateFileURL) else { return [] }
        return (try? decoder.decode([AutoFixDecisionAggregate].self, from: data)) ?? []
    }

    private func mergeAggregateOnDisk(_ aggregate: AutoFixDecisionAggregate) {
        var stored = loadAggregatesSync()
        if let index = stored.firstIndex(where: { $0.id == aggregate.id }) {
            stored[index].count += aggregate.count
        } else {
            stored.append(aggregate)
        }
        rewriteAggregates(with: stored)
    }

    private func rewriteAggregates(with aggregates: [AutoFixDecisionAggregate]) {
        do {
            let bounded = boundedAggregates(aggregates)
            guard !bounded.isEmpty else {
                try? FileManager.default.removeItem(at: aggregateFileURL)
                return
            }
            try encoder.encode(bounded).write(to: aggregateFileURL, options: .atomic)
        } catch {
            logger.warning("Decision aggregate rewrite failed: \(error.localizedDescription, privacy: .private)")
        }
    }

    private func boundedAggregates(
        _ aggregates: [AutoFixDecisionAggregate],
        targetBytes: Int? = nil
    ) -> [AutoFixDecisionAggregate] {
        let sorted = aggregates.sorted { lhs, rhs in
            if lhs.day != rhs.day { return lhs.day > rhs.day }
            return lhs.id < rhs.id
        }
        let countBounded = Array(sorted.prefix(aggregateMemoryCap))
        let maximumBytes = targetBytes ?? aggregateFileSizeCap
        guard (try? encoder.encode(countBounded).count) ?? 0 > maximumBytes else {
            return countBounded
        }

        var lowerBound = 0
        var upperBound = countBounded.count
        while lowerBound < upperBound {
            let candidateCount = (lowerBound + upperBound + 1) / 2
            let candidate = Array(countBounded.prefix(candidateCount))
            if ((try? encoder.encode(candidate).count) ?? Int.max) <= maximumBytes {
                lowerBound = candidateCount
            } else {
                upperBound = candidateCount - 1
            }
        }
        return Array(countBounded.prefix(lowerBound))
    }

    private func pruneDiskSync(forceRetention: Bool = false) -> DiskPruneResult? {
        guard FileManager.default.fileExists(atPath: fileURL.path)
                || FileManager.default.fileExists(atPath: aggregateFileURL.path)
        else { return nil }
        let now = Date()
        let cutoff = retention.timeInterval.map { now.addingTimeInterval(-$0) }
        let retentionIsDue = cutoff != nil && (
            forceRetention
                || lastRetentionPruneAt.map { now.timeIntervalSince($0) >= retentionPruneInterval } != false
        )
        let decisionFileSize = ((try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size]) as? NSNumber)?.intValue ?? 0
        let aggregateFileSize = ((try? FileManager.default.attributesOfItem(atPath: aggregateFileURL.path)[.size]) as? NSNumber)?.intValue ?? 0
        let fileCapExceeded = decisionFileSize > fileSizeCap
        let aggregateFileCapExceeded = aggregateFileSize > aggregateFileSizeCap
        let aggregateCountCapExceeded = loadAggregatesSync().count > aggregateMemoryCap
        guard retentionIsDue
                || fileCapExceeded
                || aggregateFileCapExceeded
                || aggregateCountCapExceeded
                || (forceRetention && cutoff == nil)
        else { return nil }

        let allEntries = loadAllEntriesSync()
        var kept = cutoff.map { cutoff in
            allEntries.filter { $0.timestamp >= cutoff }
        } ?? allEntries
        if fileCapExceeded {
            let targetBytes = fileSizeCap / 2
            var retainedBytes = 0
            kept = Array(kept.prefix { entry in
                guard let encoded = try? encoder.encode(entry) else { return false }
                let nextSize = encoded.count + 1
                guard retainedBytes + nextSize <= targetBytes else { return false }
                retainedBytes += nextSize
                return true
            })
        }
        let allAggregates = loadAggregatesSync()
        let retentionBoundedAggregates = cutoff.map { cutoff in
            allAggregates.filter { $0.day >= Calendar.current.startOfDay(for: cutoff) }
        } ?? allAggregates
        let keptAggregates = boundedAggregates(
            retentionBoundedAggregates,
            targetBytes: aggregateFileCapExceeded ? aggregateFileSizeCap / 2 : nil
        )
        if kept.count != allEntries.count || fileCapExceeded {
            rewriteDisk(with: kept)
        }
        if keptAggregates != allAggregates || aggregateFileCapExceeded || aggregateCountCapExceeded {
            rewriteAggregates(with: keptAggregates)
        }
        lastRetentionPruneAt = now
        return DiskPruneResult(entries: kept, aggregates: keptAggregates, snapshotStartedAt: now)
    }
}
