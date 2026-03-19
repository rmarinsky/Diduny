import Foundation

struct RemoteConfig: Codable {
    let version: Int?
    let featureFlags: FeatureFlags?
    let endpoints: Endpoints?
    let messages: Messages?

    struct FeatureFlags: Codable {
        let translationRealtimeSocketEnabled: Bool?
        let transcriptionRealtimeSocketEnabled: Bool?
        let meetingRealtimeTranscriptionEnabled: Bool?
        let textCleanupEnabled: Bool?
        let escapeCancelEnabled: Bool?
    }

    struct Endpoints: Codable {
        let sttBaseURL: String?
        let sttModel: String?
    }

    struct Messages: Codable {
        let maintenanceMessage: String?
        let updateAvailableMessage: String?
    }
}
