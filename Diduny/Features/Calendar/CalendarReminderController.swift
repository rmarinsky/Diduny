import AppKit
import SwiftUI

private final class CalendarReminderWindow: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor final class CalendarReminderController {
    private var window: NSWindow?
    private var pending: [CalendarMeeting] = []
    private let presentation = CalendarReminderPresentation()
    func dismiss() { window?.close(); window = nil; pending = [] }

    func show(_ meetings: [CalendarMeeting], connection: CalendarConnection) {
        guard !meetings.isEmpty else { return }
        presentation.prepare(defaultRecord: connection.configuration.recordOnJoin, replacingVisible: window?.isVisible == true)
        let merged = CalendarMeeting.pendingReminders(existing: window?.isVisible == true ? pending : [], incoming: meetings, current: connection.currentMeetings)
        dismiss()
        pending = merged
        let fullscreen = connection.configuration.fullScreen
        let frame = fullscreen ? (NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1000, height: 700))
                               : NSRect(x: 0, y: 0, width: 480, height: 400)
        let panel = CalendarReminderWindow(contentRect: frame,
            styleMask: fullscreen ? [.borderless] : [.titled, .closable], backing: .buffered, defer: false)
        panel.title = String(localized: "Upcoming meeting")
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: CalendarReminderView(meetings: merged, connection: connection, presentation: presentation,
                                                                          dismiss: { [weak self] in self?.dismiss() }))
        if !fullscreen { panel.center() }
        window = panel
        panel.makeKeyAndOrderFront(nil)
    }
}

private struct CalendarReminderView: View {
    let meetings: [CalendarMeeting]
    let connection: CalendarConnection
    @Bindable var presentation: CalendarReminderPresentation
    let dismiss: () -> Void
    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            VStack(spacing: 20) {
                Image(systemName: "calendar.badge.clock").font(.system(size: 46)).foregroundStyle(.tint)
                Text("Your next meeting").font(.largeTitle.bold())
                ScrollView {
                    ForEach(meetings) { event in
                        if let current = connection.currentMeetings.first(where: { $0.id == event.id && $0.start == event.start }) {
                            VStack(spacing: 10) {
                                Text(current.title).font(.title2.bold()).multilineTextAlignment(.center)
                                Text(current.start <= context.date ? String(localized: "Starting now") : current.start.formatted(date: .omitted, time: .shortened))
                                if let url = current.meetingURL {
                                    Text(url.absoluteString).font(.caption).textSelection(.enabled)
                                    Button("Join") { connection.join(current, record: presentation.record); dismiss() }
                                        .buttonStyle(.borderedProminent).controlSize(.large)
                                } else {
                                    Text("This event has no supported meeting link.").foregroundStyle(.secondary)
                                    Button("Record meeting") { connection.join(current, record: true); dismiss() }
                                        .buttonStyle(.borderedProminent)
                                }
                            }.padding()
                        }
                    }
                }.frame(maxHeight: 300)
                Toggle("Record this meeting", isOn: $presentation.record)
                Text(connection.configuration.localRecording ? "New recordings use local transcription. If a recording is already running, it is linked with its current processing settings." : "New recordings use cloud transcription. If a recording is already running, it is linked with its current processing settings.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Dismiss", action: dismiss).keyboardShortcut(.cancelAction)
            }.padding(36).frame(maxWidth: 650).frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.background)
        }
        .onChange(of: connection.currentMeetings.map(\.reminderKey)) { _, keys in
            if !meetings.contains(where: { keys.contains($0.reminderKey) }) { dismiss() }
        }
    }
}
