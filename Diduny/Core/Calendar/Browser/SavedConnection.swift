import Foundation

public struct SavedConnection: Codable, Equatable, Sendable {
    public var version = 1
    public let windowName: String
    public let browserID: String
    public let profileName: String
    public let calendarURL: URL
    public let consentedAt: Date
    public init(browserID: String, profileName: String, calendarURL: URL, consentedAt: Date = Date(), windowName: String = "Diduny Calendar · " + UUID().uuidString) {
        self.windowName = windowName; self.browserID = browserID; self.profileName = profileName; self.calendarURL = calendarURL; self.consentedAt = consentedAt
    }
    public func validate() throws {
        guard version == 1, !browserID.isEmpty, !profileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              CalendarPage.provider(for: calendarURL) != nil,
              calendarURL.query == nil, calendarURL.fragment == nil,
              calendarURL.path.range(of: #"^/calendar(?:/u/[0-9]+)?(?:/r(?:/(?:day|week|month|agenda|custom/[0-9]+))?|/view/(?:day|week|workweek|month))?/?$"#, options: .regularExpression) != nil,
              windowName.hasPrefix("Diduny Calendar · "), UUID(uuidString: String(windowName.dropFirst("Diduny Calendar · ".count))) != nil else { throw CocoaError(.coderInvalidValue) }
    }
    public static func matchesWindowTitle(_ title: String, name: String) -> Bool {
        title == name || title.hasPrefix(name + " - ") || title.hasPrefix(name + " – ")
    }
    public func matchingCandidate(urls: [URL], profiles: [String?], windowTitles: [String]) -> Int? {
        guard (try? validate()) != nil, urls.count == profiles.count, urls.count == windowTitles.count else { return nil }
        let matches = urls.indices.filter { urls[$0] == calendarURL && profiles[$0] == profileName && Self.matchesWindowTitle(windowTitles[$0], name: windowName) }
        return matches.count == 1 ? matches[0] : nil
    }
}

public struct ConnectionStore {
    public let file: URL
    public init(directory: URL) { file = directory.appendingPathComponent("connection.json") }
    public func load() throws -> SavedConnection? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let saved = try JSONDecoder().decode(SavedConnection.self, from: Data(contentsOf: file))
        try saved.validate()
        return saved
    }
    public func save(_ connection: SavedConnection) throws {
        try connection.validate()
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(connection).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    public func clear() throws {
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
    }
}
