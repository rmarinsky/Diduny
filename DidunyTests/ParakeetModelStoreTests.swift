@testable import Diduny
import Foundation
import Testing

/// A download the test drives: it reports progress and finishes only when told.
@MainActor
private final class ControlledLoad {
    var progress: (@Sendable (Double) -> Void)?
    private var continuation: CheckedContinuation<Void, Error>?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    var onDisk = false
    private(set) var removeCount = 0

    func run(_ progress: @escaping @Sendable (Double) -> Void) async throws {
        self.progress = progress
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                startWaiters.forEach { $0.resume() }
                startWaiters = []
            }
        } onCancel: {
            Task { @MainActor in self.resume(throwing: CancellationError()) }
        }
    }

    func started() async {
        if continuation != nil { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func finish() {
        onDisk = true
        resume(throwing: nil)
    }

    func resume(throwing error: Error?) {
        guard let continuation else { return }
        self.continuation = nil
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
    }

    func remove() {
        removeCount += 1
        onDisk = false
    }

    func controller(supported: Bool = true) -> ParakeetModelController {
        ParakeetModelController(
            isSupportedHardware: supported,
            isDownloaded: { [unowned self] in onDisk },
            load: { [unowned self] progress in try await run(progress) },
            remove: { [unowned self] in remove() }
        )
    }
}

/// A download that ignores cancellation and keeps writing until the test lets it end.
@MainActor
private final class StubbornLoad {
    private var continuation: CheckedContinuation<Void, Never>?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var removeCount = 0
    private(set) var removedWhileWriting = false
    private var writing = false

    func controller() -> ParakeetModelController {
        ParakeetModelController(
            isSupportedHardware: true,
            isDownloaded: { false },
            load: { [unowned self] _ in await run() },
            remove: { [unowned self] in
                removeCount += 1
                if writing { removedWhileWriting = true }
            }
        )
    }

    private func run() async {
        writing = true
        await withCheckedContinuation { continuation = $0; startWaiters.forEach { $0.resume() }; startWaiters = [] }
        writing = false
    }

    func started() async {
        if continuation != nil { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func end() {
        continuation?.resume()
        continuation = nil
    }
}

private struct LoadFailure: LocalizedError {
    var errorDescription: String? { "No network" }
}

@MainActor
@Suite("Parakeet model controller: state, percent, cancel (T4-ROW-07)")
struct ParakeetModelStoreTests {
    @Test("Download reports percent and ends Ready")
    func download() async {
        let load = ControlledLoad()
        let controller = load.controller()
        #expect(controller.state == .notDownloaded)
        controller.download()
        #expect(controller.state == .downloading(0))
        await load.started()
        load.progress?(0.3)
        #expect(controller.state == .downloading(0.3))
        load.finish()
        await controller.pendingWork?.value
        #expect(controller.state == .downloaded)
    }

    @Test("Cancel returns to Download and removes the partial files; late progress is ignored")
    func cancel() async {
        let load = ControlledLoad()
        let controller = load.controller()
        controller.download()
        await load.started()
        let progress = load.progress
        controller.cancel()
        #expect(controller.state == .notDownloaded)
        await controller.pendingWork?.value
        #expect(load.removeCount == 1)
        progress?(0.9)
        #expect(controller.state == .notDownloaded)
    }

    @Test("A failed download shows the error")
    func failure() async {
        let load = ControlledLoad()
        let controller = load.controller()
        controller.download()
        await load.started()
        let work = controller.pendingWork
        load.resume(throwing: LoadFailure())
        await work?.value
        #expect(controller.state == .failed("No network"))
        controller.download()
        #expect(controller.state == .downloading(0))
    }

    @Test("Delete returns to Download")
    func delete() async {
        let load = ControlledLoad()
        load.onDisk = true
        let controller = load.controller()
        #expect(controller.state == .downloaded)
        controller.delete()
        #expect(controller.state == .notDownloaded)
        await controller.pendingWork?.value
        #expect(controller.state == .notDownloaded)
        #expect(load.removeCount == 1)
    }

    @Test("No download on an Intel Mac")
    func intel() {
        let controller = ControlledLoad().controller(supported: false)
        controller.download()
        #expect(controller.state == .notDownloaded)
    }

    @Test("Cancel removes files only after the cancelled download has stopped writing")
    func cancelWaitsForDownload() async {
        let load = StubbornLoad()
        let controller = load.controller()
        controller.download()
        await load.started()
        controller.cancel()
        #expect(controller.state == .notDownloaded)
        await Task.yield()
        #expect(load.removeCount == 0)
        load.end()
        await controller.pendingWork?.value
        #expect(load.removeCount == 1)
        #expect(!load.removedWhileWriting)
    }

    @Test("Delete during a download removes once, after the download ends")
    func deleteDuringDownload() async {
        let load = StubbornLoad()
        let controller = load.controller()
        controller.download()
        await load.started()
        controller.delete()
        load.end()
        await controller.pendingWork?.value
        #expect(load.removeCount == 1)
        #expect(!load.removedWhileWriting)
    }
}
