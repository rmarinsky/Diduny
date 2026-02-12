import Foundation

struct MeetingChapter: Identifiable, Codable, Equatable {
    let id: UUID
    let timestampSeconds: TimeInterval
    let label: String
    let createdAt: Date

    init(timestampSeconds: TimeInterval, label: String = "Chapter") {
        id = UUID()
        self.timestampSeconds = timestampSeconds
        self.label = label
        createdAt = Date()
    }
}
