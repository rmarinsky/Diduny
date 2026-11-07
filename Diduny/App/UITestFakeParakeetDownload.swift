#if TEST_BUILD
    import Foundation

    /// `--ui-testing-fake-downloads` with `--ui-testing-parakeet=missing|downloaded|unsupported` (test-plan 2.2):
    /// the Parakeet V3 download reports progress only on bridge `download.advance` (`percent`) and fails
    /// on `download.fail`. Nothing touches the network or disk.
    @MainActor
    final class UITestFakeParakeetDownload {
        static let shared = UITestFakeParakeetDownload()
        struct Failure: LocalizedError {
            var errorDescription: String? { "UI test download failure" }
        }

        private(set) var isDownloaded = UITestHarness.value(of: "--ui-testing-parakeet") == "downloaded"
        private var progress: (@Sendable (Double) -> Void)?
        private var continuation: CheckedContinuation<Void, Error>?

        static func makeController() -> ParakeetModelController? {
            guard UITestHarness.has("--ui-testing-fake-downloads") else { return nil }
            let fake = shared
            return ParakeetModelController(
                isSupportedHardware: UITestHarness.value(of: "--ui-testing-parakeet") != "unsupported",
                isDownloaded: { MainActor.assumeIsolated { fake.isDownloaded } },
                load: { progress in try await fake.run(progress) },
                remove: { await MainActor.run { fake.isDownloaded = false } }
            )
        }

        func run(_ progress: @escaping @Sendable (Double) -> Void) async throws {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    self.progress = progress
                    self.continuation = continuation
                }
            } onCancel: {
                Task { @MainActor in UITestFakeParakeetDownload.shared.resume(throwing: CancellationError()) }
            }
        }

        func advance(to value: Double) {
            progress?(min(value, 1))
            guard value >= 1 else { return }
            isDownloaded = true
            resume(throwing: nil)
        }

        func fail() {
            resume(throwing: Failure())
        }

        private func resume(throwing error: Error?) {
            guard let continuation else { return }
            self.continuation = nil
            progress = nil
            if let error { continuation.resume(throwing: error) } else { continuation.resume() }
        }
    }
#endif
