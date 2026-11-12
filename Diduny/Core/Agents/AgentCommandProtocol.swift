import Foundation

/// Changes the `diduny` tool asks the app to make. The app is the only writer of the library and
/// the notes: the tool drops a command file into `AgentCommands/`, the app applies it on the main
/// actor and writes the answer to `AgentResults/<id>.json`. Shared by the app and the tool.
enum AgentCommandProtocol {
    static let inboxFolder = "AgentCommands"
    static let resultsFolder = "AgentResults"
    static let statusFile = "agent_status.json"

    struct Command: Codable, Equatable {
        enum Action: String, Codable, CaseIterable {
            /// Appends a block marked "Added by Claude" to the recording's notes.
            case addToNotes
            case writeNotes
            case addTags
            case removeTags
            case setProject
            case addPeople
            case removePeople
            case retranscribe
        }

        var id = UUID()
        var action: Action
        /// Full recording id.
        var recordingID: UUID
        /// Note text, tags, people or the project name, by action.
        var values: [String] = []
        /// Whisper model for `retranscribe`; nil uses the model chosen in Settings.
        var model: String?
        var createdAt = Date()
        /// Seconds since 1970 with fractions: commands sent within one second keep their order,
        /// which `createdAt` loses in ISO 8601. Nil in files from before it existed.
        var order: Double? = Date().timeIntervalSince1970

        var sortKey: Double { order ?? createdAt.timeIntervalSince1970 }
    }

    struct Result: Codable, Equatable {
        var commandID: UUID
        var ok: Bool
        var message: String
    }

    /// What the app is doing, written whenever it changes, for `diduny status`.
    struct Status: Codable, Equatable {
        struct Item: Codable, Equatable {
            var recordingID: UUID
            var title: String
            /// transcription, translation or notes.
            var kind: String
            /// onThisMac, cloud or notes.
            var lane: String
            var stage: String?
            var percent: Int?
        }

        var updatedAt: Date
        var working: [Item]
        var queuedRecordings: Int
        var queuedNotes: Int
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
