import AppKit
import KeyboardShortcuts
import SwiftUI

struct MenuBarProcessingModeSelection {
    private let settings: SettingsStorage
    private(set) var provider: TranscriptionProvider

    init(settings: SettingsStorage = .shared) {
        self.settings = settings
        provider = settings.effectiveTranscriptionProvider == .cloud
            && settings.effectiveTranslationProvider == .cloud ? .cloud : .local
    }

    mutating func refresh() {
        provider = settings.effectiveTranscriptionProvider == .cloud
            && settings.effectiveTranslationProvider == .cloud ? .cloud : .local
    }

    mutating func select(_ provider: TranscriptionProvider) {
        settings.selectProcessingProvider(provider)
        self.provider = provider
    }
}

/// Runs a closure when its menu item is chosen.
final class ActionMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, key: String = "", handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: key)
        target = self
    }

    @available(*, unavailable)
    required init(coder _: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func run() { handler() }
}

/// The menu bar item. Its menu is rebuilt each time it opens, so titles, meetings and devices
/// are current; meeting rows that need more than text (timeline, next-meeting card) are SwiftUI.
@MainActor final class StatusMenuController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let builder: () -> StatusMenuBuilder

    init(appState: AppState, builder: @escaping () -> StatusMenuBuilder) {
        self.builder = builder
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        guard let button = statusItem.button else { return }
        let label = NSHostingView(rootView: StatusItemLabel { [weak self] size in
            self?.statusItem.length = max(22, size.width + 8)
        }.environment(appState))
        label.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: button.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: button.centerYAnchor),
        ])
        button.setAccessibilityLabel("Diduny")
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        builder().items().forEach(menu.addItem)
    }
}

/// Recording state icon and the next meeting, shown in the menu bar.
private struct StatusItemLabel: View {
    let onSize: (CGSize) -> Void

    var body: some View {
        HStack(spacing: 5) {
            MenuBarIconView()
            CalendarMenuLabel().font(.system(size: 13))
        }
        .fixedSize()
        .background(GeometryReader { proxy in
            Color.clear
                .onAppear { onSize(proxy.size) }
                .onChange(of: proxy.size) { _, size in onSize(size) }
        })
    }
}

@MainActor struct StatusMenuBuilder {
    struct Actions {
        var toggleRecording: () -> Void
        var toggleTranslation: () -> Void
        var toggleMeeting: () -> Void
        var toggleMeetingTranslation: () -> Void
        var batchFilesAndURLs: () -> Void
        var openMainWindow: (MainSection) -> Void
    }

    let appState: AppState
    let audioDeviceManager: AudioDeviceManager
    let connection: CalendarConnection
    let actions: Actions
    var now = Date()
    var processingMode = MenuBarProcessingModeSelection()

    func items() -> [NSMenuItem] {
        var items = calendarItems()
        if !items.isEmpty { items.append(.separator()) }
        items += recordingItems()
        items += [.separator(), inputItem(), .separator()]
        items += [
            ActionMenuItem(String(localized: "Open Diduny")) { actions.openMainWindow(.overview) },
            ActionMenuItem(String(localized: "Recordings")) { actions.openMainWindow(.recordings) },
            batchItem(),
            .separator(),
            settingsItem(),
            ActionMenuItem(String(localized: "Quit"), key: "q") { NSApplication.shared.terminate(nil) },
        ]
        return items
    }

    // MARK: Meetings

    func calendarItems() -> [NSMenuItem] {
        let configuration = connection.configuration
        guard configuration.connected else { return [] }
        let meetings = connection.agendaMeetings.filter { configuration.showWithoutLink || $0.meetingURL != nil }
        let timeline = CalendarTimeline(meetings: meetings, now: now)
        var items = [hosted(size: CalendarTimelineView.size) { close in
            CalendarTimelineView(timeline: timeline, hideNames: configuration.hideNames,
                                 onOpen: { close(); actions.openMainWindow(.meetings) })
        }]
        if let next = meetings.filter({ $0.end > now }).min(by: { $0.start < $1.start }) {
            items.append(hosted(size: NextMeetingCard.size) { close in
                NextMeetingCard(meeting: next, now: now, hideNames: configuration.hideNames, recordOnJoin: configuration.recordOnJoin) { record in
                    close()
                    join(next, record: record)
                }
            })
        }
        let agenda = CalendarMeeting.agenda(meetings, now: now)
            .filter { configuration.showTomorrow || Calendar.current.isDate($0.day, inSameDayAs: now) }
        if agenda.isEmpty {
            items.append(disabled(String(localized: "No upcoming meetings")))
        }
        for day in agenda {
            items.append(.sectionHeader(title: dayTitle(day.day)))
            items += day.meetings.map(row)
        }
        return items
    }

    func row(_ meeting: CalendarMeeting) -> NSMenuItem {
        let phase = meeting.phase(at: now)
        let title = connection.configuration.hideNames ? String(localized: "Meeting")
            : meeting.title.count > 40 ? String(meeting.title.prefix(39)) + "…" : meeting.title
        let times = meeting.start.formatted(date: .omitted, time: .shortened) + " – " + meeting.end.formatted(date: .omitted, time: .shortened)
        let item = NSMenuItem(title: times + "   " + title, action: nil, keyEquivalent: "")
        item.attributedTitle = Self.rowTitle(times: times, title: title, phase: phase,
                                             tentative: meeting.myResponse == .tentative || meeting.myResponse == .pending)
        let symbol = phase == .current ? "dot.radiowaves.left.and.right" : meeting.meetingURL == nil ? "person.2.fill" : "video.fill"
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        if phase == .past {
            // Ended meetings stay for context; an item with a submenu would always be enabled.
            item.isEnabled = false
        } else {
            item.submenu = details(meeting)
        }
        return item
    }

    /// Start–end in a fixed column (digits monospaced, tab stop after the widest time), then the title.
    static func rowTitle(times: String, title: String, phase: CalendarTimeline.Phase, tentative: Bool) -> NSAttributedString {
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: phase == .current ? .semibold : .regular)
        let sample = Calendar.current.date(from: DateComponents(year: 2026, month: 1, day: 1, hour: 22, minute: 58)) ?? Date()
        let widest = sample.formatted(date: .omitted, time: .shortened) + " – " + sample.formatted(date: .omitted, time: .shortened)
        let column = (widest as NSString).size(withAttributes: [.font: font]).width + 14
        let paragraph = NSMutableParagraphStyle()
        paragraph.tabStops = [NSTextTab(textAlignment: .left, location: column)]
        var attributes: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: paragraph]
        if phase == .past { attributes[.foregroundColor] = NSColor.disabledControlTextColor }
        let text = NSMutableAttributedString(string: times + "\t" + title, attributes: attributes)
        if tentative {
            let range = NSRange(location: (times + "\t").utf16.count, length: title.utf16.count)
            text.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue | NSUnderlineStyle.patternDot.rawValue, range: range)
        }
        return text
    }

    func details(_ meeting: CalendarMeeting) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let configuration = connection.configuration
        if let url = meeting.meetingURL {
            menu.addItem(ActionMenuItem(String(localized: "Join")) { join(meeting, record: configuration.recordOnJoin) })
            if !configuration.recordOnJoin {
                menu.addItem(ActionMenuItem(String(localized: "Join and record")) { join(meeting, record: true) })
            }
            menu.addItem(ActionMenuItem(String(localized: "Copy meeting link")) { CalendarMeeting.copyLink(url) })
        } else {
            menu.addItem(ActionMenuItem(String(localized: "Record meeting")) { join(meeting, record: true) })
        }
        if let link = meeting.calendarAppURL {
            menu.addItem(ActionMenuItem(String(localized: "Open in Calendar")) { NSWorkspace.shared.open(link) })
        }
        guard !configuration.hideNames else { return menu }
        var info = [meeting.scheduleLine, meeting.calendarTitle, meeting.location,
                    meeting.organizer.map { String(localized: "Organized by \($0.displayName)") },
                    meeting.attendees.map { CalendarMeeting.attendeeSummary($0) }].compactMap { $0 }
        if let notes = meeting.notes {
            info += notes.components(separatedBy: .newlines).filter { !$0.isEmpty }.prefix(4)
                .map { $0.count > 60 ? String($0.prefix(59)) + "…" : $0 }
        }
        if !info.isEmpty { menu.addItem(.separator()) }
        info.forEach { menu.addItem(disabled($0)) }
        return menu
    }

    private func join(_ meeting: CalendarMeeting, record: Bool) {
        let connection = connection
        Task {
            if let message = await connection.joinFromMenu(meeting, record: record) {
                DictationOverlayController.shared.showInfo(message: message, duration: 5)
            }
        }
    }

    private func dayTitle(_ day: Date) -> String {
        let date = day.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        return Calendar.current.isDate(day, inSameDayAs: now)
            ? String(localized: "Today (\(date))") : String(localized: "Tomorrow (\(date))")
    }

    private func hosted<Content: View>(size: CGSize, _ content: (_ close: @escaping () -> Void) -> Content) -> NSMenuItem {
        let item = NSMenuItem()
        let close: () -> Void = { [weak item] in item?.menu?.cancelTracking() }
        let view = NSHostingView(rootView: content(close))
        view.frame = NSRect(origin: .zero, size: size)
        item.view = view
        return item
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    // MARK: Recording

    func recordingItems() -> [NSMenuItem] {
        [
            shortcutItem(recordingTitle, .toggleRecording, enabled: !isBlocked(appState.recordingState, by: [appState.translationRecordingState, appState.meetingRecordingState, appState.meetingTranslationRecordingState]), action: actions.toggleRecording),
            shortcutItem(translationTitle, .toggleTranslation, enabled: !isBlocked(appState.translationRecordingState, by: [appState.recordingState, appState.meetingRecordingState, appState.meetingTranslationRecordingState]), action: actions.toggleTranslation),
            shortcutItem(meetingTitle, .toggleMeetingRecording, enabled: !isBlocked(appState.meetingRecordingState, by: [appState.recordingState, appState.translationRecordingState, appState.meetingTranslationRecordingState]), action: actions.toggleMeeting),
            shortcutItem(meetingTranslationTitle, .toggleMeetingTranslation, enabled: !isBlocked(appState.meetingTranslationRecordingState, by: [appState.recordingState, appState.translationRecordingState, appState.meetingRecordingState]), action: actions.toggleMeetingTranslation),
        ]
    }

    private func shortcutItem(_ title: String, _ shortcut: KeyboardShortcuts.Name, enabled: Bool, action: @escaping () -> Void) -> NSMenuItem {
        let item = ActionMenuItem(title, handler: action)
        item.setShortcut(for: shortcut)
        item.isEnabled = enabled
        return item
    }

    /// An idle mode is unavailable while another mode records or processes.
    private func isBlocked(_ state: RecordingState, by others: [RecordingState]) -> Bool {
        state == .idle && others.contains { $0 == .recording || $0 == .processing }
    }

    private var recordingTitle: String {
        switch appState.recordingState {
        case .recording: String(localized: "Stop Dictation")
        case .processing: String(localized: "Processing Dictation…")
        default: String(localized: "Dictation")
        }
    }

    private var translationTitle: String {
        switch appState.translationRecordingState {
        case .recording: String(localized: "Stop Translation")
        case .processing: String(localized: "Processing Translation…")
        default: String(localized: "Translation \(translationTargetLabel)")
        }
    }

    private var meetingTitle: String {
        switch appState.meetingRecordingState {
        case .recording: String(localized: "Stop Meeting")
        case .processing: String(localized: "Processing Meeting…")
        default: String(localized: "Meeting")
        }
    }

    private var meetingTranslationTitle: String {
        switch appState.meetingTranslationRecordingState {
        case .recording: String(localized: "Stop Meeting Translation")
        case .processing: String(localized: "Processing Meeting Translation…")
        default: String(localized: "Meeting Translation \(translationTargetLabel)")
        }
    }

    private var translationTargetLabel: String {
        if SettingsStorage.shared.effectiveTranslationProvider == .local { return "EN" }
        return SettingsStorage.shared.resolveTranslationLanguagePair().displayLabel
    }

    // MARK: Input, windows, app

    /// One submenu for where audio comes from and where it is processed.
    func inputItem() -> NSMenuItem {
        let isCloud = processingMode.provider == .cloud
        let item = NSMenuItem(title: String(localized: "Input: \(microphoneLabel) · \(isCloud ? String(localized: "Cloud") : String(localized: "Local"))"),
                              action: nil, keyEquivalent: "")
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(.sectionHeader(title: String(localized: "Processing")))
        let cloud = ActionMenuItem(String(localized: "Cloud")) {
            guard AuthService.shared.isLoggedIn else {
                DictationOverlayController.shared.showInfo(message: String(localized: "Log in to use cloud processing"), duration: 3.0)
                actions.openMainWindow(.account)
                return
            }
            var mode = processingMode
            mode.select(.cloud)
        }
        cloud.state = isCloud ? .on : .off
        let local = ActionMenuItem(String(localized: "Local")) {
            var mode = processingMode
            mode.select(.local)
        }
        local.state = isCloud ? .off : .on
        menu.addItem(cloud)
        menu.addItem(local)
        menu.addItem(.sectionHeader(title: String(localized: "Microphone")))
        let effectiveUID = audioDeviceManager.effectiveDeviceUID(preferred: appState.preferredDeviceUID)
        let systemDefault = ActionMenuItem(String(localized: "System Default")) { appState.preferredDeviceUID = nil }
        systemDefault.state = effectiveUID == nil ? .on : .off
        menu.addItem(systemDefault)
        for device in audioDeviceManager.availableDevices {
            let deviceItem = ActionMenuItem(deviceLabel(device)) { appState.preferredDeviceUID = device.uid }
            deviceItem.state = effectiveUID == device.uid ? .on : .off
            menu.addItem(deviceItem)
        }
        item.submenu = menu
        return item
    }

    private var microphoneLabel: String {
        if let uid = audioDeviceManager.effectiveDeviceUID(preferred: appState.preferredDeviceUID),
           let device = audioDeviceManager.device(forUID: uid) {
            return device.name
        }
        return String(localized: "System Default")
    }

    private func deviceLabel(_ device: AudioDevice) -> String {
        var label = device.name
        if device.transportType != .unknown, device.transportType != .builtIn {
            label += " (\(device.transportType.displayName))"
        }
        if device.isDefault {
            label += String(localized: " — Default")
        }
        return label
    }

    private func batchItem() -> NSMenuItem {
        let item = ActionMenuItem(MainWindowController.batchComposerActionTitle, key: "b", handler: actions.batchFilesAndURLs)
        item.keyEquivalentModifierMask = [.command, .shift]
        return item
    }

    private func settingsItem() -> NSMenuItem {
        ActionMenuItem(String(localized: "Settings…"), key: ",") { actions.openMainWindow(.general) }
    }
}
