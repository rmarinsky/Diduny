import SwiftUI
import UniformTypeIdentifiers

/// What the day can ask the library to do. The library owns storage, undo and the inspector.
struct RecordingsDayActions {
    var openRecording: (UUID) -> Void
    var openEvent: (String) -> Void
    var openNotes: (String) -> Void
    var openGroup: (UUID) -> Void
    var attach: (UUID, CalendarMeeting) -> Void
    var detach: (UUID) -> Void
    var toggleSelection: (UUID) -> Void
}

/// Variant B: a week strip, then the day on an hour scale. Events with their recordings inside, unattached
/// recordings beside them, voice notes grouped by the zoom level, files and links listed under the scale.
struct RecordingsDayView<FileRow: View>: View {
    let day: RecordingsDay
    @Binding var selectedDay: Date
    let daysWithRecordings: Set<Date>
    @Binding var zoom: NotesZoom
    @Binding var expandedNotes: Set<String>
    let openSelection: RecordingsInspectorSelection?
    let isSelectionMode: Bool
    let selectedRecordingIDs: Set<UUID>
    let actions: RecordingsDayActions
    @ViewBuilder let fileRow: (Recording) -> FileRow

    @State private var dropTarget: String?
    @State private var pinchStart: NotesZoom?
    private let calendar = Calendar.current

    static var narrowWidth: CGFloat { 460 }
    private static var railInset: CGFloat { 42 }
    private static var rowHeight: Double { 24 }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            HStack(spacing: DS.Space.sm) {
                weekStrip
                zoomButtons
            }
            GeometryReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if day.isEmpty {
                            Text("No recordings or events on this day.")
                                .font(DS.Font.callout)
                                .foregroundStyle(DS.Palette.secondary)
                                .padding(.vertical, DS.Space.xl)
                                .padding(.horizontal, DS.Space.sm)
                        } else {
                            if !day.items.isEmpty {
                                rail(width: proxy.size.width)
                            }
                            if !day.files.isEmpty {
                                Text("Files and links added this day")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(DS.Palette.secondary)
                                    .padding(.horizontal, DS.Space.sm)
                                    .padding(.top, DS.Space.md)
                                    .padding(.bottom, DS.Space.xs)
                                ForEach(day.files) { fileRow($0) }
                            }
                        }
                    }
                    .padding(.bottom, DS.Space.sm)
                }
                .accessibilityIdentifier("recordings.day")
            }
            .gesture(
                MagnifyGesture()
                    .onChanged { value in
                        let start = pinchStart ?? zoom
                        pinchStart = start
                        let steps = Int((log2(value.magnification) * 2).rounded())
                        let target = NotesZoom(rawValue: min(max(start.rawValue + steps, 0), NotesZoom.allCases.count - 1)) ?? start
                        if target != zoom { zoom = target }
                    }
                    .onEnded { _ in pinchStart = nil }
            )
        }
    }

    // MARK: - Week strip

    private var weekStrip: some View {
        HStack(spacing: 2) {
            Button { moveWeek(-1) } label: { Image(systemName: "chevron.left") }
                .buttonStyle(.plain)
                .foregroundStyle(DS.Palette.secondary)
                .help("Previous week")
                .accessibilityIdentifier("recordings.week.previous")
            ForEach(RecordingsWeek.days(containing: selectedDay, calendar: calendar), id: \.self) { date in
                weekDay(date)
            }
            Button { moveWeek(1) } label: { Image(systemName: "chevron.right") }
                .buttonStyle(.plain)
                .foregroundStyle(DS.Palette.secondary)
                .help("Next week")
                .accessibilityIdentifier("recordings.week.next")
        }
    }

    private func weekDay(_ date: Date) -> some View {
        let isOn = calendar.isDate(date, inSameDayAs: selectedDay)
        let has = daysWithRecordings.contains(calendar.startOfDay(for: date))
        return Button { selectedDay = date } label: {
            VStack(spacing: 0) {
                Text(date.formatted(.dateTime.weekday(.abbreviated)))
                Text(date.formatted(.dateTime.day())).fontWeight(.bold)
            }
            .font(DS.Font.caption)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 3)
            .foregroundStyle(isOn ? Color.white : has ? DS.Palette.text : DS.Palette.secondary)
            .background(isOn ? DS.Palette.accentFill : Color.clear, in: RoundedRectangle(cornerRadius: DS.Radius.sidebarRow))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(date.formatted(date: .complete, time: .omitted)))
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .accessibilityIdentifier("recordings.week.day")
    }

    private func moveWeek(_ weeks: Int) {
        if let date = calendar.date(byAdding: .weekOfYear, value: weeks, to: selectedDay) { selectedDay = date }
    }

    private var zoomButtons: some View {
        HStack(spacing: 2) {
            Button { if let out = zoom.zoomedOut { zoom = out } } label: { Image(systemName: "minus") }
                .disabled(zoom.zoomedOut == nil)
                .help("Zoom out: group notes by half hour")
                .accessibilityIdentifier("recordings.zoom.out")
            Button { if let next = zoom.zoomedIn { zoom = next } } label: { Image(systemName: "plus") }
                .disabled(zoom.zoomedIn == nil)
                .help("Zoom in: smaller groups, down to single notes")
                .accessibilityIdentifier("recordings.zoom.in")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
    }

    // MARK: - Hour scale

    private func rail(width: CGFloat) -> some View {
        let narrow = width < Self.narrowWidth
        let placement = RecordingsDayPlacement.place(day.items, hourHeight: zoom.hourHeight, narrow: narrow,
                                                     minimumHeight: minimumHeight)
        let railWidth = max(0, width - Self.railInset - 6)
        let byID = Dictionary(uniqueKeysWithValues: day.items.map { ($0.id, $0) })
        return ZStack(alignment: .topLeading) {
            ForEach(placement.hours, id: \.hour) { line in
                Rectangle().fill(DS.Palette.line).frame(width: railWidth, height: 1)
                    .offset(x: Self.railInset, y: line.y)
                Text(verbatim: "\(line.hour):00")
                    .font(DS.Font.caption).monospacedDigit()
                    .foregroundStyle(DS.Palette.secondary)
                    .offset(x: 0, y: line.y - 7)
            }
            ForEach(placement.frames, id: \.id) { frame in
                if let item = byID[frame.id] {
                    let indent: CGFloat = frame.indented ? 14 : 0
                    let gap: CGFloat = frame.columns > 1 ? 4 : 0
                    let columnWidth = railWidth / CGFloat(frame.columns)
                    block(item)
                        .frame(width: max(0, columnWidth - gap - indent), height: frame.height, alignment: .topLeading)
                        .offset(x: Self.railInset + columnWidth * CGFloat(frame.column) + indent, y: frame.top)
                }
            }
        }
        .frame(width: width, height: placement.height, alignment: .topLeading)
        .contentShape(Rectangle())
        // A recording dragged out of an event onto empty space is detached.
        .dropDestination(for: String.self) { ids, _ in
            guard let id = ids.first.flatMap(UUID.init(uuidString:)) else { return false }
            actions.detach(id)
            return true
        }
        .padding(.top, 8)
        .animation(DS.Motion.easeOut(0.18), value: zoom)
    }

    private func minimumHeight(_ item: RecordingsDay.Item) -> Double {
        switch item {
        case let .event(event, _, _):
            event.attached.isEmpty ? 24 : 24 + Double(event.attached.count) * Self.rowHeight
        case let .notes(group, _, _):
            expandedNotes.contains(group.key)
                ? 40 + Double(min(group.recordings.count, NotesGroupRows.shownWhenLong + 1)) * Self.rowHeight
                : 40
        case let .group(group, _, _):
            24 + Double(group.recordings.count) * Self.rowHeight
        case .recording:
            40
        }
    }

    @ViewBuilder
    private func block(_ item: RecordingsDay.Item) -> some View {
        switch item {
        case let .event(event, _, _): eventBlock(event)
        case let .notes(group, _, _): notesBlock(group)
        case let .group(group, _, _): groupBlock(group)
        case let .recording(recording, _, _): recordingBlock(recording)
        }
    }

    private func eventBlock(_ event: RecordingsDay.Event) -> some View {
        let isOn = !isSelectionMode && openSelection == .event(event.key)
        let stripe = event.meeting.calendarColorRGB.map { Color(rgb: $0) } ?? DS.Palette.secondary
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(event.meeting.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                if event.attached.isEmpty {
                    Text("not recorded").font(DS.Font.caption).foregroundStyle(isOn ? Color.white : DS.Palette.secondary)
                        .lineLimit(1)
                }
            }
            ForEach(event.attached) { recording in
                attachedRow(recording, title: recording.isVoiceNote
                    ? String(localized: "Voice note \(time(recording.createdAt))")
                    : String(localized: "Recording \(time(recording.createdAt))"))
            }
        }
        .padding(EdgeInsets(top: 4, leading: 10, bottom: 5, trailing: 6))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .foregroundStyle(isOn ? Color.white : DS.Palette.text)
        .background(isOn ? DS.Palette.accentFill : DS.Palette.box, in: RoundedRectangle(cornerRadius: 6))
        .overlay(alignment: .leading) {
            Rectangle().fill(stripe).frame(width: 3).clipShape(RoundedRectangle(cornerRadius: 1.5)).padding(.vertical, 3)
                .padding(.leading, 3)
        }
        .overlay {
            if dropTarget == event.key {
                RoundedRectangle(cornerRadius: 6).strokeBorder(DS.Palette.accent, lineWidth: 2)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { actions.openEvent(event.key) }
        .dropDestination(for: String.self) { ids, _ in
            guard let id = ids.first.flatMap(UUID.init(uuidString:)) else { return false }
            actions.attach(id, event.meeting)
            return true
        } isTargeted: { targeted in
            dropTarget = targeted ? event.key : (dropTarget == event.key ? nil : dropTarget)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Calendar event: \(event.meeting.title)"))
        .accessibilityIdentifier("recordings.day.event")
    }

    private func attachedRow(_ recording: Recording, title: String) -> some View {
        let isOn = !isSelectionMode && openSelection?.opensRecording(recording.id) == true
        return HStack(spacing: 6) {
            if isSelectionMode { checkmark(selectedRecordingIDs.contains(recording.id)) }
            Text(title).font(.system(size: 11, weight: .semibold)).lineLimit(1).layoutPriority(1)
            Text(statusLine(recording)).font(DS.Font.caption).lineLimit(1)
                .foregroundStyle(isOn ? Color.white : DS.Palette.secondary)
        }
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, minHeight: 21, maxHeight: 21, alignment: .leading)
        .foregroundStyle(isOn ? Color.white : DS.Palette.text)
        .background(isOn ? DS.Palette.accentFill : DS.Palette.card, in: RoundedRectangle(cornerRadius: 5))
        .contentShape(Rectangle())
        .onTapGesture { tapRecording(recording.id) }
        .draggable(recording.id.uuidString)
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("recordings.day.attached")
    }

    private func notesBlock(_ group: RecordingsDay.NotesGroup) -> some View {
        let expanded = expandedNotes.contains(group.key)
        let isOn = !isSelectionMode && openSelection == .notes(group.key)
        let rows = NotesGroupRows.visible(group.recordings)
        let total = group.recordings.reduce(0) { $0 + $1.durationSeconds }
        return VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .top, spacing: 6) {
                if isSelectionMode {
                    checkmark(group.recordings.allSatisfy { selectedRecordingIDs.contains($0.id) })
                } else {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .frame(width: 14, height: 16)
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text("\(group.recordings.count) voice notes").font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Text(verbatim: "\(time(group.recordings[0].createdAt))-\(time(group.recordings.last!.createdAt)), \(duration(total))")
                        .font(DS.Font.caption).lineLimit(1)
                        .foregroundStyle(isOn ? Color.white : DS.Palette.secondary)
                }
            }
            if expanded {
                ForEach(rows.shown) { attachedRow($0, title: time($0.createdAt)) }
                if rows.hidden > 0 {
                    Button { actions.openNotes(group.key) } label: {
                        Text("\(rows.hidden) more, all of them are in the inspector")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(isOn ? Color.white : DS.Palette.accentText)
                    }
                    .buttonStyle(.plain)
                    .frame(height: 21)
                }
            }
        }
        .padding(EdgeInsets(top: 3, leading: 7, bottom: 3, trailing: 7))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .foregroundStyle(isOn ? Color.white : DS.Palette.text)
        .background(isOn ? DS.Palette.accentFill : DS.Palette.box, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture {
            if isSelectionMode {
                let all = group.recordings.allSatisfy { selectedRecordingIDs.contains($0.id) }
                group.recordings.filter { selectedRecordingIDs.contains($0.id) == all }.forEach { actions.toggleSelection($0.id) }
            } else {
                if expanded { expandedNotes.remove(group.key) } else { expandedNotes.insert(group.key) }
                actions.openNotes(group.key)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .accessibilityIdentifier("recordings.day.notes")
    }

    private func groupBlock(_ group: RecordingsDay.Group) -> some View {
        let isOn = !isSelectionMode && openSelection == .group(group.id)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: "square.stack").font(.system(size: 10))
                Text(group.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
            }
            ForEach(Array(group.recordings.enumerated()), id: \.element.id) { index, recording in
                attachedRow(recording, title: String(localized: "Part \(index + 1)"))
            }
        }
        .padding(EdgeInsets(top: 4, leading: 7, bottom: 5, trailing: 6))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .foregroundStyle(isOn ? Color.white : DS.Palette.text)
        .background(isOn ? DS.Palette.accentFill : DS.Palette.box, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture { actions.openGroup(group.id) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("recordings.day.group")
    }

    private func recordingBlock(_ recording: Recording) -> some View {
        let isOn = !isSelectionMode && openSelection?.opensRecording(recording.id) == true
        let overlap = RecordingsDay.overlappingEvents(for: recording, in: day.items)
        return HStack(alignment: .top, spacing: 6) {
            if isSelectionMode { checkmark(selectedRecordingIDs.contains(recording.id)) }
            VStack(alignment: .leading, spacing: 0) {
                Text(recording.displayTitle).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Text(recording.isVoiceNote ? statusLine(recording) : "\(duration(recording.durationSeconds)), \(statusLine(recording))")
                    .font(DS.Font.caption).lineLimit(1)
                    .foregroundStyle(isOn ? Color.white : DS.Palette.secondary)
            }
            Spacer(minLength: 0)
            if let event = overlap.first, !isSelectionMode {
                Button { actions.attach(recording.id, event) } label: {
                    Text("Attach").font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .foregroundStyle(DS.Palette.accentText)
                        .background(DS.Palette.tint, in: RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
                .help(Text("Attach to \(event.title)"))
                .accessibilityLabel(Text("Attach to \(event.title)"))
                .accessibilityIdentifier("recordings.day.attach")
            }
        }
        .padding(EdgeInsets(top: 3, leading: 7, bottom: 3, trailing: 7))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .foregroundStyle(isOn ? Color.white : DS.Palette.text)
        .background(isOn ? DS.Palette.accentFill : DS.Palette.card, in: RoundedRectangle(cornerRadius: 6))
        .overlay { if !isOn { RoundedRectangle(cornerRadius: 6).strokeBorder(DS.Palette.line, lineWidth: 1) } }
        .contentShape(Rectangle())
        .onTapGesture { tapRecording(recording.id) }
        .draggable(recording.id.uuidString)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .accessibilityIdentifier("recordings.day.recording")
    }

    // MARK: - Helpers

    private func tapRecording(_ id: UUID) {
        if isSelectionMode { actions.toggleSelection(id) } else { actions.openRecording(id) }
    }

    private func checkmark(_ on: Bool) -> some View {
        Image(systemName: on ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 13))
            .foregroundStyle(on ? DS.Palette.accent : DS.Palette.secondary)
    }

    private func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    private func duration(_ seconds: TimeInterval) -> String {
        Duration.seconds(seconds).formatted(.time(pattern: seconds >= 3600 ? .hourMinuteSecond : .minuteSecond))
    }

    private func statusLine(_ recording: Recording) -> String {
        RecordingsStatusText.short(recording)
    }
}

enum RecordingsStatusText {
    static func short(_ recording: Recording) -> String {
        switch recording.status {
        case .needsRecovery: String(localized: "Needs recovery")
        case .processing: String(localized: "Transcribing")
        case .failed: String(localized: "Failed")
        default:
            if recording.status.isInProgressCapture { String(localized: "Recording") }
            else if recording.displayTranscriptText != nil { String(localized: "Transcript ready") }
            else { String(localized: "Not transcribed yet") }
        }
    }
}
