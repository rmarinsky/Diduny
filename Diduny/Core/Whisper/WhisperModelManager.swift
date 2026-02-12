import Foundation

@Observable
final class WhisperModelManager: NSObject {
    static let shared = WhisperModelManager()

    // MARK: - Model Catalog

    struct WhisperModel: Identifiable, Hashable {
        let name: String
        let displayName: String
        let sizeDescription: String
        let speed: Double // 0.0-1.0
        let accuracy: Double // 0.0-1.0
        let isEnglishOnly: Bool
        let ramUsage: String
        let description: String

        var id: String { name }

        var filename: String { "\(name).bin" }

        var downloadURL: URL {
            URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(filename)")!
        }
    }

    static let availableModels: [WhisperModel] = [
        WhisperModel(
            name: "ggml-tiny",
            displayName: "Tiny",
            sizeDescription: "75 MB",
            speed: 0.95,
            accuracy: 0.60,
            isEnglishOnly: false,
            ramUsage: "~0.3 GB",
            description: "Fastest model, suitable for quick drafts"
        ),
        WhisperModel(
            name: "ggml-tiny.en",
            displayName: "Tiny (English)",
            sizeDescription: "75 MB",
            speed: 0.95,
            accuracy: 0.65,
            isEnglishOnly: true,
            ramUsage: "~0.3 GB",
            description: "English-optimized tiny model"
        ),
        WhisperModel(
            name: "ggml-base",
            displayName: "Base",
            sizeDescription: "142 MB",
            speed: 0.85,
            accuracy: 0.72,
            isEnglishOnly: false,
            ramUsage: "~0.5 GB",
            description: "Good balance for everyday use"
        ),
        WhisperModel(
            name: "ggml-base.en",
            displayName: "Base (English)",
            sizeDescription: "142 MB",
            speed: 0.85,
            accuracy: 0.75,
            isEnglishOnly: true,
            ramUsage: "~0.5 GB",
            description: "English-optimized base model"
        ),
        WhisperModel(
            name: "ggml-small",
            displayName: "Small",
            sizeDescription: "466 MB",
            speed: 0.65,
            accuracy: 0.82,
            isEnglishOnly: false,
            ramUsage: "~1.0 GB",
            description: "Higher accuracy, moderate speed"
        ),
        WhisperModel(
            name: "ggml-small.en",
            displayName: "Small (English)",
            sizeDescription: "466 MB",
            speed: 0.65,
            accuracy: 0.85,
            isEnglishOnly: true,
            ramUsage: "~1.0 GB",
            description: "English-optimized small model"
        ),
        WhisperModel(
            name: "ggml-medium",
            displayName: "Medium",
            sizeDescription: "1.5 GB",
            speed: 0.45,
            accuracy: 0.90,
            isEnglishOnly: false,
            ramUsage: "~2.6 GB",
            description: "High accuracy for demanding tasks"
        ),
        WhisperModel(
            name: "ggml-medium.en",
            displayName: "Medium (English)",
            sizeDescription: "1.5 GB",
            speed: 0.45,
            accuracy: 0.92,
            isEnglishOnly: true,
            ramUsage: "~2.6 GB",
            description: "English-optimized medium model"
        ),
        WhisperModel(
            name: "ggml-large-v2",
            displayName: "Large v2",
            sizeDescription: "2.9 GB",
            speed: 0.30,
            accuracy: 0.96,
            isEnglishOnly: false,
            ramUsage: "~3.8 GB",
            description: "Very high accuracy, slower processing"
        ),
        WhisperModel(
            name: "ggml-large-v3",
            displayName: "Large v3",
            sizeDescription: "2.9 GB",
            speed: 0.30,
            accuracy: 0.98,
            isEnglishOnly: false,
            ramUsage: "~3.9 GB",
            description: "Best accuracy, slower processing"
        ),
        WhisperModel(
            name: "ggml-large-v3-turbo",
            displayName: "Large v3 Turbo",
            sizeDescription: "1.5 GB",
            speed: 0.75,
            accuracy: 0.97,
            isEnglishOnly: false,
            ramUsage: "~1.8 GB",
            description: "Best balance of accuracy and speed"
        ),
        WhisperModel(
            name: "ggml-large-v3-turbo-q5_0",
            displayName: "Large v3 Turbo (Q5)",
            sizeDescription: "547 MB",
            speed: 0.75,
            accuracy: 0.95,
            isEnglishOnly: false,
            ramUsage: "~1.0 GB",
            description: "Quantized turbo — great accuracy, small size"
        ),
    ]

    // MARK: - State

    var downloadProgress: [String: Double] = [:]
    var isDownloading: [String: Bool] = [:]
    var downloadedModels: Set<String> = []

    private var activeTasks: [String: URLSessionDownloadTask] = [:]
    private var progressObservations: [String: NSKeyValueObservation] = [:]

    // MARK: - Paths

    private var modelsDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Diduny/models")
    }

    override private init() {
        super.init()
        ensureModelsDirectory()
        refreshDownloadedModels()
    }

    // MARK: - Public API

    func modelPath(for model: WhisperModel) -> String {
        modelsDirectory.appendingPathComponent(model.filename).path
    }

    func isModelDownloaded(_ model: WhisperModel) -> Bool {
        downloadedModels.contains(model.name)
    }

    func selectedModel() -> WhisperModel? {
        let name = SettingsStorage.shared.selectedWhisperModel
        guard let model = Self.availableModels.first(where: { $0.name == name }) else { return nil }
        return isModelDownloaded(model) ? model : nil
    }

    func diskUsage(for model: WhisperModel) -> String? {
        let path = modelPath(for: model)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? UInt64
        else { return nil }
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }

    func downloadModel(_ model: WhisperModel) {
        guard activeTasks[model.name] == nil else { return }

        Log.whisper.info("Starting download: \(model.displayName)")
        isDownloading[model.name] = true
        downloadProgress[model.name] = 0

        let task = URLSession.shared.downloadTask(with: model.downloadURL) { [weak self] tempURL, response, error in
            let statusCode = (response as? HTTPURLResponse)?.statusCode
            let isOK = statusCode.map { (200 ... 299).contains($0) } ?? true
            DispatchQueue.main.async {
                if let statusCode, !isOK {
                    self?.handleDownloadCompletion(model: model, tempURL: nil, error: NSError(domain: "WhisperModelManager", code: statusCode, userInfo: [NSLocalizedDescriptionKey: "HTTP \(statusCode)"]))
                } else {
                    self?.handleDownloadCompletion(model: model, tempURL: tempURL, error: error)
                }
            }
        }

        // Observe progress
        let observation = task.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
            DispatchQueue.main.async {
                self?.downloadProgress[model.name] = progress.fractionCompleted
            }
        }
        progressObservations[model.name] = observation

        activeTasks[model.name] = task
        task.resume()
    }

    func cancelDownload(_ model: WhisperModel) {
        activeTasks[model.name]?.cancel()
        cleanupDownload(model)
    }

    func deleteModel(_ model: WhisperModel) {
        cancelDownload(model)
        let path = modelPath(for: model)
        try? FileManager.default.removeItem(atPath: path)
        downloadedModels.remove(model.name)

        // If deleted model was selected, clear selection
        if SettingsStorage.shared.selectedWhisperModel == model.name {
            SettingsStorage.shared.selectedWhisperModel = ""
        }

        Log.whisper.info("Deleted model: \(model.displayName)")
    }

    // MARK: - Private

    private func ensureModelsDirectory() {
        try? FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
    }

    private func refreshDownloadedModels() {
        downloadedModels = Set(Self.availableModels.compactMap { model in
            FileManager.default.fileExists(atPath: modelPath(for: model)) ? model.name : nil
        })
    }

    private func handleDownloadCompletion(model: WhisperModel, tempURL: URL?, error: Error?) {
        defer { cleanupDownload(model) }

        if let error {
            if (error as NSError).code == NSURLErrorCancelled { return }
            Log.whisper.error("Download failed for \(model.displayName): \(error.localizedDescription)")
            return
        }

        guard let tempURL else {
            Log.whisper.error("Download completed but no file URL for \(model.displayName)")
            return
        }

        let destination = modelsDirectory.appendingPathComponent(model.filename)
        do {
            // Remove existing file if present
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: tempURL, to: destination)
            downloadedModels.insert(model.name)

            // Auto-select if no model selected
            if SettingsStorage.shared.selectedWhisperModel.isEmpty {
                SettingsStorage.shared.selectedWhisperModel = model.name
            }

            Log.whisper.info("Download complete: \(model.displayName)")
        } catch {
            Log.whisper.error("Failed to save model \(model.displayName): \(error.localizedDescription)")
        }
    }

    private func cleanupDownload(_ model: WhisperModel) {
        progressObservations[model.name]?.invalidate()
        progressObservations[model.name] = nil
        activeTasks[model.name] = nil
        isDownloading[model.name] = false
        downloadProgress[model.name] = nil
    }
}
