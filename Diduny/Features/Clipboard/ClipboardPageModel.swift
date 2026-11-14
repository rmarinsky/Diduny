import Foundation
import Observation

/// The Clipboard page: search, filter, day groups and the `clipboard.` settings.
@MainActor
@Observable
final class ClipboardPageModel {
    enum Filter: String, CaseIterable, Identifiable {
        case all
        case text
        case screenshots
        case fromDiduny

        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: String(localized: "All")
            case .text: String(localized: "Text")
            case .screenshots: String(localized: "Screenshots")
            case .fromDiduny: String(localized: "From Diduny")
            }
        }

        func matches(_ entry: ClipboardEntry) -> Bool {
            switch self {
            case .all: true
            case .text: entry.kind == .text
            case .screenshots: entry.kind == .image
            case .fromDiduny: entry.kind == .diduny
            }
        }
    }

    struct Day: Identifiable, Equatable {
        /// Start of the day.
        let id: Date
        let title: String
        /// Newest first.
        let entries: [ClipboardEntry]
    }

    /// How long "Copy" reads "Copied".
    static let copiedDuration: Duration = .milliseconds(1200)

    @ObservationIgnored private let service: ClipboardHistoryService
    @ObservationIgnored private let settings: SettingsStorage
    @ObservationIgnored private let calendar: Calendar
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var copiedReset: Task<Void, Never>?

    var query = ""
    var filter = Filter.all
    /// "Clear" was clicked: the row shows "Clear everything" and "Keep".
    var isAskingToClear = false
    private(set) var copiedID: UUID?

    private(set) var retention: ClipboardRetention
    private(set) var keepScreenshots: Bool
    private(set) var keepDidunyPastes: Bool
    private(set) var skipPasswordManagers: Bool

    init(
        service: ClipboardHistoryService = .shared,
        settings: SettingsStorage = .shared,
        calendar: Calendar = .current,
        now: @escaping () -> Date = Date.init
    ) {
        self.service = service
        self.settings = settings
        self.calendar = calendar
        self.now = now
        retention = settings.clipboardRetention
        keepScreenshots = settings.clipboardKeepScreenshots
        keepDidunyPastes = settings.clipboardKeepDidunyPastes
        skipPasswordManagers = settings.clipboardSkipPasswordManagers
    }

    // MARK: - List

    var isEmpty: Bool { service.store.entries.isEmpty }

    var days: [Day] {
        Self.days(entries: service.store.entries, filter: filter, query: query, calendar: calendar, now: now())
    }

    func thumbnailURL(for entry: ClipboardEntry) -> URL? {
        service.store.thumbnailURL(for: entry)
    }

    /// The entries that pass the filter and the search, grouped by day, newest day first.
    static func days(entries: [ClipboardEntry], filter: Filter, query: String, calendar: Calendar, now: Date) -> [Day] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let visible = entries.filter { entry in
            filter.matches(entry) && (needle.isEmpty || searchText(for: entry).contains(needle))
        }
        let groups = Dictionary(grouping: visible) { calendar.startOfDay(for: $0.date) }
        return groups.keys.sorted(by: >).map { day in
            Day(
                id: day, title: dayTitle(day, calendar: calendar, now: now),
                entries: (groups[day] ?? []).sorted { $0.date > $1.date }
            )
        }
    }

    /// The full text plus the source line, so an app name finds every copy made in that app.
    static func searchText(for entry: ClipboardEntry) -> String {
        ((entry.text ?? title(for: entry)) + " " + caption(for: entry)).lowercased()
    }

    static func dayTitle(_ day: Date, calendar: Calendar, now: Date) -> String {
        let today = calendar.startOfDay(for: now)
        if day == today { return String(localized: "Today") }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: today), day == yesterday {
            return String(localized: "Yesterday")
        }
        var style = Date.FormatStyle(date: .abbreviated, time: .omitted)
        style.calendar = calendar
        style.timeZone = calendar.timeZone
        return day.formatted(style)
    }

    /// The row's one line: the text with line breaks as spaces, or the image's pixel size.
    static func title(for entry: ClipboardEntry) -> String {
        if entry.kind == .image {
            // As plain digits: a localized number would read "1,440".
            let width = String(entry.pixelWidth ?? 0)
            let height = String(entry.pixelHeight ?? 0)
            // Diduny cannot tell a screenshot from an image copied in an app.
            return entry.appName == nil
                ? String(localized: "Screenshot, \(width) × \(height)")
                : String(localized: "Image, \(width) × \(height)")
        }
        return (entry.text ?? "").prefix(400).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// The source line under the title.
    static func caption(for entry: ClipboardEntry) -> String {
        switch (entry.kind, entry.origin, entry.appName) {
        case let (.diduny, .translated, name?): String(localized: "Translated into \(name)")
        case (.diduny, .translated, nil): String(localized: "Translated")
        case let (.diduny, _, name?): String(localized: "Dictated into \(name)")
        case (.diduny, _, nil): String(localized: "Dictated")
        case let (_, _, name?): String(localized: "Copied in \(name)")
        case (.image, _, nil): String(localized: "Screenshot")
        case (.text, _, nil): String(localized: "Copied")
        }
    }

    static func time(for entry: ClipboardEntry) -> String {
        entry.date.formatted(date: .omitted, time: .shortened)
    }

    // MARK: - Row actions

    /// Puts the entry back on the clipboard. The list does not change.
    func copy(_ entry: ClipboardEntry) {
        guard service.copyToPasteboard(entry) else { return }
        copiedID = entry.id
        copiedReset?.cancel()
        copiedReset = Task { [weak self] in
            try? await Task.sleep(for: Self.copiedDuration)
            guard !Task.isCancelled else { return }
            self?.copiedID = nil
        }
    }

    func delete(_ entry: ClipboardEntry) {
        service.store.delete(id: entry.id)
    }

    func clearEverything() {
        service.store.clear()
        isAskingToClear = false
    }

    // MARK: - Settings

    /// A shorter value removes the older entries at once. "Never" stops the history and removes nothing.
    func setRetention(_ value: ClipboardRetention) {
        settings.clipboardRetention = value
        retention = value
        service.retentionChanged()
    }

    func setKeepScreenshots(_ value: Bool) {
        settings.clipboardKeepScreenshots = value
        keepScreenshots = value
    }

    func setKeepDidunyPastes(_ value: Bool) {
        settings.clipboardKeepDidunyPastes = value
        keepDidunyPastes = value
    }

    func setSkipPasswordManagers(_ value: Bool) {
        settings.clipboardSkipPasswordManagers = value
        skipPasswordManagers = value
    }
}
