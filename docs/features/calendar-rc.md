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

## Calendar permission correction · 2026-10-19

A user screenshot reported denied calendar access. Inspection found the calendar entitlement missing from both `project.yml` and `Diduny.entitlements` while Hardened Runtime was enabled. The old local candidate must not be treated as calendar-ready: signature validity did not prove required entitlement coverage. The fix adds `com.apple.security.personal-information.calendars` to both inputs, with a CI packaging contract that failed before the fix and passes after project regeneration. A newly built signed TEST app was inspected with `codesign` and contains the key. The system permission itself was not changed or verified.

The error UI now links directly to Calendar Permissions and explains reconnecting after changing access. The user's exact running build and TCC authorization state are unknown, so this confirms a packaging defect without claiming it was the only cause of the reported denial. No installed app was replaced. Native permission grant/retry and the settings deep link still need live verification.

Correction validation: 3 packaging contract tests passed after `xcodegen generate`; 10 targeted CalendarConnection/CalendarMeeting app tests passed with the existing unsigned test-host setup; 3 release-highlights tests and plist/diff checks passed. Two independent source reviews found no blockers. No real calendar permission grant or account read is claimed.

## Calendar selection and account grouping (2026-10-19)

Calendar settings groups calendars by EventKit source identifier, with compact checkboxes and selected counts. Other calendars remain available in a collapsed disclosure. First connection selects editable, non-subscribed, non-birthday calendars; recognized exact English/Ukrainian birthday/holiday names are also excluded because Exchange exposes some as editable ordinary calendars. Existing saved selections, including explicit opt-in to these calendars, are preserved. Initial EventKit event queries use this same selection before reading event details.

This is a suggested selection, not provider-primary discovery. EventKit does not expose a primary calendar for every account. Custom or other-language service names may need manual deselection; shared read-only meeting calendars require manual opt-in. No provider registration or account changes are introduced.

Validation: initial-selection test failed before filtering; exact-name Exchange test failed six cases before correction. Final CalendarConnection/CalendarMeeting tests: 12 passed, 0 failed. Calendar entitlement packaging: 3 passed. Two independent source reviews completed; initial-query minimization and Ukrainian wording findings resolved. Signed DEV build installed and verified: account groups, collapsed/expanded Exchange service calendars, preserved selection and event read after restart. Fresh first-connect defaults are covered by tests, not a destructive reset of the user's connection.

## Teams links adjacent to Outlook Safe Links (2026-10-19)

The shared calendar URL extractor now trims a known adjacent Outlook Safe Links suffix from a supported direct meeting URL. Literal, HTML-escaped and URL-encoded angle boundaries are covered. It does not decode meeting query parameters or unwrap Safe Links redirects. The HTTPS/provider allowlist still applies before and after trimming.

Regression evidence: original parser failed all three delimiter cases; an intermediate broad delimiter split failed encoded-context preservation and wrapper rejection. Final targeted suite: 13 passed, 0 failed. Two independent code reviews completed; their query-preservation findings were fixed. Signed DEV build installed with executable SHA-256 `34218a4877ddb5d5f46b1d0d02aa61b3399d24920c01d56c6b15bb2d24af780e`. Live Join navigation is not exercised.

## Calendar and audio settings redesign (2026-10-19)

Calendar & Meetings now contains a compact connection summary, reminders, and a collapsed preview of at most three events. Meeting links use a short Join action with the full URL in its tooltip. Calendar selection lives in a separate sheet, with EventKit source type, calendar color, and editable/read-only/subscription/birthday metadata. Generic source titles are replaced by descriptive source-kind labels; no email or Google identity is inferred from CalDAV. Existing selections and first-connect suggestion rules are unchanged.

Audio & Dictation has Dictation and Meetings segments. Meeting provider, suggestions, audio source, gains and test capture retain their existing persisted settings. The calendar shortcut selects the Meetings segment. Duplicate feature/shortcut instructions were removed. Dictation playback state resets when leaving its segment.

Installed signed DEV build: compact calendar screen, ten calendar rows and their metadata, four preserved selections, background read after restart without consent, direct navigation to meeting audio, and return to Dictation verified through native UI. Local reference captures are stored outside Git and contain no event titles or join URLs; the calendar selection capture includes account/calendar names and must not be published raw. Join execution, reminder delivery, audio capture, VoiceOver, light mode and Ukrainian runtime layout were not exercised in this pass.

Source-label regression failed before implementation in an isolated actual-model harness. The playback cleanup regression similarly failed before the fix and passed after it. Two independent source reviews completed; lifecycle, stable group ordering, localization and accessible action label findings were resolved. Final isolated TEST-host suite: 53 passed, 0 failed (6 calendar connection, 8 calendar meeting, 39 settings storage); 3 calendar entitlement checks passed. Signed DEV build and strict signature verification passed.

## Reminder presentation and Join ordering (2026-10-20)

The reminder panel now remains visible when another application is active. Both modes use a nonactivating panel and explicit foreground ordering; fullscreen uses the screen-saver window level, while the small reminder stays floating. Dismiss orders the window out without animation before closing it. Both Join and record-only actions dismiss before invoking browser/recording work.

A native TEST-host regression connects a synthetic due event through CalendarConnection into the real controller/NSPanel, then verifies dismissal inside the Join callback and no redelivery after refresh. It failed five assertions before the fix and passed afterward. Final calendar suites: 15 passed; entitlement checks: 3 passed; localization: 1087 matching keys. Two independent source reviews found no remaining blockers.

A same-source standalone synthetic UI check started and logged a visible panel, but the computer-control service timed out. Cross-app/fullscreen visibility, Escape and interactive Join latency remain unverified; the synthetic process was terminated. No real calendar event, browser navigation or audio capture was used. Existing ledger semantics remain: one reminder per occurrence at the configured lead time, and wake catch-up only within five minutes after start.
