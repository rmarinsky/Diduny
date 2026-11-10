import SwiftUI
import UniformTypeIdentifiers

/// What the day can ask the library to do. The library owns storage, undo and the inspector.
struct RecordingsDayActions {
    var openRecording: (UUID) -> Void
    var openEvent: (String) -> Void
    var openNotes: (String) -> Void
    var openGroup: (UUID) -> Void
    var attach: (UUID, CalendarMeeting) -> Void
    /// A recording dragged out of its event and dropped outside every event.
    var detachByDrag: (UUID) -> Void
    var toggleSelection: (UUID) -> Void
}

/// Variant B: a week strip, then the day on an hour scale. Events with their recordings inside, unattached
/// recordings beside them, dictation notes (voice and translation) grouped by the zoom level, files and links listed under the scale.
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
    /// The recording being dragged, set when its drag preview appears.
    @State private var draggingID: UUID?
    @State private var railTargeted = false
    /// Where the scale scrolls next: a minute of day and where it lands in the view.
    @State private var scrollMinute: Double?
    @State private var scrollAnchor = UnitPoint.top
    @State private var scrollRequest = 0
    private let calendar = Calendar.current

    /// The day column never gets narrower than this; below it the page scrolls sideways.
    static var minimumWidth: CGFloat { 300 }
    private static var railInset: CGFloat { 42 }
    private static var rowHeight: Double { 24 }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            HStack(spacing: DS.Space.sm) {
                weekStrip
                zoomButtons
            }
            GeometryReader { proxy in
                ScrollViewReader { scroller in
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
                .overlay(alignment: .top) { detachHint }
                .onChange(of: scrollRequest) {
                    // After the marker moved to the new minute.
                    DispatchQueue.main.async {
                        withAnimation(DS.Motion.easeOut(0.25)) { scroller.scrollTo(Self.scrollMarkerID, anchor: scrollAnchor) }
                    }
                }
                }
            }
            .onAppear { scrollToFirstItem() }
            .onChange(of: calendar.startOfDay(for: selectedDay)) { scrollToFirstItem() }
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

    private static var scrollMarkerID: String { "recordings.day.scrollTarget" }

    private func scrollToFirstItem() {
        guard let minute = RecordingsDayScroll.targetMinute(items: day.items, nowMinute: nil) else { return }
        scroll(to: max(0, minute - 10), anchor: .top)
    }

    private func scroll(to minute: Double, anchor: UnitPoint) {
        scrollMinute = minute
        scrollAnchor = anchor
        scrollRequest += 1
    }

    /// "Now": today, with the current time about a third from the top.
    private func goToNow() {
        let now = Date()
        selectedDay = now
        let minute = RecordingsDayScroll.minuteOfDay(now, calendar: calendar)
        // Wait for the new day to lay out before scrolling.
        DispatchQueue.main.async {
            scroll(to: minute, anchor: UnitPoint(x: 0, y: RecordingsDayScroll.nowAnchor))
        }
    }

    @ViewBuilder
    private var detachHint: some View {
        if let draggingID, railTargeted, dropTarget == nil,
           RecordingsDrop.sourceEventKey(of: draggingID, in: day.items) != nil
        {
            Label("Release to detach from the event", systemImage: "arrow.up.left.and.arrow.down.right")
                .font(DS.Font.calloutStrong)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .foregroundStyle(DS.Palette.accentText)
                .background(DS.Palette.tint, in: Capsule())
                .padding(.top, DS.Space.sm)
                .accessibilityIdentifier("recordings.day.detachHint")
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
            Button("Now") { goToNow() }
                .controlSize(.small)
                .keyboardShortcut("t", modifiers: .command)
                .help("Go to today, at the current time (⌘T)")
                .accessibilityIdentifier("recordings.week.now")
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
        let railWidth = max(0, width - Self.railInset - 6)
        let placement = RecordingsDayPlacement.place(day.items, hourHeight: zoom.hourHeight, width: railWidth)
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
            if let scrollMinute {
                VStack(spacing: 0) {
                    Color.clear.frame(height: max(0, RecordingsDayPlacement.y(scrollMinute, startHour: placement.startHour,
                                                                               hourHeight: placement.hourHeight)))
                    Color.clear.frame(width: 1, height: 1).id(Self.scrollMarkerID)
                }
                .accessibilityHidden(true)
            }
            ForEach(placement.frames, id: \.id) { frame in
                if let item = byID[frame.id] {
                    let gap: CGFloat = frame.columns > 1 ? 4 : 0
                    let columnWidth = railWidth / CGFloat(frame.columns)
                    let blockWidth = max(0, columnWidth - gap)
                    let expanded = expandedHeight(item)
                    block(item, width: blockWidth, frame: frame)
                        .frame(width: blockWidth, height: max(frame.height, expanded ?? 0), alignment: .topLeading)
                        .offset(x: Self.railInset + columnWidth * CGFloat(frame.column), y: frame.top)
                        // An open notes list floats over what follows; the times underneath stay true.
                        .zIndex(expanded == nil ? 0 : 1)
                        .shadow(color: expanded == nil ? .clear : .black.opacity(0.18), radius: 8, y: 3)
                }
            }
            ForEach(placement.overflow, id: \.top) { more in
                overflowChip(more.ids.compactMap { byID[$0] })
                    .offset(x: Self.railInset + railWidth - 34, y: more.top)
                    .zIndex(2)
            }
        }
        .frame(width: width, height: placement.height, alignment: .topLeading)
        .contentShape(Rectangle())
        // Outside every event: a recording dragged out of its own event detaches; anything else springs back.
        .dropDestination(for: String.self) { ids, _ in
            defer { draggingID = nil }
            guard let id = ids.first.flatMap(UUID.init(uuidString:)) else { return false }
            let source = RecordingsDrop.sourceEventKey(of: id, in: day.items)
            guard RecordingsDrop.decide(sourceEventKey: source, targetEventKey: nil) == .detach else { return false }
            actions.detachByDrag(id)
            return true
        } isTargeted: { railTargeted = $0 }
        .padding(.top, 8)
        .animation(DS.Motion.easeOut(0.18), value: zoom)
    }

    /// The height an open notes group needs for its rows, or nil when it is closed.
    private func expandedHeight(_ item: RecordingsDay.Item) -> Double? {
        guard case let .notes(group, _, _) = item, expandedNotes.contains(group.key) else { return nil }
        return 40 + Double(min(group.recordings.count, NotesGroupRows.shownWhenLong + 1)) * Self.rowHeight
    }

    @ViewBuilder
    private func block(_ item: RecordingsDay.Item, width: CGFloat, frame: RecordingsDayPlacement.Frame) -> some View {
        switch item {
        case let .event(event, start, _): eventBlock(event, start: start, width: width)
        case let .notes(group, _, _): notesBlock(group, frame: frame)
        case let .group(group, start, _): groupBlock(group, start: start, width: width)
        case let .recording(recording, _, _): recordingBlock(recording, frame: frame, width: width)
        }
    }

    /// Spinner while any of these recordings is transcribed; a warning when one failed.
    @ViewBuilder
    private func stateMark(_ state: RecordingsProcessingState, isOn: Bool) -> some View {
        switch state {
        case .working:
            ProgressView().controlSize(.mini)
                .accessibilityLabel(Text("Transcribing"))
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10))
                .foregroundStyle(isOn ? Color.white : DS.Palette.no)
                .accessibilityLabel(Text("Failed"))
        case .none:
            EmptyView()
        }
    }

    /// Share of an event's width given to its title when recordings stand inside it at their real times.
    private static var titleShare: CGFloat { 0.4 }
    /// Below this an event stacks its title above its recordings.
    static var stackedEventWidth: CGFloat { 260 }
    /// Below this "Attach" is an icon with a tooltip.
    private static var compactBlockWidth: CGFloat { 170 }

    /// "+N": items that did not fit a readable lane, listed in a menu that opens them.
    private func overflowChip(_ items: [RecordingsDay.Item]) -> some View {
        Menu {
            ForEach(items) { item in
                Button(Self.menuTitle(item)) { open(item) }
            }
        } label: {
            Text(verbatim: "+\(items.count)").font(.system(size: 11, weight: .semibold))
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .controlSize(.mini)
        .fixedSize()
        .help(Text("\(items.count) more at this time"))
        .accessibilityLabel(Text("\(items.count) more at this time"))
        .accessibilityIdentifier("recordings.day.overflow")
    }

    private static func menuTitle(_ item: RecordingsDay.Item) -> String {
        switch item {
        case let .event(event, _, _): event.meeting.title
        case let .recording(recording, _, _): "\(recording.createdAt.formatted(date: .omitted, time: .shortened)) \(recording.displayTitle)"
        case let .notes(group, _, _): String(localized: "\(group.recordings.count) dictation notes")
        case let .group(group, _, _): group.name
        }
    }

    private func open(_ item: RecordingsDay.Item) {
        switch item {
        case let .event(event, _, _): actions.openEvent(event.key)
        case let .recording(recording, _, _): actions.openRecording(recording.id)
        case let .notes(group, _, _): actions.openNotes(group.key)
        case let .group(group, _, _): actions.openGroup(group.id)
        }
    }

    private func eventBlock(_ event: RecordingsDay.Event, start: Double, width: CGFloat) -> some View {
        let isOn = !isSelectionMode && openSelection == .event(event.key)
        let stripe = event.meeting.calendarColorRGB.map { Color(rgb: $0) } ?? DS.Palette.secondary
        let hasChildren = !event.spans.isEmpty
        // Narrow event: title on top, recordings below it on the time scale; wide: title beside them.
        let stacked = hasChildren && width < Self.stackedEventWidth
        let titleHeight: Double = stacked ? 34 : 0
        let childX = stacked ? 0 : hasChildren ? width * Self.titleShare : width
        let childRegion = max(0, width - childX - 3)
        let fitted = RecordingsDayPlacement.fit(
            RecordingsDayPlacement.children(event.spans, containerStart: start, hourHeight: zoom.hourHeight, topInset: titleHeight),
            maxLanes: RecordingsDayPlacement.maxLanes(width: childRegion, minimumLaneWidth: RecordingsDayPlacement.minimumChildLaneWidth))
        let children = fitted.frames
        let byID = Dictionary(uniqueKeysWithValues: event.spans.map { ($0.recording.id.uuidString, $0.recording) })
        let eventHeight = RecordingsDayPlacement.heights(start: start, end: start + event.meeting.end.timeIntervalSince(event.meeting.start) / 60,
                                                         hourHeight: zoom.hourHeight).drawn
        return ZStack(alignment: .topLeading) {
            // The event's own time; recordings that run past its end hang below it.
            RoundedRectangle(cornerRadius: 6)
                .fill(isOn ? DS.Palette.accentFill : DS.Palette.box)
                .frame(height: eventHeight)
                .overlay(alignment: .leading) {
                    Rectangle().fill(stripe).frame(width: 3).clipShape(RoundedRectangle(cornerRadius: 1.5))
                        .padding(.vertical, 3).padding(.leading, 3)
                }
                .overlay {
                    if dropTarget == event.key {
                        RoundedRectangle(cornerRadius: 6).strokeBorder(DS.Palette.accent, lineWidth: 2)
                    }
                }
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(event.meeting.title).font(.system(size: 12, weight: .semibold))
                        .lineLimit(stacked || !hasChildren ? 2 : 4)
                        .truncationMode(.tail)
                    stateMark(.of(event.attached), isOn: isOn)
                }
                if event.attached.isEmpty {
                    Text("not recorded").font(DS.Font.caption).lineLimit(1)
                        .foregroundStyle(isOn ? Color.white : DS.Palette.secondary)
                }
            }
            .padding(EdgeInsets(top: 4, leading: 10, bottom: 0, trailing: 4))
            .frame(width: stacked ? width : childX, alignment: .leading)
            .frame(maxHeight: stacked ? titleHeight : eventHeight, alignment: .topLeading)
            .clipped()
            ForEach(children, id: \.id) { child in
                if let recording = byID[child.id] {
                    let laneWidth = childRegion / CGFloat(child.columns)
                    childBlock(recording, frame: child)
                        .frame(width: max(0, laneWidth - (child.columns > 1 ? 2 : 0)), height: child.height, alignment: .topLeading)
                        .offset(x: childX + (stacked ? 6 : 0) + laneWidth * CGFloat(child.column), y: child.top)
                }
            }
            ForEach(fitted.overflow, id: \.top) { more in
                overflowChip(more.ids.compactMap { id in byID[id].map { RecordingsDay.Item.recording($0, startMinute: 0, endMinute: 0) } })
                    .offset(x: max(0, width - 34), y: more.top)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .foregroundStyle(isOn ? Color.white : DS.Palette.text)
        .contentShape(Rectangle())
        .onTapGesture { actions.openEvent(event.key) }
        .accessibilityAction { actions.openEvent(event.key) }
        .dropDestination(for: String.self) { ids, _ in
            defer { draggingID = nil }
            guard let id = ids.first.flatMap(UUID.init(uuidString:)) else { return false }
            let source = RecordingsDrop.sourceEventKey(of: id, in: day.items)
            guard case .attach = RecordingsDrop.decide(sourceEventKey: source, targetEventKey: event.key) else { return false }
            actions.attach(id, event.meeting)
            return true
        } isTargeted: { targeted in
            dropTarget = targeted ? event.key : (dropTarget == event.key ? nil : dropTarget)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Calendar event: \(event.meeting.title)"))
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("recordings.day.event")
    }

    /// A recording inside an event or group, as tall as it lasts.
    private func childBlock(_ recording: Recording, frame: RecordingsDayPlacement.Frame, title: String? = nil) -> some View {
        let isOn = !isSelectionMode && openSelection?.opensRecording(recording.id) == true
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                if isSelectionMode { checkmark(selectedRecordingIDs.contains(recording.id)) }
                Text(title ?? time(recording.createdAt)).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                stateMark(.of(recording), isOn: isOn)
            }
            if frame.height >= 40 {
                Text(recording.isVoiceNote ? statusLine(recording) : "\(duration(recording.durationSeconds)), \(statusLine(recording))")
                    .font(DS.Font.caption).lineLimit(1)
                    .foregroundStyle(isOn ? Color.white : DS.Palette.secondary)
            }
        }
        .padding(EdgeInsets(top: 3, leading: 7, bottom: 2, trailing: 4))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .foregroundStyle(isOn ? Color.white : DS.Palette.text)
        .background(isOn ? DS.Palette.accentFill : DS.Palette.card, in: RoundedRectangle(cornerRadius: 5))
        .overlay(alignment: .topLeading) { trueSpanBar(frame) }
        .contentShape(Rectangle())
        .onTapGesture { tapRecording(recording.id) }
        .accessibilityAction { tapRecording(recording.id) }
        .draggable(recording.id.uuidString) { dragPreview(recording) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("recordings.day.attached")
    }

    /// The real span of a block drawn taller than it lasts.
    @ViewBuilder
    private func trueSpanBar(_ frame: RecordingsDayPlacement.Frame) -> some View {
        if frame.trueHeight < frame.height {
            Rectangle().fill(DS.Palette.accent)
                .frame(width: 3, height: max(2, frame.trueHeight))
                .accessibilityHidden(true)
        }
    }

    private func notesBlock(_ group: RecordingsDay.NotesGroup, frame: RecordingsDayPlacement.Frame) -> some View {
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
                    HStack(spacing: 4) {
                        Text("\(group.recordings.count) dictation notes").font(.system(size: 12, weight: .semibold)).lineLimit(1)
                        stateMark(.of(group.recordings), isOn: isOn)
                    }
                    if frame.height >= 40 || expanded {
                        Text(verbatim: "\(time(group.recordings[0].createdAt))-\(time(group.recordings.last!.createdAt)), \(duration(total))")
                            .font(DS.Font.caption).lineLimit(1)
                            .foregroundStyle(isOn ? Color.white : DS.Palette.secondary)
                    }
                }
            }
            if expanded {
                ForEach(rows.shown) { note in
                    childBlock(note, frame: .init(id: note.id.uuidString, top: 0, height: 21, trueHeight: 21, column: 0, columns: 1))
                        .frame(height: 21)
                }
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
        .overlay(alignment: .topLeading) { if !expanded { trueSpanBar(frame) } }
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
        .accessibilityAction { actions.openNotes(group.key) }
        .accessibilityLabel(Text("\(group.recordings.count) dictation notes"))
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .accessibilityIdentifier("recordings.day.notes")
    }

    private func groupBlock(_ group: RecordingsDay.Group, start: Double, width: CGFloat) -> some View {
        let isOn = !isSelectionMode && openSelection == .group(group.id)
        let childX = width * Self.titleShare
        let children = RecordingsDayPlacement.fit(
            RecordingsDayPlacement.children(group.spans, containerStart: start, hourHeight: zoom.hourHeight),
            maxLanes: RecordingsDayPlacement.maxLanes(width: max(0, width - childX - 3),
                                                      minimumLaneWidth: RecordingsDayPlacement.minimumChildLaneWidth)).frames
        let parts = Dictionary(uniqueKeysWithValues: group.recordings.enumerated().map { ($1.id.uuidString, ($0, $1)) })
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 6).fill(isOn ? DS.Palette.accentFill : DS.Palette.box)
            HStack(alignment: .top, spacing: 4) {
                Image(systemName: "square.stack").font(.system(size: 10))
                Text(group.name).font(.system(size: 12, weight: .semibold)).lineLimit(4)
                stateMark(.of(group.recordings), isOn: isOn)
            }
            .padding(EdgeInsets(top: 4, leading: 7, bottom: 0, trailing: 4))
            .frame(width: childX, alignment: .leading)
            ForEach(children, id: \.id) { child in
                if let part = parts[child.id] {
                    let laneWidth = (width - childX - 3) / CGFloat(child.columns)
                    childBlock(part.1, frame: child, title: String(localized: "Part \(part.0 + 1)"))
                        .frame(width: max(0, laneWidth - (child.columns > 1 ? 2 : 0)), height: child.height, alignment: .topLeading)
                        .offset(x: childX + laneWidth * CGFloat(child.column), y: child.top)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .foregroundStyle(isOn ? Color.white : DS.Palette.text)
        .contentShape(Rectangle())
        .onTapGesture { actions.openGroup(group.id) }
        .accessibilityAction { actions.openGroup(group.id) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("recordings.day.group")
    }

    private func recordingBlock(_ recording: Recording, frame: RecordingsDayPlacement.Frame, width: CGFloat) -> some View {
        let isOn = !isSelectionMode && openSelection?.opensRecording(recording.id) == true
        let overlap = RecordingsDay.overlappingEvents(for: recording, in: day.items)
        return HStack(alignment: .top, spacing: 6) {
            if isSelectionMode { checkmark(selectedRecordingIDs.contains(recording.id)) }
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 4) {
                    Text(recording.displayTitle).font(.system(size: 12, weight: .semibold))
                        .lineLimit(frame.height >= 44 ? 2 : 1).truncationMode(.tail)
                    stateMark(.of(recording), isOn: isOn)
                }
                if frame.height >= 40 {
                    Text(recording.isVoiceNote ? statusLine(recording) : "\(duration(recording.durationSeconds)), \(statusLine(recording))")
                        .font(DS.Font.caption).lineLimit(1)
                        .foregroundStyle(isOn ? Color.white : DS.Palette.secondary)
                }
            }
            Spacer(minLength: 0)
            if let event = overlap.first, !isSelectionMode {
                Button { actions.attach(recording.id, event) } label: {
                    Group {
                        if width < Self.compactBlockWidth {
                            Image(systemName: "link").font(.system(size: 10, weight: .semibold))
                        } else {
                            Text("Attach").font(.system(size: 11, weight: .semibold))
                        }
                    }
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
        .overlay(alignment: .topLeading) { trueSpanBar(frame) }
        .contentShape(Rectangle())
        .onTapGesture { tapRecording(recording.id) }
        .accessibilityAction { tapRecording(recording.id) }
        .draggable(recording.id.uuidString) { dragPreview(recording) }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("recordings.day.recording")
    }

    private func dragPreview(_ recording: Recording) -> some View {
        Text(recording.displayTitle)
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(DS.Palette.card, in: RoundedRectangle(cornerRadius: 5))
            .onAppear { draggingID = recording.id }
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
