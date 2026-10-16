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

Implemented source: native EventKit for accounts configured in macOS, with the browser path as additional bounded access. This follows the recommended default stated during implementation. Browser-only complete occurrence/time/link synchronization is not claimed.

## Verification plan

Each slice: closest existing XCTest or new domain boundary test, intended red, implementation, green. Real app test target exercises storage and orchestration. Native verification covers connection, calendar selection, menu, popup/full-screen, default-browser Join without recording, disconnect/restart and failure recovery. Audio capture must not run merely to make screenshots. Two independent reviews and dated reference update precede readiness. Any unavailable live path is a candidate blocker, not a passing result.

## Candidate outcome

Implementation revision `4c3ca5a96dfe7f4a7a1e41b03538d09ec3d44d4d`, based on `21c4c2a`.

- Full app XCTest/Swift Testing result: 474 total, **467 passed, 7 skipped, 0 failed**, 38.784 seconds. Five skips require configured native/cloud E2E; one requires a video fixture; one requires live YouTube access. Targeted app subset: 44 passed. Same-source isolated core/browser harness: 25 passed. These overlap and are not additive coverage.
- Release-highlights pipeline: 3 Python tests passed; bundled release-copy test passed after updating its previous-release expectation.
- Two independent read-only reviews completed. Resolved findings: incorrect playback argument insertion, provider URLs without join paths, replacement of pending reminders, lack of record-only action, inaccurate local-processing wording for active recordings, resetting explicit recording opt-out, and SwiftUI initializer order.
- An actual test host hung in MenuBarExtra with a TimelineView label. Replacing it with ordinary observable state from the existing polling loop allowed both targeted and full app runs to finish. This is automated startup evidence, not visual UI verification.
- Release/arm64 build succeeded. Packaged local copy has bundle ID `ua.com.rmarinsky.diduny.calendar-rc`, own display name and automatic update checks disabled. Production source updater behavior remains unchanged. Ad-hoc signature passed deep/strict verification; ZIP integrity passed. Candidate was not installed, launched, notarized or published.
- Embedded version remains repository default 1.14.4 (4); public release version is assigned by the normal release workflow, not manually here.

Archive SHA256: `bcd1dada235c3034f470124cbc1f8f122a1bfd69c80f8196259dde5f3ac257b2`.
Executable SHA256: `83058138d39c8a54e06592146d1c252d7ed4b8ef384cc3ccbd5c623eecbdc9c9`.

Local deliverables in the documentation workspace: `artifacts/calendar-rc/2026-10-16/` and `design-reference/2026-10-16-calendar-integration-rc/`. The source commit above excludes this report-only follow-up.

## Verification boundaries

The user explicitly requested continuing without desktop access while the Mac was locked. No new native screenshots or live EventKit permission/account reads were performed. Calendar source adapters, browser/profile routing, reminder layout/Escape/focus, default-app Join, real recording and local transcription must still be exercised on an unlocked Mac before production readiness. Prior standalone prototype evidence is retained with its original scope: Google/Chrome Roma and Outlook/Edge Work restoration, background reading, changed-tab pause/resume, native-menu profiles and persistent disconnect. It does not prove the integrated app or complete browser calendar synchronization. The latest Edge window-naming activation fix remains unverified live.

Events remain in memory; selected IDs, consent and reminder occurrence keys persist locally. A recorded meeting's title/time/link is stored with its local recording. The app does not write calendar events. Provider synchronization latency and calendar/browser permission revocation remain external conditions; errors disable stale scheduling/actions. Calendar browser access does not extract credentials or bypass account policy.

No PR, CI run, merge, tag, appcast update or public release was created.

## PR #76 integration follow-up (2026-10-16)

The existing draft PR now combines this calendar work with staged Pro purchase review,
one-time annual access, mandatory email-code sign-in, optional analytics consent, and
Ukrainian/English app localization. It preserves the original calendar occurrence metadata,
calendar sources and resource declarations. Updated release copy covers the combined scope.

Independent integration reviews identified and resolved two auth transitions: calendar
Join+Record now keeps Account visible for a signed-out user, and meeting startup rejection
clears only the pending state for its own pipeline generation. The existing cancellation
fixtures explicitly provide their signed-in precondition. Calendar browser error/status
messages now follow the app language; AX matching strings and persisted identifiers remain
unchanged. New failing tests and the full integrated validation are recorded in the PR.

No new native visual evidence was captured. The earlier candidate archive, signatures,
checksums and manual verification limits above belong to their stated source revision;
they do not describe a rebuilt combined candidate. Backend and website changes remain in
separate repositories. Publishing this draft PR does not deploy them or release the app.
