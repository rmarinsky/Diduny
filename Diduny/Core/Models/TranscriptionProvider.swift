import Foundation

enum TranscriptionProvider: String, CaseIterable, Identifiable {
    case cloud
    case local

    var id: String {
        rawValue
    }
}
