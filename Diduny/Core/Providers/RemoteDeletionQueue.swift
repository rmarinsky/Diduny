import Foundation

/// One pending remote delete. Holds only ids and retry state: no transcript, audio or key.
struct PendingRemoteDelete: Codable, Equatable, Sendable {
    let providerID: String
    let remoteID: String
    var attempts: Int
    var nextAttemptAt: Date
}

enum RemoteDeleteResult: Equatable, Sendable {
    /// 2xx.
    case deleted
    /// 404: already gone, counts as done.
    case notFound
    /// 401/403: key can't delete; drop and notify once.
    case unauthorized
    /// 5xx, 429, network: keep with backoff.
    case retryLater
}

protocol RemoteTranscriptDeleter: Sendable {
    func deleteTranscript(remoteID: String, apiKey: String) async -> RemoteDeleteResult
}

/// Persisted queue of provider-side transcript deletes. Never blocks paste/save; callers enqueue and move on.
actor RemoteDeletionQueue {
    static let maxBackoffSeconds: TimeInterval = 3600
    static let baseBackoffSeconds: TimeInterval = 5

    private let fileURL: URL
    private let apiKey: @Sendable (String) -> String?
    private let deleters: [String: any RemoteTranscriptDeleter]
    private let now: @Sendable () -> Date
    private let onAuthFailure: @Sendable (String) -> Void
    private var notifiedProviders: Set<String> = []
    private(set) var pending: [PendingRemoteDelete]

    init(
        fileURL: URL,
        deleters: [String: any RemoteTranscriptDeleter],
        apiKey: @escaping @Sendable (String) -> String?,
        now: @escaping @Sendable () -> Date = { Date() },
        onAuthFailure: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.fileURL = fileURL
        self.deleters = deleters
        self.apiKey = apiKey
        self.now = now
        self.onAuthFailure = onAuthFailure
        if let data = try? Data(contentsOf: fileURL),
           let stored = try? JSONDecoder().decode([PendingRemoteDelete].self, from: data)
        {
            pending = stored
        } else {
            pending = []
        }
    }

    static var defaultFileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Diduny", isDirectory: true)
            .appendingPathComponent("pending-remote-deletes.json")
    }

    func enqueue(providerID: String, remoteID: String) {
        guard !pending.contains(where: { $0.providerID == providerID && $0.remoteID == remoteID }) else { return }
        pending.append(PendingRemoteDelete(providerID: providerID, remoteID: remoteID, attempts: 0, nextAttemptAt: now()))
        persist()
    }

    /// Call after a new valid key is saved so the next auth failure notifies again.
    func resetAuthNotice(for providerID: String) {
        notifiedProviders.remove(providerID)
    }

    /// Attempts every due entry whose provider has a key. Entries without a key are kept untouched.
    func process() async {
        for entry in pending where entry.nextAttemptAt <= now() {
            guard let deleter = deleters[entry.providerID], let key = apiKey(entry.providerID) else { continue }
            let result = await deleter.deleteTranscript(remoteID: entry.remoteID, apiKey: key)
            apply(result, to: entry)
        }
    }

    private func apply(_ result: RemoteDeleteResult, to entry: PendingRemoteDelete) {
        guard let index = pending.firstIndex(of: entry) else { return }
        switch result {
        case .deleted, .notFound:
            pending.remove(at: index)
        case .unauthorized:
            pending.remove(at: index)
            if notifiedProviders.insert(entry.providerID).inserted {
                onAuthFailure(entry.providerID)
            }
        case .retryLater:
            pending[index].attempts += 1
            let delay = min(Self.maxBackoffSeconds, Self.baseBackoffSeconds * pow(2, Double(pending[index].attempts - 1)))
            pending[index].nextAttemptAt = now().addingTimeInterval(delay)
        }
        persist()
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try JSONEncoder().encode(pending).write(to: fileURL, options: .atomic)
        } catch {
            // Queue stays in memory; next persist retries. No ids or content logged.
        }
    }
}
