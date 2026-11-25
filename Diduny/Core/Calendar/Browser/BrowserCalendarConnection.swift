import SwiftUI

@MainActor final class BrowserCalendarConnection: ObservableObject {
    static let shared = BrowserCalendarConnection()
    @Published var connected = false
    @Published var busy = false
    @Published var result: BrowserReadResult?
    @Published var message = String(localized: "Choose a browser and calendar profile.")
    @Published var reveal = true
    @Published var lastAttempt: Date?
    @Published var successes = 0
    @Published var saved: SavedConnection?
    /// The "Read a calendar from a browser" switch. Off: no read, connect or open, and no timer work.
    @Published private(set) var enabled = false
    private let store: ConnectionStore
    private var session = SyncSession()
    private var target: BrowserTarget?
    private var access: ReadAccess?
    private var timer: Timer?
    private var observer: NSObjectProtocol?
    private var connectionKey: String?
    private var memory = BrowserEventMemory()
    private var launchRetries = 0
    private let settings: SettingsStorage
    /// A cold accessibility walk of a week view outlasts the 12-second budget used to name a window.
    private static let pageReadSeconds = 45

    init(directory: URL? = nil, settings: SettingsStorage = .shared) {
        self.settings = settings
        let directory = directory ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support").appendingPathComponent(Bundle.main.bundleIdentifier ?? "Diduny").appendingPathComponent("CalendarBrowser")
        store = ConnectionStore(directory: directory)
        do {
            saved = try store.load()
            if let saved {
                connected = true; connectionKey = saved.windowName; session.connect(source: saved.windowName)
                if let stored = try? store.loadMeetings() { memory.restore(stored) }
                message = String(localized: "Connection restored. Looking for the named calendar window…")
            }
        } catch { message = String(localized: "Could not restore the connection. Reading is paused: \(error.localizedDescription)") }
        enabled = BrowserCalendarSetting.resolve(stored: settings.browserCalendarStored, hasSavedConnection: saved != nil)
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.read() }
        }
        observer = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.read(force: true) }
        }
        Task { read(force: true) }
    }

    func connect(browserID: String, profileName: String) {
        guard enabled, !busy, !connected, !profileName.isEmpty else { return }
        let key = UUID().uuidString
        connectionKey = key; session.connect(source: key)
        guard let request = session.begin(source: key, now: ProcessInfo.processInfo.systemUptime, force: true) else { return }
        let readAccess = ReadAccess(seconds: Self.pageReadSeconds); access = readAccess; busy = true; lastAttempt = Date()
        message = String(localized: "Checking the profile and naming the calendar window…")
        Task {
            let outcome = await Task.detached(priority: .userInitiated) {
                Result { () -> (BrowserReadResult, SavedConnection) in
                    let value = try BrowserReader(access: readAccess).read(bundleID: browserID, approved: true, profileName: profileName)
                    let connection = SavedConnection(browserID: browserID, profileName: profileName, calendarURL: value.target.url)
                    try connection.validate()
                    try NativeProfiles(access: ReadAccess()).nameWindow(bundleID: browserID, window: value.target.window, name: connection.windowName)
                    return (value, connection)
                }
            }.value
            guard session.finish(request, now: ProcessInfo.processInfo.systemUptime) else { return }
            busy = false; access = nil
            switch outcome {
            case .success(let (value, connection)):
                do {
                    try store.save(connection)
                    saved = connection; target = value.target; result = value; connected = true; reveal = true; successes = 1
                    connectionKey = connection.windowName; session.connect(source: connection.windowName)
                    remember(value)
                    // Start the 60-second interval from this successful connect, without another read.
                    if let token = session.begin(source: connection.windowName, now: ProcessInfo.processInfo.systemUptime) { _ = session.finish(token, now: ProcessInfo.processInfo.systemUptime) }
                    message = String(localized: "Connection saved · refreshes every minute while Diduny is running")
                } catch { session.disconnect(); message = String(localized: "Could not save the connection. Reading has not started: \(error.localizedDescription)") }
            case .failure(let error): session.disconnect(); message = String(localized: "Connection was not created. \(error.localizedDescription) Select a calendar view with no event details open.")
            }
        }
    }
    func disconnect() {
        access?.cancel(); access = nil; session.disconnect(); connected = false; busy = false; connectionKey = nil
        target = nil; result = nil; lastAttempt = nil; successes = 0; memory.clear()
        do { try store.clear(); saved = nil; message = String(localized: "Disconnected. Saved consent was removed, reading stopped and in-memory calendar data cleared.") }
        catch { message = String(localized: "Reading stopped, but saved consent could not be removed. It may return after restart. Retry disconnecting: \(error.localizedDescription)") }
    }
    func read(force: Bool = false) {
        guard enabled, connected, let saved, let key = connectionKey,
              let request = session.begin(source: key, now: ProcessInfo.processInfo.systemUptime, force: force) else { return }
        let bound = target, readAccess = ReadAccess(seconds: Self.pageReadSeconds)
        access = readAccess; busy = true; lastAttempt = Date()
        Task {
            let outcome = await Task.detached(priority: .utility) {
                Result { try BrowserReader(access: readAccess).read(bundleID: saved.browserID, approved: true, target: bound, saved: saved) }
            }.value
            guard session.finish(request, now: ProcessInfo.processInfo.systemUptime) else { return }
            busy = false; access = nil
            switch outcome {
            case .success(let value):
                target = value.target; result = value; successes += 1; remember(value)
                message = String(localized: "Background reading is active · next check in one minute")
            case .failure(let error):
                target = nil
                message = String(localized: "\(error.localizedDescription) Saved consent remains active.")
                if successes == 0, launchRetries < 15 { launchRetries += 1; session.reopenInterval() }
            }
        }
    }
    func openCalendar(browser: InstalledBrowser, profileID: String, url: URL) {
        guard enabled, !busy, !connected else { return }
        let key = UUID().uuidString
        session.connect(source: key)
        guard let request = session.begin(source: key, now: ProcessInfo.processInfo.systemUptime) else { return }
        let operationAccess = ReadAccess(); access = operationAccess; busy = true
        Task {
            let outcome = await Task.detached {
                Result {
                    if profileID.hasPrefix("menu:") {
                        try NativeProfiles(access: operationAccess).select(bundleID: browser.id, profile: String(profileID.dropFirst(5)))
                    }
                    try operationAccess.check()
                }
            }.value
            guard session.finish(request, now: ProcessInfo.processInfo.systemUptime) else { return }
            defer { busy = false; access = nil }
            do {
                try outcome.get()
                try operationAccess.check()
                try browser.openCalendar(url, profile: profileID.hasPrefix("menu:") ? "" : profileID)
                message = String(localized: "Opening the calendar in the selected profile. Connect its window after loading.")
            } catch { message = error.localizedDescription }
        }
    }
    /// Off stops every read and drops the in-memory result. The saved browser and profile stay.
    func setEnabled(_ on: Bool) {
        settings.setBrowserCalendarEnabled(on)
        guard on != enabled else { return }
        enabled = on
        if on {
            if connected, let connectionKey { session.connect(source: connectionKey) }
            if let stored = try? store.loadMeetings() { memory.restore(stored) }
            launchRetries = 0
            read(force: true)
        } else {
            access?.cancel(); access = nil; session.disconnect(); busy = false
            target = nil; result = nil; lastAttempt = nil; successes = 0; memory.clear()
        }
    }
    /// Events remembered from successful reads whose times overlap the range.
    /// A later read replaces only the days it actually shows, so yesterday and tomorrow stay.
    func meetings(from: Date, to: Date, calendar _: Calendar = .current) -> [CalendarMeeting] {
        guard enabled else { return [] }
        return memory.overlapping(from: from, to: to)
    }

    private func remember(_ value: BrowserReadResult) {
        guard let saved else { return }
        let source = CalendarPage.provider(for: saved.calendarURL) == .google ? "Google Calendar" : "Outlook"
        let parsed = BrowserCalendarMeetings.make(events: value.snapshot.events, windowName: saved.windowName,
                                                  sourceTitle: source, from: .distantPast, to: .distantFuture)
        if value.incomplete { memory.add(parsed) } else { memory.replace(parsed) }
        try? store.saveMeetings(memory.stored())
    }

    func stop() {
        access?.cancel(); session.disconnect(); timer?.invalidate()
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }
}
