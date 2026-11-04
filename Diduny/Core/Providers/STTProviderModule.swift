import Foundation

/// Stable provider identifiers. Persisted in settings and the remote-deletion queue.
enum STTProviderID {
    static let didunyCloud = "diduny-cloud"
    static let localWhisper = "local-whisper"
}

/// The four user-facing jobs that each have their own default provider + model.
enum STTJob: String, CaseIterable, Codable, Sendable {
    case dictation
    case dictationTranslation
    case meeting
    case file
}

struct TranslationCaps: Equatable, Sendable {
    var oneWay: Bool
    var twoWay: Bool
}

struct BatchCaps: Equatable, Sendable {
    /// nil = unknown; the router chunks conservatively.
    var maxDurationSeconds: TimeInterval?
    var maxFileBytes: Int64?
    var diarization: Bool
    var maxSpeakers: Int?
    var translation: TranslationCaps?
}

struct RealtimeCaps: Equatable, Sendable {
    /// nil = unknown; the session reconnects with context when the provider closes it.
    var maxSessionSeconds: TimeInterval?
    var idleTimeoutSeconds: TimeInterval?
    var diarization: Bool
    var manualCommit: Bool
    var translation: TranslationCaps?
}

enum LanguageSupport: Equatable, Sendable {
    case all
    case set(Set<String>)

    func supports(_ code: String) -> Bool {
        let code = code.lowercased()
        if code == "auto" { return true }
        switch self {
        case .all: return true
        case let .set(codes): return codes.contains(code)
        }
    }
}

/// What the provider does with transcripts after use.
enum RemoteDeletionSupport: Equatable, Sendable {
    /// The provider stores a transcript that can be deleted by its id.
    case byID
    /// Not verified yet; nothing is deleted and nothing is claimed.
    case unverified
    /// The provider keeps the data; the UI shows a "keeps your data" notice.
    case none
}

struct STTModelCapabilities: Equatable, Sendable {
    var batch: BatchCaps?
    var realtime: RealtimeCaps?
    var languages: LanguageSupport
    var autoLanguageDetection: Bool
    var batchDeletion: RemoteDeletionSupport
    var realtimeDeletion: RemoteDeletionSupport
}

struct STTModel: Equatable, Sendable {
    let id: String
    let displayName: String
    let capabilities: STTModelCapabilities
}

/// One provider = one module. Routing and UI read only `models[].capabilities`, never the provider id.
protocol STTProviderModule: Sendable {
    var id: String { get }
    var displayName: String { get }
    /// true for bring-your-own-key providers; their models are offered only when a key is stored.
    var requiresKey: Bool { get }
    var models: [STTModel] { get }
}

struct ProviderRegistry: Sendable {
    /// Provider modules are added here (one line per provider) as they are implemented.
    static let shared = ProviderRegistry(modules: [DidunyCloudProvider(), LocalWhisperProvider(), ElevenLabsProvider()])

    let modules: [any STTProviderModule]

    func module(id: String) -> (any STTProviderModule)? {
        modules.first { $0.id == id }
    }

    var providerIDs: Set<String> {
        Set(modules.map(\.id)).union([STTProviderID.didunyCloud, STTProviderID.localWhisper])
    }
}
