<p align="center">
  <a href="https://stand-with-ukraine.pp.ua">
    <img src="https://raw.githubusercontent.com/vshymanskyy/StandWithUkraine/main/banner-direct-single.svg" alt="Stand With Ukraine">
  </a>
</p>

<p align="center">
  <img src="icons/transparent/App Store.png" width="128" height="128" alt="Diduny Icon">
</p>

<h1 align="center">Diduny</h1>

<p align="center">
  <a href="https://stand-with-ukraine.pp.ua"><img src="https://img.shields.io/badge/made_in-ukraine-ffd700.svg?labelColor=0057b7" alt="Made in Ukraine"></a>
</p>

<p align="center">
  A native macOS menu bar app for voice dictation. Record your voice, get it transcribed, and automatically paste the text.
</p>

## Features

- **Voice Dictation** — Press hotkey, speak, release, text appears
- **Menu Bar App** — Lives in your menu bar, no dock icon
- **Global Hotkey** — Default: `Cmd+Opt+D`
- **Push-to-Talk** — Hold Right Shift, Right Option, or Caps Lock
- **Meeting Recording** — Capture system audio from Zoom, Meet, etc. (`Cmd+Opt+M`)
- **Text Translation** — Translate selected text between languages (`Cmd+Opt+/`)
- **Real-time Transcription** — Live streaming transcription via WebSocket
- **Local Whisper** — On-device transcription with whisper.cpp (Metal GPU)
- **Auto-Paste** — Transcribed text automatically pastes to active app

## Requirements

- macOS 14.0+ (Sonoma)

### Build from Source

- Xcode 15.0+
- [Homebrew](https://brew.sh) (for XcodeGen)

## Build & Install

### 1. Clone the Repository

```bash
git clone https://github.com/rmarinsky/Diduny.git
cd Diduny
```

### 2. Generate Xcode Project

```bash
./generate_project.sh
```

This installs XcodeGen (if needed) and generates `Diduny.xcodeproj`.

### 3. Build & Install

**Option A: Dev install script**
```bash
./scripts/dev_install.sh
```

**Option B: Open in Xcode**
```bash
open Diduny.xcodeproj
```
Select the **Diduny DEV** scheme and press `Cmd+R`.

## First Launch Setup

### 1. Grant Permissions

The app will request these permissions:

| Permission | Why Needed | How to Grant |
|------------|-----------|--------------|
| **Microphone** | Record your voice | Click "Allow" when prompted |
| **Accessibility** | Auto-paste text (Cmd+V simulation) | System Settings → Privacy & Security → Accessibility → Enable Diduny |
| **Screen Recording** | Meeting recording (system audio) | System Settings → Privacy & Security → Screen Recording → Enable Diduny |

### 2. Sign In

1. Click the menu bar icon → **Settings** → **Account**
2. Enter your email and sign in with the OTP code
3. The app connects to the proxy server for cloud transcription

## Usage

### Voice Dictation

| Action | Method |
|--------|--------|
| Start/Stop Recording | Click menu bar icon |
| Start/Stop Recording | Press `Cmd+Opt+D` |
| Push-to-Talk | Hold `Right Shift` or `Right Option` |

### Translation

| Action | Method |
|--------|--------|
| Translate selected text | Double-press `Cmd+C` |
| Open translation window | Press `Cmd+Opt+/` |

### Meeting Recording

| Action | Method |
|--------|--------|
| Start/Stop Meeting Recording | Press `Cmd+Opt+M` |

Records system audio (Zoom, Google Meet, Teams, etc.) and transcribes when stopped.

### Settings

Access via menu bar icon → **Settings**:

- **General** — Launch at login, menu bar icon style
- **Shortcuts** — Global hotkeys, recording mode, push-to-talk keys
- **Audio** — Microphone selection, audio quality
- **Dictation** — Transcription provider (cloud/local), language, Whisper models
- **Translation** — Favorite languages
- **Meetings** — Audio source (system only / system + mic)
- **Account** — Sign in, proxy server configuration, usage stats

## Troubleshooting

### App doesn't appear in menu bar
- Check if app is running: `ps aux | grep Diduny`
- Try relaunching the app

### Microphone not working
- System Settings → Privacy & Security → Microphone → Ensure Diduny is enabled
- Try selecting a different audio device in Settings → Audio

### Auto-paste not working
- System Settings → Privacy & Security → Accessibility → Enable Diduny
- Restart the app after granting permission

### Meeting recording not capturing audio
- System Settings → Privacy & Security → Screen Recording → Enable Diduny
- Restart the app after granting permission

## Uninstall

```bash
# Remove app
rm -rf /Applications/Diduny.app

# Remove preferences (optional)
defaults delete ua.com.rmarinsky.diduny

# Remove keychain items (optional)
security delete-generic-password -s "ua.com.rmarinsky.diduny" 2>/dev/null
```

## License

MIT
