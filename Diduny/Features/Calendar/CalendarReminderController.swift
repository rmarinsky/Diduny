import AppKit
import SwiftUI

private final class CalendarReminderWindow: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor final class CalendarReminderController {
    private(set) var window: NSWindow?
    private var pending: [CalendarMeeting] = []
    private var screenObserver: NSObjectProtocol?

    func dismiss() {
        window?.orderOut(nil)
        window?.close()
        window = nil
        pending = []
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

    func join(_ meeting: CalendarMeeting, record: Bool, connection: CalendarConnection) {
        dismiss()
        connection.join(meeting, record: record)
    }

    func show(_ meetings: [CalendarMeeting], connection: CalendarConnection) {
        guard !meetings.isEmpty else { return }
        let merged = CalendarMeeting.pendingReminders(existing: window?.isVisible == true ? pending : [], incoming: meetings, current: connection.currentMeetings)
        dismiss()
        pending = merged
        let fullScreen = connection.configuration.reminderStyle == .fullScreen
        let screen = Self.activeScreen()
        let frame = fullScreen ? (screen?.frame ?? NSRect(x: 0, y: 0, width: 1000, height: 700))
                               : NSRect(x: 0, y: 0, width: 560, height: 620)
        let panel = CalendarReminderWindow(contentRect: frame,
            styleMask: fullScreen ? [.borderless, .nonactivatingPanel] : [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = String(localized: "Upcoming meeting")
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.level = fullScreen ? .screenSaver : .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: CalendarReminderView(
            meetings: merged, connection: connection, fullScreen: fullScreen,
            dismiss: { [weak self] in self?.dismissByUser(connection: connection) },
            snooze: { [weak self] minutes in self?.snooze(minutes: minutes, connection: connection) },
            join: { [weak self] meeting, record in self?.join(meeting, record: record, connection: connection) }))
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
            panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - frame.width / 2, y: screen.visibleFrame.midY - frame.height / 2))
        }
        window = panel
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
    }

    private var endedWindow: NSWindow?

    /// A small floating prompt: the meeting being recorded has ended.
    func showMeetingEnded(_ meeting: CalendarMeeting, hideNames: Bool, stop: @escaping () -> Void) {
        endedWindow?.close()
        let panel = CalendarReminderWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 150),
                                           styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = String(localized: "Meeting ended")
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let close: () -> Void = { [weak self] in self?.endedWindow?.close(); self?.endedWindow = nil }
        panel.contentView = NSHostingView(rootView: MeetingEndedView(
            title: hideNames ? String(localized: "Meeting") : meeting.title,
            stop: { close(); stop() }, keep: close))
        if let screen = Self.activeScreen() {
            panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.maxX - 420, y: screen.visibleFrame.maxY - 170))
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
    let dismiss: () -> Void
    let snooze: (Int) -> Void
    let join: (CalendarMeeting, Bool) -> Void

    private var current: [CalendarMeeting] {
        meetings.compactMap { event in connection.currentMeetings.first { $0.id == event.id && $0.start == event.start } }
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            VStack(spacing: 0) {
                if let meeting = current.first {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 22) {
                            CalendarMeetingDetails(meeting: meeting, now: context.date, hideNames: connection.configuration.hideNames,
                                                   titleSize: fullScreen ? 34 : 22)
                            actions(meeting)
                            if current.count > 1 { others(Array(current.dropFirst()), now: context.date) }
                        }
                        .frame(maxWidth: 680, alignment: .leading)
                        .padding(fullScreen ? 48 : 24)
                        .frame(maxWidth: .infinity)
                    }
                    Divider()
                    footer
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.background)
        }
        .tint(Color("BrandAccentDeep"))
        .onChange(of: connection.currentMeetings.map(\.reminderKey)) { _, keys in
            if !meetings.contains(where: { keys.contains($0.reminderKey) }) { dismiss() }
        }
    }

    @ViewBuilder private func actions(_ meeting: CalendarMeeting) -> some View {
        HStack(spacing: 10) {
            if let url = meeting.meetingURL {
                Button { join(meeting, connection.configuration.recordOnJoin) } label: {
                    Label("Join", systemImage: "video.fill").frame(minWidth: 120)
                }
                .buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.defaultAction)
                if !connection.configuration.recordOnJoin {
                    Button("Join and record") { join(meeting, true) }.controlSize(.large)
                }
                Button("Copy link") { CalendarMeeting.copyLink(url) }.controlSize(.large)
            } else {
                Button { join(meeting, true) } label: {
                    Label("Record meeting", systemImage: "record.circle").frame(minWidth: 120)
                }
                .buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.defaultAction)
            }
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
                        Button("Join") { join(meeting, connection.configuration.recordOnJoin) }
                    } else {
                        Button("Record meeting") { join(meeting, true) }
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
            Text(connection.configuration.localRecording ? "New recordings use local transcription. If a recording is already running, it is linked with its current processing settings." : "New recordings use cloud transcription. If a recording is already running, it is linked with its current processing settings.")
                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            Spacer()
            Button("Dismiss", action: dismiss).keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, fullScreen ? 48 : 20).padding(.vertical, 14)
    }
}

private struct MeetingEndedView: View {
    let title: String
    let stop: () -> Void
    let keep: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(title) has ended").font(.headline).lineLimit(2)
            Text("Diduny is still recording this meeting.").foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Keep recording", action: keep).keyboardShortcut(.cancelAction)
                Button("Stop recording", action: stop).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 400, alignment: .leading)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                if let rgb = meeting.calendarColorRGB {
                    Circle().fill(Color(rgb: rgb)).frame(width: 9, height: 9).accessibilityHidden(true)
                }
                if let now { Text(meeting.statusLine(now: now)).font(.headline).foregroundStyle(Color("BrandAccentDeep")) }
                if let calendar = meeting.calendarTitle { Text(calendar).foregroundStyle(.secondary) }
            }
            Text(hideNames ? String(localized: "Meeting") : meeting.title)
                .font(.system(size: titleSize, weight: .bold)).textSelection(.enabled)
            HStack(spacing: 6) {
                Image(systemName: meeting.meetingURL == nil ? "person.2.fill" : "video.fill").accessibilityHidden(true)
                Text(meeting.scheduleLine)
            }
            .foregroundStyle(.secondary)
            if let location = meeting.location {
                Label(location, systemImage: "mappin.and.ellipse").foregroundStyle(.secondary).textSelection(.enabled)
            }
            if !hideNames, let attendees = meeting.attendees, !attendees.isEmpty {
                people(attendees)
            }
            if !hideNames, let notes = meeting.notes {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Agenda").font(.headline)
                    Text(notes).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
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
