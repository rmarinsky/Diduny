import AppKit
import SwiftUI

private final class CalendarReminderWindow: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor final class CalendarReminderController {
    private(set) var window: NSWindow?
    private var pending: [CalendarMeeting] = []
    /// The shown window is the heads-up before the meeting, not the start reminder.
    private(set) var isEarly = false
    private var screenObserver: NSObjectProtocol?

    func dismiss() {
        window?.orderOut(nil)
        window?.close()
        window = nil
        pending = []
        isEarly = false
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
    }

    /// Dismissed by the person: the shown meetings are not offered again for this occurrence.
    func dismissByUser(connection: CalendarConnection) {
        connection.acknowledge(pending)
        dismiss()
    }

    func snooze(minutes: Int, connection: CalendarConnection) {
        connection.snooze(pending, minutes: minutes)
        dismiss()
    }

    func join(_ meeting: CalendarMeeting, record: Bool, local: Bool? = nil, connection: CalendarConnection) {
        guard connection.hasFreshSnapshot else {
            // The panel may show a meeting from an older read: refresh first, keep the panel if it fails.
            Task {
                if let message = await connection.joinFromMenu(meeting, record: record, local: local) {
                    DictationOverlayController.shared.showInfo(message: message, duration: 5)
                } else {
                    dismiss()
                }
            }
            return
        }
        dismiss()
        connection.join(meeting, record: record, local: local)
    }

    /// The compact heads-up a few minutes before a meeting. Never covers a start reminder.
    func showEarly(_ meetings: [CalendarMeeting], connection: CalendarConnection) {
        guard !meetings.isEmpty, window?.isVisible != true || isEarly else { return }
        present(meetings, connection: connection, early: true)
    }

    func show(_ meetings: [CalendarMeeting], connection: CalendarConnection) {
        guard !meetings.isEmpty else { return }
        present(meetings, connection: connection, early: false)
    }

    private func present(_ meetings: [CalendarMeeting], connection: CalendarConnection, early: Bool) {
        let shown = window?.isVisible == true && isEarly == early ? pending : []
        let merged = CalendarMeeting.pendingReminders(existing: shown, incoming: meetings, current: connection.currentMeetings)
        dismiss()
        pending = merged
        isEarly = early
        let fullScreen = !early && connection.configuration.reminderStyle == .fullScreen
        let screen = Self.activeScreen()
        let frame = fullScreen ? (screen?.frame ?? NSRect(x: 0, y: 0, width: 1000, height: 700))
                               : NSRect(x: 0, y: 0, width: early ? 420 : 560, height: early ? 300 : 620)
        let panel = CalendarReminderWindow(contentRect: frame,
            styleMask: fullScreen ? [.borderless, .nonactivatingPanel] : [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = String(localized: "Upcoming meeting")
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.level = fullScreen ? .screenSaver : .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let content = NSHostingView(rootView: CalendarReminderView(
            meetings: merged, connection: connection, fullScreen: fullScreen, early: early,
            // Dismissing the heads-up keeps the start reminder coming.
            dismiss: { [weak self] in early ? self?.dismiss() : self?.dismissByUser(connection: connection) },
            close: { [weak self] in self?.dismiss() },
            snooze: { [weak self] minutes in self?.snooze(minutes: minutes, connection: connection) },
            join: { [weak self] meeting, record, local in self?.join(meeting, record: record, local: local, connection: connection) }))
        panel.contentView = content
        if early { panel.setContentSize(NSSize(width: frame.width, height: content.fittingSize.height)) }
        if fullScreen {
            // A disconnected display would strand the full-screen reminder off-screen.
            screenObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
            ) { [weak panel] _ in
                MainActor.assumeIsolated {
                    guard let panel, let screen = Self.activeScreen() else { return }
                    panel.setFrame(screen.frame, display: true)
                }
            }
        } else if let screen {
            let size = panel.frame.size
            panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - size.width / 2, y: screen.visibleFrame.midY - size.height / 2))
        }
        window = panel
        // The heads-up must not take the keys of whatever the person is typing in.
        if !early { panel.makeKeyAndOrderFront(nil) }
        panel.orderFrontRegardless()
    }

    private var endedWindow: NSWindow?

    var isShowingMeetingEnded: Bool { endedWindow != nil }

    func closeMeetingEnded() {
        endedWindow?.close()
        endedWindow = nil
    }

    /// A small floating prompt: the meeting being recorded has ended. One at a time; a newer one replaces it.
    func showMeetingEnded(title: String, message: String, stop: @escaping () -> Void) {
        closeMeetingEnded()
        let panel = CalendarReminderWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 160),
                                           styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let content = NSHostingView(rootView: MeetingEndedView(
            title: title, message: message,
            stop: { [weak self] in self?.closeMeetingEnded(); stop() },
            keep: { [weak self] in self?.closeMeetingEnded() }))
        panel.contentView = content
        panel.setContentSize(content.fittingSize)
        if let screen = Self.activeScreen() {
            panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.maxX - panel.frame.width - 20,
                                         y: screen.visibleFrame.maxY - panel.frame.height - 20))
        }
        endedWindow = panel
        panel.orderFrontRegardless()
    }

    /// The display the person is working on: the one under the pointer.
    private static func activeScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
    }
}

struct CalendarReminderView: View {
    let meetings: [CalendarMeeting]
    let connection: CalendarConnection
    let fullScreen: Bool
    /// The compact heads-up before the start.
    var early = false
    /// Dismissed by the person: not offered again for this occurrence (the heads-up only closes).
    let dismiss: () -> Void
    /// Closed because the meetings ended or changed: no acknowledgement.
    let close: () -> Void
    let snooze: (Int) -> Void
    /// Meeting, record, and local transcription for this meeting (nil keeps the calendar default).
    let join: (CalendarMeeting, Bool, Bool?) -> Void
    /// Chosen on the reminder for this meeting only.
    @State var localOverride: Bool? = nil

    private var local: Bool { localOverride ?? connection.configuration.localRecording }

    /// The latest version of each shown meeting; the shown copy when the calendar can't be read right now.
    private var current: [CalendarMeeting] {
        meetings.map { event in connection.currentMeetings.first { $0.id == event.id && $0.start == event.start } ?? event }
    }

    var body: some View {
        if early { earlyBody } else { startBody }
    }

    private var earlyBody: some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            let upcoming = current.filter { $0.start > context.date }
            VStack(alignment: .leading, spacing: 14) {
                if let meeting = upcoming.first {
                    CalendarMeetingDetails(meeting: meeting, now: context.date, hideNames: connection.configuration.hideNames,
                                           titleSize: 19, compact: true)
                    HStack(spacing: 8) {
                        actions(meeting, size: .regular)
                        Spacer()
                        Button("Dismiss", action: dismiss).keyboardShortcut(.cancelAction)
                    }
                    processingLine(meeting, changeable: false)
                    if upcoming.count > 1 { others(Array(upcoming.dropFirst()), now: context.date) }
                }
            }
            .padding(20)
            .frame(width: 420, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            // The start reminder takes over at the start time.
            .onChange(of: upcoming.isEmpty) { _, started in if started { close() } }
        }
        .tint(Color("BrandAccentDeep"))
        .onChange(of: connection.currentMeetings.map(\.reminderKey)) { _, keys in
            guard connection.hasFreshSnapshot else { return }
            if !meetings.contains(where: { keys.contains($0.reminderKey) }) { close() }
        }
    }

    private var startBody: some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            let running = current.filter { $0.end > context.date }
            VStack(spacing: 0) {
                if let meeting = running.first {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 22) {
                            CalendarMeetingDetails(meeting: meeting, now: context.date, hideNames: connection.configuration.hideNames,
                                                   titleSize: fullScreen ? 34 : 22)
                            VStack(alignment: .leading, spacing: 10) {
                                actions(meeting, size: .large)
                                processingLine(meeting, changeable: true)
                            }
                            if running.count > 1 { others(Array(running.dropFirst()), now: context.date) }
                        }
                        .frame(maxWidth: 680, alignment: .leading)
                        .padding(fullScreen ? 48 : 24)
                        .frame(maxWidth: .infinity)
                    }
                } else {
                    Spacer()
                }
                // Always present, so the reminder can be closed (Escape) whatever happens to the meeting.
                Divider()
                footer
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.background)
            .onChange(of: running.isEmpty) { _, ended in if ended { close() } }
        }
        .tint(Color("BrandAccentDeep"))
        .onChange(of: connection.currentMeetings.map(\.reminderKey)) { _, keys in
            // Only a fresh read can say the meetings were moved or removed; a failed read leaves keys empty.
            guard connection.hasFreshSnapshot else { return }
            if !meetings.contains(where: { keys.contains($0.reminderKey) }) { close() }
        }
    }

    @ViewBuilder private func actions(_ meeting: CalendarMeeting, size: ControlSize) -> some View {
        HStack(spacing: 10) {
            if let url = meeting.meetingURL {
                Button { join(meeting, connection.configuration.recordOnJoin, localOverride) } label: {
                    Label("Join", systemImage: "video.fill").frame(minWidth: size == .large ? 120 : 0)
                }
                // No Return shortcut: the panel can take key focus while the person types elsewhere.
                .buttonStyle(.borderedProminent).controlSize(size)
                if !connection.configuration.recordOnJoin {
                    Button("Join and record") { join(meeting, true, localOverride) }.controlSize(size)
                }
                Button("Copy link") { CalendarMeeting.copyLink(url) }.controlSize(size)
            } else {
                Button { join(meeting, true, localOverride) } label: {
                    Label("Record meeting", systemImage: "record.circle").frame(minWidth: size == .large ? 120 : 0)
                }
                .buttonStyle(.borderedProminent).controlSize(size)
            }
        }
    }

    /// What Join does with the recording; on the start reminder it can be changed for this meeting.
    @ViewBuilder private func processingLine(_ meeting: CalendarMeeting, changeable: Bool) -> some View {
        if connection.configuration.recordOnJoin || meeting.meetingURL == nil {
            let hasModel = WhisperModelManager.shared.selectedModel() != nil
            HStack(spacing: 8) {
                Circle().fill(Color("BrandAccentDeep")).frame(width: 7, height: 7).accessibilityHidden(true)
                if !local {
                    Text("Records with a live transcript in the cloud")
                } else if hasModel {
                    Text("Records on this Mac · transcribed after the meeting")
                } else {
                    Text("Records audio only · download a model to transcribe")
                }
                if changeable {
                    Menu("Change") {
                        Button { localOverride = true } label: {
                            if local { Label("On this Mac, after the meeting", systemImage: "checkmark") } else { Text("On this Mac, after the meeting") }
                        }
                        Button { localOverride = false } label: {
                            if local { Text("Live transcript in the cloud") } else { Label("Live transcript in the cloud", systemImage: "checkmark") }
                        }
                        .disabled(!UsageService.canOfferCloudTranscription(hasStoredSession: AuthService.hasStoredSession,
                                                                           usage: UsageService.shared.cachedUsage))
                        Divider()
                        Text("Applies to this meeting only")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    if local && !hasModel {
                        Button("Download model") { AppDelegate.current?.openSettings(tab: .models) }
                            .buttonStyle(.link).foregroundStyle(Color("BrandAccentDeep"))
                    }
                }
            }
            .font(changeable ? .callout : .caption)
            .foregroundStyle(.secondary)
        }
    }

    private func others(_ meetings: [CalendarMeeting], now: Date) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Also starting").font(.headline)
            ForEach(meetings) { meeting in
                HStack {
                    Text(connection.configuration.hideNames ? String(localized: "Meeting") : meeting.title).lineLimit(1)
                    Text(meeting.start.formatted(date: .omitted, time: .shortened)).foregroundStyle(.secondary)
                    Spacer()
                    if meeting.meetingURL != nil {
                        Button("Join") { join(meeting, connection.configuration.recordOnJoin, localOverride) }
                    } else {
                        Button("Record meeting") { join(meeting, true, localOverride) }
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Menu("Snooze") {
                Button("1 minute") { snooze(1) }
                Button("5 minutes") { snooze(5) }
            }
            .fixedSize()
            Spacer()
            Button("Dismiss", action: dismiss).keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, fullScreen ? 48 : 20).padding(.vertical, 14)
    }
}

/// Same card look as "Looks like a meeting started".
private struct MeetingEndedView: View {
    let title: String
    let message: String
    let stop: () -> Void
    let keep: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "stop.circle")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Color("BrandAccentDeep"))
                    .frame(width: 44, height: 44)
                    .background(Color("BrandTintSoft"), in: RoundedRectangle(cornerRadius: 11))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.system(size: 15, weight: .semibold)).lineLimit(2)
                    Text(message)
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 8) {
                Button(action: keep) { Text("Keep recording").frame(maxWidth: .infinity, minHeight: 32) }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.cancelAction)
                Button(action: stop) { Text("Stop recording").frame(maxWidth: .infinity, minHeight: 32) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .frame(width: 380, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous).stroke(Color.primary.opacity(0.10), lineWidth: 0.5))
        .tint(Color("BrandAccentDeep"))
    }
}

/// Status, title, service, time, place, people and agenda of one meeting. Shared by the
/// meeting-now screen and the recording detail.
struct CalendarMeetingDetails: View {
    let meeting: CalendarMeeting
    let now: Date?
    var hideNames = false
    var titleSize: CGFloat = 22
    /// The heads-up: people as one summary line and the start of the agenda.
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                if let rgb = meeting.calendarColorRGB {
                    Circle().fill(Color(rgb: rgb)).frame(width: 9, height: 9).accessibilityHidden(true)
                }
                if let now { Text(meeting.statusLine(now: now)).font(.headline).foregroundStyle(Color("BrandAccentDeep")) }
                if !hideNames, let calendar = meeting.calendarTitle { Text(calendar).foregroundStyle(.secondary) }
            }
            Text(hideNames ? String(localized: "Meeting") : meeting.title)
                .font(.system(size: titleSize, weight: .bold)).textSelection(.enabled)
            HStack(spacing: 6) {
                Image(systemName: meeting.meetingURL == nil ? "person.2.fill" : "video.fill").accessibilityHidden(true)
                Text(meeting.scheduleLine)
            }
            .foregroundStyle(.secondary)
            if !hideNames, let location = meeting.location {
                Label(location, systemImage: "mappin.and.ellipse").foregroundStyle(.secondary).textSelection(.enabled)
            }
            if !hideNames, let attendees = meeting.attendees, !attendees.isEmpty {
                if compact {
                    HStack(alignment: .firstTextBaseline) {
                        Text("People").font(.headline)
                        Text(CalendarMeeting.attendeeSummary(attendees)).foregroundStyle(.secondary).lineLimit(1)
                    }
                } else {
                    people(attendees)
                }
            }
            if !hideNames, let notes = meeting.notes {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Agenda").font(.headline)
                    Text(notes).textSelection(.enabled).lineLimit(compact ? 2 : nil).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func people(_ attendees: [CalendarAttendee]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("People").font(.headline)
                Text(CalendarMeeting.attendeeSummary(attendees)).foregroundStyle(.secondary)
            }
            if let organizer = meeting.organizer {
                Text("Organized by \(organizer.displayName)").foregroundStyle(.secondary)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), alignment: .leading)], alignment: .leading, spacing: 6) {
                ForEach(attendees.prefix(16), id: \.self) { attendee in
                    HStack(spacing: 6) {
                        Image(systemName: attendee.response.symbol).foregroundStyle(attendee.response.color)
                            .accessibilityLabel(Text(attendee.response.label))
                        VStack(alignment: .leading, spacing: 0) {
                            Text(attendee.displayName + (attendee.isCurrentUser ? " " + String(localized: "(you)") : "")).lineLimit(1)
                            if let email = attendee.email, attendee.name != nil {
                                Text(email).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                    .textSelection(.enabled)
                }
            }
            if attendees.count > 16 {
                Text("and \(attendees.count - 16) more").foregroundStyle(.secondary)
            }
        }
    }
}

extension Color {
    init(rgb: UInt32) {
        self.init(red: Double((rgb >> 16) & 255) / 255, green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255)
    }
}

extension CalendarAttendee.Response {
    var symbol: String {
        switch self {
        case .accepted: "checkmark.circle.fill"
        case .declined: "xmark.circle.fill"
        case .tentative: "questionmark.circle.fill"
        case .pending, .unknown: "circle.dashed"
        }
    }

    var color: Color {
        switch self {
        case .accepted: .green
        case .declined: .red
        case .tentative: .orange
        case .pending, .unknown: .secondary
        }
    }

    var label: String {
        switch self {
        case .accepted: String(localized: "Accepted")
        case .declined: String(localized: "Declined")
        case .tentative: String(localized: "Maybe")
        case .pending, .unknown: String(localized: "No response")
        }
    }
}
