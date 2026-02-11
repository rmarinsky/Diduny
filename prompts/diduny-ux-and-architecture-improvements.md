# Task: Diduny UX & Architecture Improvements

## Context

Diduny is a macOS menu bar voice dictation app (Swift/SwiftUI, macOS 14+).
This prompt covers architecture fixes, code quality improvements, and new user flows
identified during a comprehensive codebase audit.

Prioritized into 3 phases: Phase 1 (high-priority fixes), Phase 2 (UX features), Phase 3 (advanced flows).

---

## Phase 1: Architecture & Code Quality Fixes

### 1.1 Unify Duplicated Recording State Enums

**Problem:** `RecordingState`, `MeetingRecordingState`, `TranslationRecordingState` in
`AppState.swift` are 3 identical 5-case enums (idle/recording/processing/success/error).
There's even a conversion extension proving they're interchangeable.

**Files:**
- `Diduny/App/AppState.swift`

**Action:**
- Delete `MeetingRecordingState` and `TranslationRecordingState` enums
- Use `RecordingState` for all three state properties
- Remove the `RecordingState.init(from:)` conversion extension
- Update all references in `AppDelegate+MeetingRecording.swift`, `AppDelegate+TranslationRecording.swift`,
  `MenuBarContentView.swift`, `MenuBarIconView.swift`, and any other consumers

**Result:** ~60 lines removed, single source of truth for recording states.

### 1.2 Migrate NotchManager and AudioDeviceManager to @Observable

**Problem:** `AppState` uses `@Observable` (modern), but `NotchManager` uses
`ObservableObject`/`@Published` and `AudioDeviceManager` uses `ObservableObject`.
This forces views to mix `@Environment(AppState.self)` with `@ObservedObject`.

**Files:**
- `Diduny/Features/Notch/NotchManager.swift` — change `ObservableObject` to `@Observable`, remove `@Published`
- `Diduny/Core/Services/AudioDeviceManager.swift` — same migration
- `Diduny/Features/Notch/NotchContentView.swift` — change `@ObservedObject` to `@Environment` or `@Bindable`
- `Diduny/Features/MenuBar/MenuBarContentView.swift` — change `@ObservedObject var audioDeviceManager` to `@Environment`
- `Diduny/App/DidunyApp.swift` — propagate via `.environment()`

**Migration pattern:**
```swift
// Before
@MainActor
final class NotchManager: ObservableObject {
    @Published private(set) var state: NotchState = .idle
}

// After
@Observable
@MainActor
final class NotchManager {
    private(set) var state: NotchState = .idle
}
```

**Caution:** `DynamicNotchKit` may rely on `ObservableObject` conformance. Check its generic
constraints before migrating `NotchManager`. If it requires `ObservableObject`, keep it and
only migrate `AudioDeviceManager`.

### 1.3 Deduplicate State Change Handlers

**Problem:** `handleRecordingStateChange`, `handleMeetingStateChange`, `handleTranslationStateChange`
in `AppDelegate.swift:226-310` are near-identical (~30 lines each). Only the `RecordingMode`
and auto-dismiss timing differ.

**Files:**
- `Diduny/App/AppDelegate.swift`

**Action:** Replace all three with a single method:
```swift
func handleStateChange(_ state: RecordingState, mode: RecordingMode, dismissDelay: TimeInterval = 1.5) {
    switch state {
    case .recording:
        NotchManager.shared.startRecording(mode: mode)
    case .processing:
        NotchManager.shared.startProcessing(mode: mode)
    case .success:
        if let text = appState.lastTranscription {
            NotchManager.shared.showSuccess(text: text)
        }
        Task {
            try? await Task.sleep(for: .seconds(dismissDelay))
            // Reset to idle based on mode
        }
    case .error:
        NotchManager.shared.showError(message: appState.errorMessage ?? "Error")
        Task {
            try? await Task.sleep(for: .seconds(2))
            // Reset to idle based on mode
        }
    case .idle:
        break
    }
}
```

Update callers in `AppDelegate+Recording.swift`, `AppDelegate+MeetingRecording.swift`,
`AppDelegate+TranslationRecording.swift` to pass the mode.

### 1.4 Replace DispatchQueue.main.asyncAfter with Task.sleep in SwiftUI Views

**Problem:** Multiple SwiftUI views use GCD (`DispatchQueue.main.asyncAfter`) despite being
in a `@MainActor` context. This is legacy pattern mixing.

**Files and lines to fix:**
- `MenuBarContentView.swift:73` — `DispatchQueue.main.asyncAfter(deadline: .now() + 0.1)`
- `MenuBarContentView.swift:84` — same
- `SettingsView.swift:43` — same
- `OnboardingContainerView.swift:334, 353, 367, 548, 560` — `DispatchQueue.main.asyncAfter`

**Replace with:**
```swift
// Before
DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
    NSApp.activate(ignoringOtherApps: true)
}

// After
Task { @MainActor in
    try? await Task.sleep(for: .milliseconds(100))
    NSApp.activate(ignoringOtherApps: true)
}
```

### 1.5 Fix Menu Bar Button Titles

**Problem:** Inconsistent tone and a typo in `MenuBarContentView.swift`.

**Current → Fixed:**
| Current | Fixed |
|---------|-------|
| `"Transcribe me"` | `"Start Dictation"` |
| `"Stop listening"` | `"Stop Dictation"` |
| `"Processing?"` | `"Processing..."` |
| `"Transcribed!"` | `"Transcribed"` |
| `"Error :/"` | `"Transcription Error"` |
| `"Translate me"` | `"Start Translation"` |
| `"Stop listening"` | `"Stop Translation"` |
| `"Processing?"` | `"Translating..."` |
| `"Translated!"` | `"Translated"` |
| `"Error :/"` | `"Translation Error"` |
| `"Record Meeting"` | `"Record Meeting"` (keep) |
| `"Stop Meeting Recording"` | `"Stop Meeting"` |
| `"Processing Meeting?"` | `"Processing Meeting..."` |
| `"Meeting Welldone!"` | `"Meeting Recorded"` |
| `"Meeting Error :/"` | `"Meeting Error"` |

---

## Phase 2: UX Improvements

### 2.1 Add Recording Duration to Notch Compact View

**Problem:** Users can't see how long they've been recording. The `recordingDuration`
computed property exists in `AppState` but is never shown in the notch.

**Files:**
- `Diduny/Features/Notch/NotchContentView.swift` — `NotchCompactTrailingView`
- `Diduny/App/AppState.swift` — expose `recordingStartTime` per mode

**Action:**
- In `NotchCompactTrailingView`, when state is `.recording`, show a live timer next to the pulsing dot
- Use `TimelineView(.periodic(from: .now, by: 1))` for SwiftUI-native timer updates
- Format as "0:05", "1:23", "12:05" (mm:ss, no leading zero on minutes)

```swift
// In NotchCompactTrailingView, replace PulsingDotView() with:
case .recording:
    HStack(spacing: 4) {
        PulsingDotView()
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(formatDuration(from: recordingStartTime, at: context.date))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.red)
        }
    }
```

**Requires:** Passing `recordingStartTime` (or the relevant per-mode start time) to the notch view.
`NotchManager` needs to store the start time when `startRecording(mode:)` is called.

### 2.2 Show Audio Level During Recording

**Problem:** `AudioRecorderProtocol` exposes `audioLevel: Float` but nothing displays it.
Users can't confirm the mic is picking up sound.

**Files:**
- `Diduny/Features/Notch/NotchContentView.swift` — `RecordingCompactView` or `RecordingExpandedView`
- `Diduny/Core/Services/AudioRecorderService.swift` — already publishes audio level

**Action:**
- Add a small 3-bar audio level indicator next to the recording icon in the compact notch view
- Poll `audioRecorder.audioLevel` via a timer or publish it through `NotchManager`
- Bars: 3 vertical rectangles, heights proportional to level (0.0-1.0), colored red

### 2.3 Recent Transcriptions in Menu Bar

**Problem:** Accessing past transcriptions requires opening the full Recordings Library window.

**Files:**
- `Diduny/Features/MenuBar/MenuBarContentView.swift`
- `Diduny/Core/Storage/RecordingsLibraryStorage.swift`

**Action:**
- Add a "Recent" submenu between "Recordings" and "Settings" in the menu bar
- Show last 5 recordings: type icon + timestamp + first 40 chars of transcription
- Click copies text to clipboard
- Option-click opens in Recordings Library

```swift
// In MenuBarContentView body, after "Recordings" button:
Menu("Recent") {
    ForEach(storage.recordings.prefix(5)) { recording in
        Button {
            if let text = recording.transcriptionText {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        } label: {
            HStack {
                Image(systemName: recording.type.iconName)
                Text(recording.transcriptionText?.prefix(40) ?? "No transcription")
            }
        }
    }
}
```

### 2.4 Quick Review Before Auto-Paste

**Problem:** Text is auto-pasted immediately after transcription. Users can't review first.

**Files:**
- `Diduny/App/AppDelegate+Recording.swift` — `stopRecording()` method
- `Diduny/Features/Notch/NotchManager.swift` — new `showReview` state
- `Diduny/Features/Notch/NotchContentView.swift` — new review expanded view
- `Diduny/Core/Storage/SettingsStorage.swift` — new `reviewBeforePaste` setting

**Action:**
1. Add new `SettingsStorage` boolean: `reviewBeforePaste` (default: false)
2. Add new `NotchState` case: `.review(text: String, countdown: Int)`
3. When `reviewBeforePaste` is enabled:
   - After transcription success, show expanded notch with full text + "Paste" button + countdown (3s)
   - Countdown ticks 3...2...1 then auto-pastes (if auto-paste enabled)
   - User can click "Paste" to paste immediately
   - User can press ESC to cancel paste (text stays in clipboard)
4. When disabled: current behavior (immediate paste)
5. Add toggle in General Settings: "Review before pasting"

### 2.5 Contextual Language Indicator

**Problem:** Translation direction (UK<->EN) is hardcoded and invisible to users.

**Files:**
- `Diduny/Features/Notch/NotchContentView.swift`
- `Diduny/Core/Models/RecordingMode.swift` (or wherever mode labels live)
- `Diduny/Features/Settings/GeneralSettingsView.swift`

**Action:**
- In the notch compact view during translation recording, show "UK -> EN" label
- In Settings > General, add language pair picker (source + target)
- Store in `SettingsStorage`: `sourceLanguage`, `targetLanguage` (ISO 639-1 codes)
- Pass language codes to `SonioxTranscriptionService.translateAndTranscribe()`
- Update `RecordingMode.translation` label to include languages: "Recording (UK -> EN)..."

---

## Phase 3: Advanced User Flows

### 3.1 Dictation Modes

**Concept:** Different transcription behaviors for different contexts.

**Modes:**
| Mode | Soniox Context Prompt | Use Case |
|------|----------------------|----------|
| Notes | Raw transcription, minimal formatting | Quick notes |
| Email | Add punctuation, capitalization, paragraphs | Professional writing |
| List | Convert pauses to bullet points | Todo lists, agendas |
| Code | Preserve technical terms, camelCase | Developer dictation |

**Files:**
- New: `Diduny/Core/Models/DictationMode.swift`
- `Diduny/Core/Storage/SettingsStorage.swift` — persist selected mode
- `Diduny/Core/Services/SonioxTranscriptionService.swift` — vary context per mode
- `Diduny/Features/MenuBar/MenuBarContentView.swift` — mode picker submenu
- `Diduny/Features/Settings/GeneralSettingsView.swift` — mode configuration

**Implementation:**
- `DictationMode` enum with `.notes`, `.email`, `.list`, `.code` cases
- Each mode provides a `sonioxContext: String` computed property with the appropriate prompt
- Menu bar: submenu to switch modes, show active mode icon on menu bar
- Keyboard shortcut: Cmd+Opt+1/2/3/4 to switch modes

### 3.2 Meeting Chapter Bookmarks

**Concept:** Users can mark chapters during meeting recording for easier navigation.

**Files:**
- `Diduny/Core/Models/LiveTranscriptStore.swift` — add `chapters: [Chapter]`
- `Diduny/Features/Transcription/LiveTranscriptView.swift` — render chapter markers
- `Diduny/App/AppDelegate+MeetingRecording.swift` — hotkey handler for adding chapters
- `Diduny/Core/Models/Recording.swift` — persist chapters in metadata

**Implementation:**
- During meeting recording, Cmd+Opt+B adds a chapter marker at current timestamp
- Chapter stored as `Chapter(timestamp: TimeInterval, label: String?)`
- LiveTranscriptView renders chapter dividers between segments
- After recording, chapters appear in RecordingDetailView as clickable timestamps
- Auto-chapters: detect silence gaps >5s and suggest chapter breaks

### 3.3 Transcription History Palette

**Concept:** A floating, searchable palette (like Spotlight/Raycast) for past transcriptions.

**Files:**
- New: `Diduny/Features/HistoryPalette/HistoryPaletteView.swift`
- New: `Diduny/Features/HistoryPalette/HistoryPaletteWindowController.swift`
- `Diduny/App/AppDelegate+Hotkeys.swift` — register Cmd+Opt+H hotkey
- `Diduny/Core/Storage/RecordingsLibraryStorage.swift` — search method

**Implementation:**
- Floating panel (NSPanel, level: .floating) with search field
- Shows last 20 transcriptions, filterable by text search
- Each row: type icon + date + preview (60 chars)
- Enter key copies selected item to clipboard
- Cmd+Enter pastes immediately
- ESC dismisses
- Opens via Cmd+Opt+H global hotkey

### 3.4 Ambient Listening / Wake Word

**Concept:** Always-listening mode with wake word activation.

**Files:**
- New: `Diduny/Core/Services/WakeWordService.swift`
- `Diduny/Core/Storage/SettingsStorage.swift` — ambient mode settings
- `Diduny/Features/MenuBar/MenuBarIconView.swift` — ambient mode indicator

**Implementation:**
- Uses local Whisper (tiny model) in continuous listening mode
- Detects wake phrase (configurable, default: "Hey Diduny")
- On wake word: starts recording, detects end of speech (2s silence), auto-transcribes
- Menu bar icon shows subtle ear symbol when ambient mode is active
- Toggle via menu bar or Settings > General
- Privacy: all wake word detection is local (no cloud)

---

## Implementation Order

| Step | Task | Scope | Depends On |
|------|------|-------|------------|
| 1 | Unify state enums (1.1) | Small refactor | - |
| 2 | Fix menu bar titles (1.5) | Trivial | - |
| 3 | Deduplicate state handlers (1.3) | Small refactor | Step 1 |
| 4 | Replace DispatchQueue.main.asyncAfter (1.4) | Small refactor | - |
| 5 | Migrate to @Observable (1.2) | Medium refactor | - |
| 6 | Add recording duration to notch (2.1) | Small feature | - |
| 7 | Show audio level (2.2) | Small feature | - |
| 8 | Recent transcriptions menu (2.3) | Small feature | - |
| 9 | Quick review before paste (2.4) | Medium feature | - |
| 10 | Language indicator (2.5) | Medium feature | - |
| 11 | Dictation modes (3.1) | Large feature | - |
| 12 | Meeting chapters (3.2) | Large feature | - |
| 13 | History palette (3.3) | Large feature | Step 8 |
| 14 | Ambient listening (3.4) | Large feature | - |

## Verification

After each phase:
1. Run `./scripts/build_and_install.sh` to build and install
2. Test all 3 recording flows (voice, translation, meeting)
3. Verify notch displays correctly for all states
4. Open Settings and verify all tabs render
5. Open Recordings Library and verify list/detail/playback
6. Test push-to-talk with each key option
7. Test double-ESC cancellation
8. Test device switching (plug/unplug external mic)