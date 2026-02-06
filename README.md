<p align="center">
  <img src="icons/transparent/App Store.png" width="128" height="128" alt="Diduny Icon">
</p>

<h1 align="center">Diduny</h1>

<p align="center">
  A native macOS menu bar app for voice dictation. Record your voice, get it transcribed via Soniox API, and automatically paste the text.
</p>

## Features

- **Voice Dictation** - Press hotkey, speak, release, text appears
- **Menu Bar App** - Lives in your menu bar, no dock icon
- **Global Hotkey** - Default: `Cmd+Opt+D`
- **Push-to-Talk** - Hold Caps Lock, Right Shift, or Right Option
- **Meeting Recording** - Capture system audio from Zoom, Meet, etc. (`Cmd+Opt+M`)
- **Auto-Paste** - Transcribed text automatically pastes to active app
- **Secure Storage** - API keys stored in macOS Keychain

## Requirements

- macOS 14.0+ (Sonoma)
- Xcode 15.0+
- [Homebrew](https://brew.sh) (for XcodeGen)
- [Soniox API key](https://console.soniox.com)

## Build & Install

### 1. Clone the Repository

```bash
git clone https://github.com/YOUR_USERNAME/Diduny.git
cd Diduny
```

### 2. Generate Xcode Project

```bash
./generate_project.sh
```

This installs XcodeGen (if needed) and generates `Diduny.xcodeproj`.

### 3. Open in Xcode

```bash
open Diduny.xcodeproj
```

### 4. Configure Signing

1. In Xcode, select the **Diduny** target
2. Go to **Signing & Capabilities**
3. Select your **Team** (or personal Apple ID)
4. Xcode will automatically manage signing

### 5. Build the App

**Option A: Build in Xcode**
- Press `Cmd+B` to build
- Or `Cmd+R` to build and run

**Option B: Build from Terminal**
```bash
xcodebuild -scheme Diduny -configuration Release build SYMROOT=./build
```

### 6. Install to Applications

After building, copy the app to your Applications folder:

**From Xcode build:**
```bash
cp -r ~/Library/Developer/Xcode/DerivedData/Diduny-*/Build/Products/Release/Diduny.app /Applications/
```

**From terminal build:**
```bash
cp -r ./build/Release/Diduny.app /Applications/
```

Or manually:
1. In Xcode: **Product** → **Show Build Folder in Finder**
2. Navigate to `Products/Release/`
3. Drag `Diduny.app` to `/Applications`

## First Launch Setup

### 1. Launch the App

```bash
open /Applications/Diduny.app
```

Or double-click in Finder. The app icon appears in your menu bar.

### 2. Grant Permissions

The app will request these permissions:

| Permission | Why Needed | How to Grant |
|------------|-----------|--------------|
| **Microphone** | Record your voice | Click "Allow" when prompted |
| **Accessibility** | Auto-paste text (Cmd+V simulation) | System Settings → Privacy & Security → Accessibility → Enable Diduny |
| **Screen Recording** | Meeting recording (system audio) | System Settings → Privacy & Security → Screen Recording → Enable Diduny |

### 3. Add Soniox API Key

1. Click the menu bar icon
2. Select **Settings**
3. Go to **API** tab
4. Enter your [Soniox API key](https://console.soniox.com)
5. Click **Test Connection** to verify

## Usage

### Voice Dictation

| Action | Method |
|--------|--------|
| Start/Stop Recording | Click menu bar icon |
| Start/Stop Recording | Press `Cmd+Opt+D` |
| Push-to-Talk | Hold `Caps Lock`, `Right Shift`, or `Right Option` |

1. Activate recording
2. Speak clearly
3. Stop recording
4. Text is transcribed and pasted automatically

### Meeting Recording

| Action | Method |
|--------|--------|
| Start/Stop Meeting Recording | Press `Cmd+Opt+M` |
| Start/Stop Meeting Recording | Menu → Record Meeting |

Records system audio (Zoom, Google Meet, Teams, etc.) and transcribes when stopped.

### Settings

Access via menu bar icon → **Settings**:

- **General** - Hotkey, push-to-talk key, auto-paste toggle
- **Audio** - Microphone selection, audio quality
- **Meetings** - Audio source (system only / system + mic)
- **API** - Soniox API key

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

### "API key invalid" error
- Verify your key at [console.soniox.com](https://console.soniox.com)
- Re-enter the key in Settings → API

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
