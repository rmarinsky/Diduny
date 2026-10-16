# Calendar integration release candidate

Scope requested 2026-10-16: move the approved calendar prototype into Diduny, test and prepare a candidate. This branch starts at origin/main 21c4c2a. The standalone prototype and other worktrees remain separate.

## Acceptance

- Calendar connections and scoped consent survive restart; disconnect revokes future reads and rejects late results.
- Browser/profile selection uses existing metadata and native menus, without extracting credentials. Browser limitations must remain visible.
- Selected calendars provide upcoming meetings in the menu bar and Meetings settings, with independent display horizon and reminder lead time.
- Reminders support a dismissible pop-up and optional full-screen presentation; never start a recording without an explicit Join/record action.
- Join opens the validated meeting link through the default URL handler. A separate checkbox requests recording. Local recording/transcription is the default for calendar-initiated recording, with no silent cloud fallback.
- The recording stores an optional calendar occurrence reference. Existing recordings remain decodable; recovery/finalization preserve the reference. An active recording is never toggled off by a calendar action.
- Stale, declined, cancelled, past and deselected events cannot create reminders. Moved occurrences reconcile; reminders do not repeat after reopening the app.
- Candidate preparation is local build, tests, release highlights and evidence. No merge, tag, Sparkle update or public release is authorized by this task.

## Source and reference

Current Diduny composition: MainWindowView -> Meetings/MeetingSettingsView; DidunyApp -> MenuBarContentView; AppDelegate.toggleMeetingRecording -> existing local/cloud meeting pipeline -> RecordingsLibraryStorage. Preserve these entry points. Existing meeting suggestions remain available.

Prior reference: wrapper/design-reference/2026-10-16-calendar-persistent. Browser reader0.3 proved list reads/restoration but not complete occurrence/link/time mapping. Edge repeated naming still has a runtime verification gap. Do not market that snapshot as a complete calendar subscription.

Source adapter decision pending: recommended native EventKit for accounts configured in macOS, with the browser path as additional bounded access. The scheduling/domain/storage seams are independent of that choice.

## Verification plan

Each slice: closest existing XCTest or new domain boundary test, intended red, implementation, green. Real app test target exercises storage and orchestration. Native verification covers connection, calendar selection, menu, popup/full-screen, default-browser Join without recording, disconnect/restart and failure recovery. Audio capture must not run merely to make screenshots. Two independent reviews and dated reference update precede readiness. Any unavailable live path is a candidate blocker, not a passing result.
