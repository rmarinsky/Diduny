import SwiftUI

/// Header (title, More menu, close) and a scrolling body, shared by the event, notes, group and selection inspectors.
struct RecordingsInspectorShell<Menu: View, Content: View>: View {
    let title: String
    let subtitle: String?
    let onClose: () -> Void
    @ViewBuilder var menu: () -> Menu
    @ViewBuilder var content: () -> Content

    init(title: String, subtitle: String?, onClose: @escaping () -> Void,
         @ViewBuilder menu: @escaping () -> Menu, @ViewBuilder content: @escaping () -> Content)
    {
        self.title = title
        self.subtitle = subtitle
        self.onClose = onClose
        self.menu = menu
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .top, spacing: DS.Space.sm) {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if Menu.self != EmptyView.self {
                        SwiftUI.Menu { menu() } label: { Text("More") }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                            .accessibilityIdentifier("recordings.inspector.more")
                    }
                    Button(action: onClose) { Image(systemName: "xmark") }
                        .buttonStyle(.plain)
                        .keyboardShortcut(.cancelAction)
                        .help("Close (Esc)")
                        .accessibilityIdentifier("recordings.inspector.close")
                }
                if let subtitle {
                    Text(subtitle).font(DS.Font.caption).foregroundStyle(DS.Palette.secondary)
                }
            }
            .padding(EdgeInsets(top: 16, leading: 16, bottom: 10, trailing: 16))
            ScrollView {
                VStack(alignment: .leading, spacing: 4) { content() }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(EdgeInsets(top: 6, leading: 16, bottom: 16, trailing: 16))
            }
        }
    }
}

extension RecordingsInspectorShell where Menu == EmptyView {
    init(title: String, subtitle: String?, onClose: @escaping () -> Void, @ViewBuilder content: @escaping () -> Content) {
        self.init(title: title, subtitle: subtitle, onClose: onClose, menu: { EmptyView() }, content: content)
    }
}

/// One recording in an inspector list: name opens it, time and length, an action at the end.
struct RecordingsInspectorLine<Trailing: View>: View {
    let recording: Recording
    let title: String
    let onOpen: () -> Void
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: DS.Space.sm) {
            Button(action: onOpen) {
                Text(title).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Text(verbatim: "\(recording.createdAt.formatted(date: .omitted, time: .shortened)), \(Duration.seconds(recording.durationSeconds).formatted(.time(pattern: .minuteSecond)))")
                .font(DS.Font.caption)
                .foregroundStyle(DS.Palette.secondary)
                .monospacedDigit()
            trailing().controlSize(.small)
        }
        .padding(.vertical, 5)
    }
}

struct RecordingsSectionHeading: View {
    let title: String

    var body: some View {
        Text(title).font(DS.Font.headline).padding(.top, DS.Space.md).padding(.bottom, DS.Space.xs)
    }
}

/// A notes group in the inspector: every note in time order, with a filter once the group is long.
struct RecordingsNotesInspector: View {
    let group: RecordingsDay.NotesGroup
    let onOpen: (UUID) -> Void
    let onClose: () -> Void
    @State private var filter: NotesListFilter = .all
    @State private var queueService = RecordingQueueService.shared

    var body: some View {
        let notes = group.recordings
        let missing = notes.filter(\.needsTranscript)
        let total = notes.reduce(0) { $0 + $1.durationSeconds }
        RecordingsInspectorShell(
            title: String(localized: "\(notes.count) voice notes"),
            subtitle: String(localized: "\(range), \(Duration.seconds(total).formatted(.time(pattern: .minuteSecond))) in total"),
            onClose: onClose
        ) {
            HStack {
                Button("Transcribe \(missing.count) without transcript") {
                    queueService.enqueue(missing.map(\.id), action: .transcribe)
                }
                .disabled(missing.isEmpty)
                .accessibilityIdentifier("recordings.notes.transcribeMissing")
                Button("Copy all") { ClipboardService.shared.copy(text: RecordingsTranscriptText.joined(notes), behavior: .raw) }
                    .disabled(notes.allSatisfy { $0.displayTranscriptText == nil })
            }
            .padding(.bottom, DS.Space.xs)
            if NotesListFilter.showsFilter(notes) {
                ModeSegments(
                    items: [
                        .init(id: NotesListFilter.all, title: "All \(notes.count)", accessibilityID: "recordings.notes.filter.all"),
                        .init(id: NotesListFilter.withoutTranscript, title: "Without transcript \(missing.count)",
                              accessibilityID: "recordings.notes.filter.missing")
                    ],
                    selection: $filter,
                    accessibilityLabel: "Show"
                )
                .fixedSize()
                .padding(.vertical, DS.Space.xs)
            }
            LazyVStack(alignment: .leading, spacing: 4) {
                ForEach(filter.apply(notes)) { note in
                    Button { onOpen(note.id) } label: {
                        Text(verbatim: "\(note.createdAt.formatted(date: .omitted, time: .shortened)), \(Duration.seconds(note.durationSeconds).formatted(.time(pattern: .minuteSecond)))")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(DS.Palette.secondary)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, DS.Space.sm)
                    Text(note.displayTranscriptText ?? RecordingsStatusText.short(note))
                        .font(DS.Font.body)
                        .foregroundStyle(note.displayTranscriptText == nil ? DS.Palette.secondary : DS.Palette.text)
                        .textSelection(.enabled)
                }
            }
            .accessibilityIdentifier("recordings.notes.list")
            Text("Notes are grouped by clock time. Zoom in on the day for smaller groups. A group of one shows the note itself.")
                .font(DS.Font.caption).foregroundStyle(DS.Palette.secondary).padding(.top, DS.Space.md)
        }
    }

    private var range: String {
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: group.recordings[0].createdAt)
        let start = day.addingTimeInterval(Double(group.bucketStartMinute) * 60)
        let end = start.addingTimeInterval(Double(group.bucketMinutes - 1) * 60)
        return "\(start.formatted(date: .omitted, time: .shortened))-\(end.formatted(date: .omitted, time: .shortened))"
    }
}
