# CLAUDE.md - Project Context for Claude

## Project Overview

**Diduny** is a native macOS menu bar application for voice dictation. It records audio, transcribes it using the Soniox API, and pastes the result.

- **Platform:** macOS 14.0+ (Sonoma)
- **Language:** Swift / SwiftUI
- **App Type:** Menu bar app (LSUIElement = YES, no dock icon)
- **Transcription Service:** Soniox only (async STT API)

## Key Architecture

### Entry Point & Orchestration
- `DidunyApp.swift` - SwiftUI app entry point
- `AppDelegate.swift` - Main orchestrator: menu bar, hotkey handling, recording flow
- `AppState.swift` - Shared observable state (recordingState, selectedDevice, etc.)

### Recording Flow
1. User triggers via:
   - Hotkey (⌘⌥D)
   - Left-click menu bar icon
   - Push-to-talk key (Right Option by default)
2. `AppDelegate.toggleRecording()` → `startRecording()` or `stopRecording()`
3. `AudioRecorderService` captures audio to WAV
4. `SonioxTranscriptionService.transcribe()` sends to API
5. `ClipboardService` copies result and optionally pastes

### Push-to-Talk Mode
- Hold key to record, release to stop and transcribe
- Options: Caps Lock (keyCode 57), Right Shift (60), Right Option (61)
- Default: Right Option
- Uses `NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged)`

### Meeting Recording (macOS 13.0+)
- Records system audio for meetings (Zoom, Meet, Teams, etc.)
- Uses ScreenCaptureKit for system audio capture
- Supports long recordings (1+ hour)
- Trigger: ⌘⌥M or Menu → Record Meeting
- Audio sources: System Only or System + Microphone
- Requires Screen Recording permission

### Services (Diduny/Core/Services/)
| Service | Purpose |
|---------|---------|
| `AudioDeviceManager` | Lists input devices, auto-detects best microphone |
| `AudioRecorderService` | Records audio using AVAudioEngine |
| `SonioxTranscriptionService` | 4-step async transcription: upload → create job → poll → get text |
| `WhisperTranscriptionService` | Local on-device transcription using whisper.cpp |
| `ClipboardService` | Copy to clipboard, simulate Cmd+V paste |
| `HotkeyService` | Global hotkey registration using Carbon |
| `PushToTalkService` | Monitor modifier keys (Caps Lock/Right Shift/Right Option) for push-to-talk |
| `SystemAudioCaptureService` | Capture system audio using ScreenCaptureKit (macOS 13+) |
| `MeetingRecorderService` | Orchestrate meeting recording with system audio capture |

### Whisper Local Transcription (Diduny/Core/Whisper/)
| Component | Purpose |
|-----------|---------|
| `WhisperBridge.h` | Bridging header importing whisper.h C API |
| `WhisperContext.swift` | Swift actor wrapping whisper.cpp C API (Metal GPU, greedy sampling) |
| `AudioConverter.swift` | Converts recorded WAV to 16kHz mono Float32 for Whisper |
| `WhisperModelManager.swift` | Model catalog (12 models), download/delete/select, progress tracking |

### Transcription Provider Routing
- `TranscriptionProvider` enum: `.soniox` (default) or `.whisperLocal`
- `AppDelegate.activeTranscriptionService` routes to the correct service
- Provider-specific validation at recording start (API key vs downloaded model)
- Meeting recording always uses Soniox (real-time WebSocket)
- Translation with Whisper falls back to plain transcription (Whisper only translates TO English)

### Soniox API Integration
- **Base URL:** `https://api.soniox.com/v1`
- **Model:** `stt-async-preview`
- **Flow:** POST /files → POST /transcriptions → GET /transcriptions/{id} (poll) → GET /transcriptions/{id}/transcript
- **Auth:** Bearer token in Authorization header

### Storage (Diduny/Core/Storage/)
- `KeychainManager` - Stores Soniox API key securely
- `SettingsStorage` - UserDefaults for preferences (audio quality, hotkey, auto-paste, etc.)

### UI (Diduny/Features/)
- `SettingsView` - TabView with General, Audio, Meetings, API tabs
- `APISettingsView` - Soniox API key input with test connection button
- `MeetingSettingsView` - Meeting audio source selection
- `RecordingIndicatorView` - Floating pill showing recording/processing status

## State Machine
```
RecordingState: idle → recording → processing → success/error → idle
MeetingRecordingState: idle → recording → processing → success/error → idle
```

## Key Files to Edit

| Task | Files |
|------|-------|
| Change transcription logic | `SonioxTranscriptionService.swift`, `WhisperTranscriptionService.swift` |
| Modify recording behavior | `AudioRecorderService.swift`, `AppDelegate.swift` |
| Add settings | `SettingsStorage.swift`, relevant settings view |
| Change hotkey | `HotkeyService.swift`, `GeneralSettingsView.swift` |
| Modify menu bar | `AppDelegate.setupMenu()` |
| Add whisper models | `WhisperModelManager.swift` (availableModels catalog) |
| Change transcription provider UI | `TranscriptionSettingsView.swift` |

## Default Shortcuts
- **Transcribe:** ⌘⌥D (Cmd+Opt+D)
- **Translate:** ⌘⌥/ (Cmd+Opt+/)
- **Meeting:** ⌘⌥M (Cmd+Opt+M)
- **Push-to-Talk (Transcribe):** Right Option key

## Build Configurations

The project has three build configurations with different app names and bundle IDs:

| Config | Scheme | App Name | Bundle ID | Purpose |
|--------|--------|----------|-----------|---------|
| Debug | Diduny DEV | Diduny DEV | ua.com.rmarinsky.diduny.dev | Local development |
| Test | Diduny TEST | Diduny TEST | ua.com.rmarinsky.diduny.test | Testing/QA distribution |
| Release | Diduny | Diduny | ua.com.rmarinsky.diduny | Production release |

### Development Build (Xcode)
```bash
# Generate project first
./generate_project.sh
open Diduny.xcodeproj

# In Xcode: Select "Diduny DEV" scheme → Run
# This installs "Diduny DEV.app" with dev bundle ID
```

### Development Build (Script)
```bash
# Build and install "Diduny DEV" to /Applications
./build_and_install.sh
```

### Test/QA Build
```bash
# Build "Diduny TEST" for distribution testing
./release.sh --test --skip-notarize

# Or with notarization
./release.sh --test
```

### Production Build
```bash
# Build "Diduny" for production release
./release.sh --skip-notarize

# Or with notarization
./release.sh
```

## Required Permissions
- Microphone (NSMicrophoneUsageDescription)
- Screen Recording (for meeting audio capture via ScreenCaptureKit)
- Accessibility (for auto-paste Cmd+V simulation)
- Keychain (for API key storage)
- Network (for Soniox API)

## Logging
App uses `NSLog()` with prefixes:
- `[Diduny]` - AppDelegate flow
- `[Transcription]` - Soniox API calls
- `[AppState]` - State changes

## Common Issues
- AudioHardware warnings (ID 98) - Harmless CoreAudio cleanup messages
- FBSWorkspaceScenesClient errors - macOS Control Center internal errors, not from this app
