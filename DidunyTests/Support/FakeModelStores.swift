@testable import Diduny
import Foundation

/// In-memory Whisper store (test-plan 2.5): downloaded, progress, cancel, delete, failure.
@MainActor
final class FakeWhisperModelStore: WhisperModelStoring {
    var states: [String: ModelDownloadState] = [:]
    var selectedModelName = ""
    private(set) var cancelled: [String] = []
    private(set) var deleted: [String] = []

    init(_ states: [String: ModelDownloadState] = [:], active: String = "") {
        self.states = states
        selectedModelName = active
    }

    func state(of model: WhisperModelManager.WhisperModel) -> ModelDownloadState {
        states[model.name] ?? .notDownloaded
    }

    func download(_ model: WhisperModelManager.WhisperModel) { states[model.name] = .downloading(0) }
    func progress(_ name: String, _ value: Double) { states[name] = .downloading(value) }
    func complete(_ name: String) {
        states[name] = .downloaded
        if selectedModelName.isEmpty { selectedModelName = name }
    }

    func fail(_ name: String, _ message: String) { states[name] = .failed(message) }

    func cancel(_ model: WhisperModelManager.WhisperModel) {
        cancelled.append(model.name)
        states[model.name] = .notDownloaded
    }

    func delete(_ model: WhisperModelManager.WhisperModel) {
        deleted.append(model.name)
        states[model.name] = .notDownloaded
        if selectedModelName == model.name { selectedModelName = "" }
    }
}

/// In-memory Parakeet store for the table model; `ParakeetModelControllerTests` covers the real one.
@MainActor
final class FakeParakeetModelStore: ParakeetModelStoring {
    var isSupportedHardware: Bool
    var state: ModelDownloadState
    private(set) var cancelCount = 0
    private(set) var deleteCount = 0

    init(_ state: ModelDownloadState = .downloaded, isSupportedHardware: Bool = true) {
        self.state = state
        self.isSupportedHardware = isSupportedHardware
    }

    func download() { state = .downloading(0) }
    func cancel() {
        cancelCount += 1
        state = .notDownloaded
    }

    func delete() {
        deleteCount += 1
        state = .notDownloaded
    }
}
