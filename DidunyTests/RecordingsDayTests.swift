@testable import Diduny
import Foundation
import SwiftUI
import Testing

@Suite("Recordings day (redesign B)")
struct RecordingsDayTests {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Kyiv")!
        return calendar
    }()

    private var day: Date { calendar.date(from: DateComponents(year: 2026, month: 11, day: 9))! }

    private func at(_ hour: Int, _ minute: Int, dayOffset: Int = 0) -> Date {
        calendar.date(byAdding: .minute, value: (dayOffset * 24 + hour) * 60 + minute, to: day)!
    }

    private func recording(
        _ type: Recording.RecordingType, _ hour: Int, _ minute: Int, minutes: Double = 1,
        dayOffset: Int = 0, text: String? = nil, event: CalendarMeeting? = nil
    ) -> Recording {
        var recording = Recording(
            id: UUID(), createdAt: at(hour, minute, dayOffset: dayOffset), type: type, audioFileName: "a.wav",
            durationSeconds: minutes * 60, fileSizeBytes: 1, status: text == nil ? .unprocessed : .transcribed,
            transcriptionText: text, sourceDevice: nil
        )
        recording.calendarMeeting = event
        return recording
    }

    private func event(_ id: String, _ hour: Int, _ minute: Int, minutes: Int, title: String = "Standup",
                       dayOffset: Int = 0) -> CalendarMeeting {
        let start = at(hour, minute, dayOffset: dayOffset)
        return CalendarMeeting(id: id, calendarID: "work", title: title, start: start,
                               end: start.addingTimeInterval(Double(minutes) * 60))
    }

    private func build(_ recordings: [Recording], events: [CalendarMeeting] = [], groups: [RecordingsDayGroupInput] = [],
                       zoom: NotesZoom = .halfHour) -> RecordingsDay {
        RecordingsDay.build(day: day, recordings: recordings, events: events, groups: groups, zoom: zoom, calendar: calendar)
    }

    // MARK: Events and recordings

    @Test func linkedRecordingSitsInsideItsEventAndUnlinkedSitsBeside() {
        let standup = event("e1", 10, 0, minutes: 30)
        let linked = recording(.meeting, 10, 2, minutes: 40, event: standup) // runs past the end: fine
        let loose = recording(.meeting, 10, 5, minutes: 10)
        let result = build([linked, loose], events: [standup])

        guard case let .event(slot, _, _) = result.items.first(where: \.isEvent) else {
            Issue.record("no event"); return
        }
        #expect(slot.attached.map(\.id) == [linked.id])
        #expect(result.items.contains(.recording(loose, startMinute: 605, endMinute: 615)))
        #expect(RecordingsDay.overlappingEvents(for: loose, in: result.items).map(\.id) == ["e1"])
        #expect(RecordingsDay.overlappingEvents(for: linked, in: result.items).isEmpty)
    }

    @Test func eventWithoutRecordingAndRecordingWithoutEventBothShow() {
        let office = event("e2", 16, 30, minutes: 60, title: "Office hours")
        let alone = recording(.meeting, 9, 0, minutes: 20)
        let result = build([alone], events: [office])
        #expect(result.items.count == 2)
        #expect(result.items.contains { if case let .event(slot, _, _) = $0 { slot.attached.isEmpty } else { false } })
    }

    @Test func linkedEventShowsWithoutCalendarAccess() {
        let stored = event("e1", 14, 0, minutes: 30, title: "Hiring sync")
        let linked = recording(.meeting, 14, 1, minutes: 20, event: stored)
        let result = build([linked], events: [])
        guard case let .event(slot, _, _) = result.items.first else { Issue.record("no event"); return }
        #expect(slot.meeting.title == "Hiring sync")
        #expect(slot.attached.map(\.id) == [linked.id])
    }

    @Test func repeatingEventDaysDoNotMerge() {
        let monday = event("weekly", 10, 0, minutes: 30)
        let other = event("weekly", 10, 0, minutes: 30, dayOffset: 1)
        #expect(monday.reminderKey != other.reminderKey)
        let linkedToday = recording(.meeting, 10, 1, event: monday)
        let result = build([linkedToday], events: [monday, other])
        #expect(result.items.filter(\.isEvent).count == 1, "Tomorrow's occurrence is not on this day")
    }

    @Test func recordingBelongsByStartWhenTheStoredCopyIsAnotherOccurrence() {
        let today = event("weekly", 10, 0, minutes: 30)
        let stale = event("weekly", 10, 0, minutes: 30, dayOffset: -7)
        let inside = recording(.meeting, 10, 10, event: stale)
        let before = recording(.meeting, 9, 50, event: stale)
        #expect(RecordingsDay.eventKey(for: inside, in: [today]) == today.reminderKey)
        #expect(RecordingsDay.eventKey(for: before, in: [today]) == nil, "START must fall inside the event")
    }

    @Test func cancelledAndAllDayEventsAreHidden() {
        var cancelled = event("c", 11, 0, minutes: 30)
        cancelled.cancelled = true
        var allDay = event("a", 0, 0, minutes: 24 * 60)
        allDay.allDay = true
        #expect(build([], events: [cancelled, allDay]).items.isEmpty)
    }

    @Test func filesAreListedApartFromTheScale() {
        let file = recording(.fileTranscription, 17, 10)
        let result = build([file])
        #expect(result.items.isEmpty)
        #expect(result.files.map(\.id) == [file.id])
    }

    @Test func otherDaysAreLeftOut() {
        #expect(build([recording(.meeting, 10, 0, dayOffset: 1)]).isEmpty)
    }

    // MARK: Notes

    @Test func notesGroupByClockHalfHourAndAGroupOfOneShowsTheNote() {
        let a = recording(.voice, 10, 2), b = recording(.voice, 10, 29), c = recording(.voice, 10, 31)
        let result = build([a, b, c])
        #expect(result.items.count == 2)
        guard case let .notes(group, _, _) = result.items[0] else { Issue.record("no group"); return }
        #expect(group.recordings.map(\.id) == [a.id, b.id])
        #expect(group.bucketStartMinute == 600)
        #expect(result.items[1] == .recording(c, startMinute: 631, endMinute: 632))
    }

    @Test func zoomingInMakesGroupsFinerDownToSingleNotes() {
        let notes = [recording(.voice, 10, 2), recording(.voice, 10, 12), recording(.voice, 10, 14)]
        #expect(build(notes, zoom: .halfHour).items.count == 1)
        #expect(build(notes, zoom: .tenMinutes).items.count == 2)
        #expect(build(notes, zoom: .single).items.count == 3)
        #expect(NotesZoom.halfHour.zoomedOut == nil)
        #expect(NotesZoom.single.zoomedIn == nil)
        #expect(NotesZoom.halfHour.zoomedIn == .quarterHour)
        #expect(NotesZoom.allCases.map(\.hourHeight) == NotesZoom.allCases.map(\.hourHeight).sorted())
    }

    @Test func fortyNotesInHalfAnHourStayOneRowWithACountAndAFilter() {
        var notes = (0 ..< 40).map { recording(.voice, 18, 30 + $0 % 30, text: $0 < 30 ? "note \($0)" : nil) }
        notes.append(recording(.voice, 18, 59, minutes: 2.0 / 60))
        let result = build(notes)
        #expect(result.items.count == 1)
        guard case let .notes(group, _, _) = result.items[0] else { Issue.record("no group"); return }
        #expect(group.recordings.count == 41)
        let rows = NotesGroupRows.visible(group.recordings)
        #expect(rows.shown.count == 8)
        #expect(rows.hidden == 33)
        #expect(NotesListFilter.showsFilter(group.recordings))
        #expect(NotesListFilter.withoutTranscript.apply(group.recordings).count == 11)
        #expect(NotesListFilter.all.apply(group.recordings).count == 41)
    }

    @Test func noteDuringAMeetingStaysBesideTheEventUntilAttached() {
        let meeting = event("e1", 14, 0, minutes: 60)
        let note = recording(.voice, 14, 20)
        let result = build([note], events: [meeting])
        #expect(result.items.contains(.recording(note, startMinute: 860, endMinute: 861)))
        #expect(RecordingsDay.overlappingEvents(for: note, in: result.items).count == 1)
        let attached = recording(.voice, 14, 20, event: meeting)
        guard case let .event(slot, _, _) = build([attached], events: [meeting]).items.first else {
            Issue.record("no event"); return
        }
        #expect(slot.attached.count == 1)
    }

    // MARK: Groups

    @Test func groupShowsAsOneBlockAndALoneMemberFallsBack() {
        let a = recording(.meeting, 9, 0, minutes: 30), b = recording(.meeting, 9, 40, minutes: 20)
        let group = RecordingsDayGroupInput(id: UUID(), name: "Campaign", recordingIDs: [b.id, a.id])
        let result = build([a, b], groups: [group])
        #expect(result.items.count == 1)
        guard case let .group(shown, start, end) = result.items[0] else { Issue.record("no group"); return }
        #expect(shown.recordings.map(\.id) == [a.id, b.id])
        #expect(start == 540 && end == 600)

        let lonely = RecordingsDayGroupInput(id: UUID(), name: "One", recordingIDs: [a.id])
        #expect(build([a], groups: [lonely]).items == [.recording(a, startMinute: 540, endMinute: 570)])
    }

    // MARK: Placement

    @Test func blocksStartAtTheirTimeAndAreAsTallAsTheyLast() {
        let long = recording(.meeting, 10, 15, minutes: 45)
        let short = recording(.meeting, 12, 0, minutes: 0.5)
        let placement = RecordingsDayPlacement.place(build([long, short]).items, hourHeight: 96)
        let longFrame = placement.frames.first { $0.id == "recording:" + long.id.uuidString }!
        #expect(placement.startHour == 10)
        #expect(longFrame.top == 24, "10:15 is a quarter of an hour below 10:00")
        #expect(longFrame.height == 72 && longFrame.trueHeight == 72, "45 min fills 45 min")
        let shortFrame = placement.frames.first { $0.id == "recording:" + short.id.uuidString }!
        #expect(shortFrame.height == RecordingsDayPlacement.minimumHeight, "Readable minimum")
        #expect(abs(shortFrame.trueHeight - 0.8) < 0.001, "The true span stays visible")
        #expect(placement.hours.first { $0.hour == 12 }?.y == 192, "Hour lines are never shifted")
    }

    @Test func overlappingBlocksGoIntoLanes() {
        let review = event("r", 16, 30, minutes: 60), office = event("o", 16, 30, minutes: 60, title: "Office")
        let later = recording(.meeting, 18, 0, minutes: 30)
        let placement = RecordingsDayPlacement.place(build([later], events: [review, office]).items, hourHeight: 96)
        let events = placement.frames.filter { $0.id.hasPrefix("event:") }
        #expect(events.map(\.columns) == [2, 2])
        #expect(Set(events.map(\.column)) == [0, 1])
        #expect(placement.frames.first { $0.id.hasPrefix("recording:") }?.columns == 1, "Later items get the full width")
    }

    @Test func lanesReuseAFreeLaneAndShareTheClusterCount() {
        let lanes = RecordingsDayPlacement.lanes([("a", 0, 100), ("b", 10, 30), ("c", 40, 60), ("d", 200, 220)])
        #expect(lanes["a"]! == (0, 2) && lanes["b"]! == (1, 2))
        #expect(lanes["c"]! == (1, 2), "c reuses the lane b freed")
        #expect(lanes["d"]! == (0, 1))
    }

    @Test func recordingsInsideAnEventSitAtTheirRealTimes() {
        let interview = event("i", 12, 0, minutes: 60)
        let first = recording(.meeting, 12, 1, minutes: 59, event: interview)
        let second = recording(.meeting, 13, 2, minutes: 45, event: interview) // runs past the end
        let items = build([first, second], events: [interview]).items
        guard case let .event(slot, start, _) = items.first else { Issue.record("no event"); return }
        let inner = RecordingsDayPlacement.children(slot.spans, containerStart: start, hourHeight: 96)
        #expect(abs(inner[0].top - 1.6) < 0.001 && abs(inner[1].top - 99.2) < 0.001)
        #expect(abs(inner[1].height - 72) < 0.001)
        let frame = RecordingsDayPlacement.place(items, hourHeight: 96).frames[0]
        #expect(abs(frame.height - (99.2 + 72)) < 0.001, "The event column holds a recording that runs past its end")
        #expect(frame.trueHeight == 96, "The event itself spans its time")
    }

    @Test func processingStateShowsOnTheBlockAndItsParent() {
        var working = recording(.meeting, 10, 0)
        working.status = .processing
        var failed = recording(.voice, 10, 0)
        failed.status = .failed
        let done = recording(.voice, 10, 0, text: "ok")
        #expect(RecordingsProcessingState.of(working) == .working)
        #expect(RecordingsProcessingState.of(failed) == .failed)
        #expect(RecordingsProcessingState.of(done) == .none)
        #expect(RecordingsProcessingState.of([done, failed, working]) == .working)
        #expect(RecordingsProcessingState.of([done, failed]) == .failed)
        #expect(RecordingsProcessingState.of([done]) == .none)
    }

    // MARK: Week, segments, names

    @Test func weekHasSevenDaysContainingTheDay() {
        let week = RecordingsWeek.days(containing: day, calendar: calendar)
        #expect(week.count == 7)
        #expect(week.contains(calendar.startOfDay(for: day)))
    }

    @Test func segmentsReplaceTheTypeDropdown() {
        let meeting = recording(.meeting, 9, 0), note = recording(.translation, 9, 0), file = recording(.fileTranscription, 9, 0)
        #expect(RecordingsSegment.meetings.matches(meeting) && !RecordingsSegment.meetings.matches(note))
        #expect(RecordingsSegment.notes.matches(note) && !RecordingsSegment.notes.matches(file))
        #expect(RecordingsSegment.filesAndLinks.matches(file) && !RecordingsSegment.filesAndLinks.matches(meeting))
        #expect([meeting, note, file].allSatisfy(RecordingsSegment.all.matches))
    }

    @Test func nameSuggestionComesFromTheEventElseTheTranscript() {
        var linked = recording(.meeting, 10, 0, event: event("e", 10, 0, minutes: 30, title: "Hiring sync"))
        #expect(RecordingNameSuggestion.make(for: linked) == nil, "The title already is the event's")
        linked.title = "Candidates, round 2"
        #expect(RecordingNameSuggestion.make(for: linked) == .init(source: .event, name: "Hiring sync"))

        let spoken = recording(.meeting, 10, 0, text: "Plan for December and the contract. Then other things.")
        #expect(RecordingNameSuggestion.make(for: spoken) == .init(source: .transcript, name: "Plan for December and the contract"))

        #expect(RecordingNameSuggestion.make(for: recording(.meeting, 10, 0)) == nil)
    }

    @Test func voiceNotesCanAttachButFilesCannot() {
        #expect(Recording.RecordingType.voice.canAttachCalendarEvent)
        #expect(Recording.RecordingType.meeting.canAttachCalendarEvent)
        #expect(!Recording.RecordingType.fileTranscription.canAttachCalendarEvent)
    }

    // MARK: Inspector

    @Test func resultShowsTheCurrentRunWithTranslationsAsTabsAndOlderRunsAsPreviousVersions() {
        var r = recording(.meeting, 10, 0, text: "hello")
        let t0 = at(10, 0)
        r.transcriptHistory = [
            TranscriptVersion(createdAt: t0, kind: .cloud, text: "first"),
            TranscriptVersion(createdAt: t0.addingTimeInterval(60), kind: .local, text: "second"),
            TranscriptVersion(createdAt: t0.addingTimeInterval(120), kind: .translation, targetLanguageCode: "uk", text: "uk 1"),
            TranscriptVersion(createdAt: t0.addingTimeInterval(180), kind: .local, text: "third"),
            TranscriptVersion(createdAt: t0.addingTimeInterval(240), kind: .translation, targetLanguageCode: "uk", text: "uk 2"),
            TranscriptVersion(createdAt: t0.addingTimeInterval(300), kind: .translation, targetLanguageCode: "en", text: "en")
        ]
        let versions = RecordingVersions(r)
        #expect(versions.current?.text == "third")
        #expect(versions.previousCount == 2)
        #expect(versions.translations.map(\.text) == ["uk 2", "en"], "Newest per language, one tab each")
    }

    @Test func pageWidthsAt1000_1280_1700WithTheInspectorOpenAndClosed() {
        #expect(RecordingsPageLayout.inspectorWidth(windowWidth: 1000) == 400)
        #expect(RecordingsPageLayout.inspectorWidth(windowWidth: 1280) == 480)
        #expect(RecordingsPageLayout.inspectorWidth(windowWidth: 1700) == 560)
        let column = { RecordingsPageLayout.columnWidth(windowWidth: $0, inspectorOpen: $1) }
        #expect(column(1000, true) == 361)
        #expect(column(1000, true) >= RecordingsPageLayout.minimumColumnWidth, "The day stays usable at 1000")
        #expect(RecordingsPageLayout.isCompact(columnWidth: column(1000, true)))
        #expect(RecordingsPageLayout.isCompact(columnWidth: column(1280, true)))
        #expect(!RecordingsPageLayout.isCompact(columnWidth: column(1000, false)))
        #expect(!RecordingsPageLayout.isCompact(columnWidth: column(1280, false)))
        #expect(!RecordingsPageLayout.isCompact(columnWidth: column(1700, true)))
    }

    @Test func openStateFollowsTheSelection() {
        let id = UUID()
        #expect(RecordingsInspectorSelection.recording(id, parentBatchID: nil).opensRecording(id))
        #expect(!RecordingsInspectorSelection.recording(id, parentBatchID: nil).marksRow(id, isSelectionMode: true))
        #expect(!RecordingsInspectorSelection.event("k").opensRecording(id))
    }

    @Test func theDayIsBuiltOncePerInputChangeNotPerRead() {
        let many = (0 ..< 500).map { recording($0 % 3 == 0 ? .voice : .meeting, 8 + $0 % 12, $0 % 60) }
        var cache = RecordingsDayCache()
        let inputs = { (zoom: NotesZoom) in
            RecordingsDayCache.Inputs(day: self.at(13, 0), recordings: many, events: [], groups: [], zoom: zoom)
        }
        cache.update(inputs(.halfHour))
        cache.update(inputs(.halfHour))
        #expect(cache.builds == 1, "Same inputs, no rebuild")
        _ = cache.day; _ = cache.day
        cache.update(inputs(.quarterHour))
        #expect(cache.builds == 2, "One zoom step, one rebuild")
    }

    @Test func dstDayAndEventsCrossingMidnightStayOnTheirDay() {
        // 2026-03-29 is 23 hours long in Kyiv (clocks go forward at 03:00).
        let dst = calendar.date(from: DateComponents(year: 2026, month: 3, day: 29, hour: 22))!
        let late = Recording(id: UUID(), createdAt: dst, type: .meeting, audioFileName: "a", durationSeconds: 60,
                             fileSizeBytes: 1, status: .unprocessed, sourceDevice: nil)
        let built = RecordingsDay.build(day: dst, recordings: [late], events: [], zoom: .halfHour, calendar: calendar)
        #expect(built.items.count == 1)
        #expect(built.items[0].startMinute == 22 * 60, "Wall clock, so the 22:00 label is right on a DST day")

        let overnight = event("n", 23, 30, minutes: 60)
        let today = build([], events: [overnight]).items
        // Minutes are fractional (seconds and nanoseconds), so compare within a millisecond-scale tolerance.
        #expect(abs((today.first?.endMinute ?? 0) - 24 * 60) < 0.001, "Clipped at midnight")
        let tomorrow = RecordingsDay.build(day: at(12, 0, dayOffset: 1), recordings: [], events: [overnight],
                                           zoom: .halfHour, calendar: calendar).items
        #expect(abs((tomorrow.first?.startMinute ?? -1) - 0) < 0.001, "Shows from 0:00 on the next day")
    }

    @Test func draggingOutOfItsOwnEventDetachesAndNothingElseDoes() {
        #expect(RecordingsDrop.decide(sourceEventKey: "a", targetEventKey: nil) == .detach)
        #expect(RecordingsDrop.decide(sourceEventKey: "a", targetEventKey: "b") == .attach(eventKey: "b"))
        #expect(RecordingsDrop.decide(sourceEventKey: "a", targetEventKey: "a") == .nothing)
        #expect(RecordingsDrop.decide(sourceEventKey: nil, targetEventKey: nil) == .nothing)
        #expect(RecordingsDrop.decide(sourceEventKey: nil, targetEventKey: "b") == .attach(eventKey: "b"))

        let meeting = event("e", 12, 0, minutes: 90)
        let inside = recording(.meeting, 13, 0, event: meeting)
        let loose = recording(.meeting, 9, 0)
        let items = build([inside, loose], events: [meeting]).items
        #expect(RecordingsDrop.sourceEventKey(of: inside.id, in: items) == meeting.reminderKey)
        #expect(RecordingsDrop.sourceEventKey(of: loose.id, in: items) == nil)
    }

    @Test func scrollGoesToNowOrTheFirstItem() {
        let items = build([recording(.meeting, 11, 30), recording(.meeting, 9, 15)]).items
        #expect(RecordingsDayScroll.targetMinute(items: items, nowMinute: nil) == 555)
        #expect(RecordingsDayScroll.targetMinute(items: items, nowMinute: 840) == 840)
        #expect(RecordingsDayScroll.targetMinute(items: [], nowMinute: nil) == nil)
        #expect(RecordingsDayScroll.minuteOfDay(at(14, 5), calendar: calendar) == 845)
    }
}
