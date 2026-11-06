import Foundation

/// Download state of one local model, as the Local models actions cell reads it (changes/04 §3).
enum ModelDownloadState: Equatable {
    case notDownloaded
    /// 0...1.
    case downloading(Double)
    case downloaded
    /// The download stopped with an error (plan 2.2 default for 04 Q7: "Failed" + "Retry").
    case failed(String)
}

/// The Whisper models on disk and the one Active model (test-plan 2.5).
@MainActor
protocol WhisperModelStoring: AnyObject {
    func state(of model: WhisperModelManager.WhisperModel) -> ModelDownloadState
    /// `SettingsStorage.selectedWhisperModel`; "" when no model is Active.
    var selectedModelName: String { get set }
    func download(_ model: WhisperModelManager.WhisperModel)
    func cancel(_ model: WhisperModelManager.WhisperModel)
    /// Deletes the file; deleting the Active model leaves none Active.
    func delete(_ model: WhisperModelManager.WhisperModel)
}

/// Parakeet V3 on this Mac (test-plan 2.5).
@MainActor
protocol ParakeetModelStoring: AnyObject {
    var isSupportedHardware: Bool { get }
    var state: ModelDownloadState { get }
    func download()
    func cancel()
    func delete()
}

/// Production Whisper store: `WhisperModelManager` plus the selection in `SettingsStorage`.
@MainActor
@Observable
final class WhisperModelManagerStore: WhisperModelStoring {
    private let manager: WhisperModelManager
    @ObservationIgnored private let settings: SettingsStorage
    /// `UserDefaults` is not observable; bumped on every write so the table redraws.
    private var selectionRevision = 0

    init(manager: WhisperModelManager = .shared, settings: SettingsStorage = .shared) {
        self.manager = manager
        self.settings = settings
    }

    func state(of model: WhisperModelManager.WhisperModel) -> ModelDownloadState {
        if manager.isDownloading[model.name] == true {
            return .downloading(manager.downloadProgress[model.name] ?? 0)
        }
        if manager.isModelDownloaded(model) { return .downloaded }
        if let error = manager.downloadErrors[model.name] { return .failed(error) }
        return .notDownloaded
    }

    var selectedModelName: String {
        get {
            _ = selectionRevision
            return settings.selectedWhisperModel
        }
        set {
            settings.selectedWhisperModel = newValue
            selectionRevision += 1
        }
    }

    func download(_ model: WhisperModelManager.WhisperModel) {
        manager.downloadModel(model)
        selectionRevision += 1
    }

    func cancel(_ model: WhisperModelManager.WhisperModel) {
        manager.cancelDownload(model)
    }

    func delete(_ model: WhisperModelManager.WhisperModel) {
        manager.deleteModel(model)
        if selectedModelName == model.name { selectedModelName = "" }
        selectionRevision += 1
    }
}
