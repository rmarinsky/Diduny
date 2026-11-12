import Foundation

/// Anonymous daily counters of which features run and how they were triggered.
///
/// Counts are kept per UTC day in UserDefaults and sent once the day is over, as
/// daily totals the server stores without any account reference. The request is
/// signed in (the endpoint only takes counts from Diduny accounts, against abuse);
/// Settings says so next to the toggle. Nothing else
/// (no text, no timing, no engine) is counted. Off when the user turns off
/// "Share anonymous feature usage"; turning it off also drops unsent counts.
@MainActor
final class FeatureUsageCounter {
    enum Feature: String, CaseIterable {
        case dictation, translation, meeting
        case meetingTranslation = "meeting_translation"
        case fileTranscription = "file_transcription"
        case selectionTranslation = "selection_translation"
        case textTranslation = "text_translation"
        case historyPalette = "history_palette"
        case chapterMarker = "chapter_marker"
        case exportDiagnostics = "export_diagnostics"
    }

    enum Trigger: String {
        case hotkey
        case pushToTalk = "push_to_talk"
        case menu, panel, palette, settings, other
    }

    static let shared = FeatureUsageCounter()

    private static let storageKey = "featureUsage.pendingDays"
    private let defaults: UserDefaults
    private let isEnabled: @MainActor () -> Bool
    private let isSignedIn: @MainActor () -> Bool
    private let transport: BillingService.Transport
    private let baseURL: @MainActor () -> String
    private let now: () -> Date
    private var isFlushing = false

    init(
        defaults: UserDefaults = .standard,
        isEnabled: @escaping @MainActor () -> Bool = { SettingsStorage.shared.shareFeatureUsage },
        isSignedIn: @escaping @MainActor () -> Bool = { AuthService.shared.isLoggedIn },
        baseURL: @escaping @MainActor () -> String = { SettingsStorage.shared.proxyBaseURL },
        transport: @escaping BillingService.Transport = { try await AuthService.shared.performWithAuth($0) },
        now: @escaping () -> Date = Date.init
    ) {
        self.defaults = defaults
        self.isEnabled = isEnabled
        self.isSignedIn = isSignedIn
        self.baseURL = baseURL
        self.transport = transport
        self.now = now
    }

    /// [day: ["feature|trigger": count]]
    var pending: [String: [String: Int]] {
        defaults.dictionary(forKey: Self.storageKey) as? [String: [String: Int]] ?? [:]
    }

    func record(_ feature: Feature, via trigger: Trigger) {
        DiagnosticLog.shared.record(.featureUsed, [.feature: .string(feature.rawValue), .trigger: .string(trigger.rawValue)])
        guard isEnabled() else { return }
        let today = Self.day(now())
        var days = pending
        days[today, default: [:]]["\(feature.rawValue)|\(trigger.rawValue)", default: 0] += 1
        // Keep at most 31 days while signed out or offline; the server rejects older days.
        for day in days.keys.sorted().dropLast(31) { days[day] = nil }
        defaults.set(days, forKey: Self.storageKey)
        if days.keys.contains(where: { $0 < today }) { Task { await flush() } }
    }

    func discardPending() {
        defaults.removeObject(forKey: Self.storageKey)
    }

    /// Sends finished days; a day that the server rejects as invalid is dropped, one that fails to send is kept.
    func flush() async {
        guard !isFlushing else { return }
        guard isEnabled() else { discardPending(); return }
        guard isSignedIn() else { return }
        isFlushing = true
        defer { isFlushing = false }
        let today = Self.day(now())
        for (day, counts) in pending where day < today {
            let status = await send(day: day, counts: counts)
            guard status != nil else { continue }
            var days = pending
            days[day] = nil
            defaults.set(days, forKey: Self.storageKey)
        }
    }

    private func send(day: String, counts: [String: Int]) async -> Int? {
        struct Item: Encodable { let feature: String; let trigger: String; let count: Int }
        struct Batch: Encodable { let appVersion: String; let day: String; let counts: [Item] }
        let items = counts.compactMap { key, count -> Item? in
            let parts = key.split(separator: "|").map(String.init)
            guard parts.count == 2, count > 0 else { return nil }
            return Item(feature: parts[0], trigger: parts[1], count: min(count, 1000))
        }
        guard !items.isEmpty,
              let url = URL(string: baseURL().trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/api/v1/feature-usage")
        else { return 400 }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(Batch(
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0",
            day: day,
            counts: Array(items.prefix(100))
        ))
        guard let (_, response) = try? await transport(request) else { return nil }
        // 2xx sent; 400 can never succeed; 401/429/5xx retry on a later launch.
        return response.statusCode < 300 || response.statusCode == 400 ? response.statusCode : nil
    }

    nonisolated static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
