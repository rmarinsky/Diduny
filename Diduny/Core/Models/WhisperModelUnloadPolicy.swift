import Foundation

enum WhisperModelUnloadPolicy: String, CaseIterable, Identifiable {
    case seconds30 = "30"
    case minutes1 = "60"
    case minutes2 = "120"
    case minutes5 = "300"
    case minutes10 = "600"
    case keepLoaded = "never"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .seconds30: "30 Seconds"
        case .minutes1: "1 Minute"
        case .minutes2: "2 Minutes"
        case .minutes5: "5 Minutes"
        case .minutes10: "10 Minutes"
        case .keepLoaded: "Keep Loaded"
        }
    }

    /// Returns the timeout interval, or `nil` for `.keepLoaded`.
    var timeInterval: TimeInterval? {
        switch self {
        case .seconds30: 30
        case .minutes1: 60
        case .minutes2: 120
        case .minutes5: 300
        case .minutes10: 600
        case .keepLoaded: nil
        }
    }
}
