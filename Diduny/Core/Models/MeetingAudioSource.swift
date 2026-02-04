import Foundation

enum MeetingAudioSource: String, Codable, CaseIterable {
    case systemOnly
    case systemPlusMicrophone

    var displayName: String {
        switch self {
        case .systemOnly:
            "System Audio Only"
        case .systemPlusMicrophone:
            "System + Microphone"
        }
    }

    var description: String {
        switch self {
        case .systemOnly:
            "Record only what you hear (meeting participants)"
        case .systemPlusMicrophone:
            "Record yourself and meeting participants"
        }
    }
}
