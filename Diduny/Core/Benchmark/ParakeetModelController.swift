import Foundation

/// Observable download state of Parakeet V3 with percent and cancel (changes/04 §3, §10), shared
/// outside the Local models view. Wraps `ParakeetModelStore`; the operations are injected for tests.
@MainActor
@Observable
final class ParakeetModelController: ParakeetModelStoring {
    typealias Load = (@escaping @Sendable (Double) -> Void) async throws -> Void

    static let shared = ParakeetModelController()

    let isSupportedHardware: Bool
    private(set) var state: ModelDownloadState

    @ObservationIgnored private let isDownloaded: () -> Bool
    @ObservationIgnored private let load: Load
    @ObservationIgnored private let remove: () async throws -> Void
    @ObservationIgnored private var activeDownload: (id: UUID, task: Task<Void, Never>)?
    @ObservationIgnored private(set) var pendingWork: Task<Void, Never>?

    init(
        isSupportedHardware: Bool = ParakeetModelStore.isSupportedHardware,
        isDownloaded: @escaping () -> Bool = { ParakeetModelStore.isDownloaded },
        load: @escaping Load = { progress in _ = try await ParakeetModelStore.shared.loaded(progress: progress) },
        remove: @escaping () async throws -> Void = { try await ParakeetModelStore.shared.delete() }
    ) {
        self.isSupportedHardware = isSupportedHardware
        self.isDownloaded = isDownloaded
        self.load = load
        self.remove = remove
        state = isDownloaded() ? .downloaded : .notDownloaded
    }

    func download() {
        guard isSupportedHardware, activeDownload == nil, state != .downloaded else { return }
        let id = UUID()
        state = .downloading(0)
        let task = Task { [weak self, load] in
            do {
                try await load { value in
                    if Thread.isMainThread {
                        MainActor.assumeIsolated { self?.progress(value, id: id) }
                    } else {
                        Task { @MainActor in self?.progress(value, id: id) }
                    }
                }
                self?.finish(id: id, error: nil)
            } catch {
                self?.finish(id: id, error: error)
            }
        }
        activeDownload = (id, task)
        pendingWork = task
    }

    /// Stops the download; the partial files are removed, the cell returns to "Download".
    func cancel() {
        cancelDownload(thenRemove: true)
    }

    func delete() {
        // One removal, after any running download has stopped writing.
        let running = cancelDownload(thenRemove: false)
        state = .notDownloaded
        pendingWork = Task { [weak self, remove] in
            _ = await running?.value
            try? await remove()
            guard let self else { return }
            state = isDownloaded() ? .downloaded : .notDownloaded
        }
    }

    /// Cancels the running download; removal waits until the download task has ended,
    /// so it cannot race files the cancelled download is still writing.
    @discardableResult
    private func cancelDownload(thenRemove: Bool) -> Task<Void, Never>? {
        guard let activeDownload else { return nil }
        let task = activeDownload.task
        task.cancel()
        self.activeDownload = nil
        state = .notDownloaded
        if thenRemove {
            pendingWork = Task { [remove] in
                _ = await task.value
                try? await remove()
            }
        }
        return task
    }

    /// Re-reads the disk: the Benchmark tab can download Parakeet through `ParakeetModelStore` directly.
    func refresh() {
        guard activeDownload == nil else { return }
        if isDownloaded() { state = .downloaded } else if state == .downloaded { state = .notDownloaded }
    }

    private func progress(_ value: Double, id: UUID) {
        guard activeDownload?.id == id else { return }
        state = .downloading(min(max(value, 0), 1))
    }

    private func finish(id: UUID, error: Error?) {
        guard activeDownload?.id == id else { return }
        activeDownload = nil
        if let error, !(error is CancellationError) {
            state = .failed(error.localizedDescription)
        } else {
            state = isDownloaded() ? .downloaded : .notDownloaded
        }
    }
}
