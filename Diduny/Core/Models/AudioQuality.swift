import Foundation

enum AudioQuality: String, CaseIterable, Codable {
    case high
    case medium
    case low

    var sampleRate: Double {
        switch self {
        case .high: 22050
        case .medium: 16000
        case .low: 12000
        }
    }

    var bitrate: Int {
        switch self {
        case .high: 64
        case .medium: 32
        case .low: 24
        }
    }

    var displayName: String {
        switch self {
        case .high: "High (22kHz, 64kbps)"
        case .medium: "Medium (16kHz, 32kbps)"
        case .low: "Low (12kHz, 24kbps)"
        }
    }
}
