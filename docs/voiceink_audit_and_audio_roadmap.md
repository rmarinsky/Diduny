# VoiceInk Audit + Diduny Audio Roadmap

## 1. Контекст, джерела, межі аналізу

### 1.1 Що саме проаналізовано
- VoiceInk source snapshot:
  - Repo: `https://github.com/Beingpax/VoiceInk`
  - Commit: `36427ebfa8d26db130816d4676463df3e3933e0e`
  - Commit date: `2026-02-10`
  - Локальна копія для аналізу: `/tmp/VoiceInk`
- Поточний стан Diduny:
  - Workspace: `/Users/rmarinskyi/IdeaProjects/personal/Diduny`
  - App code: `/Users/rmarinskyi/IdeaProjects/personal/Diduny/Diduny`

### 1.2 Межі
- Це статичний code-level аудит, без runtime бенчмарків VoiceInk.
- Висновки валідні для конкретного snapshot VoiceInk вище.
- Для Diduny roadmap зроблено з урахуванням поточної архітектури meeting capture (`SystemAudioCaptureService`, `AudioMixerService`, `MeetingRecorderService`).

### 1.3 Ключовий висновок в одному абзаці
VoiceInk добре вирішує local/cloud диктовку, стрімінг транскрипції і пост-обробку тексту, але не містить production-flow для meeting recording із міксом `system audio + mic` і не має AEC/echo suppression layer. Diduny, навпаки, вже має working meeting capture (включно з `systemPlusMicrophone`) і realtime hook, але поки без явного блоку echo cancellation. Тому roadmap нижче фокусується не на копіюванні VoiceInk, а на цілеспрямованому посиленні вже наявного pipeline Diduny.

---

## 2. Dependency inventory VoiceInk

## 2.1 Direct dependencies (підключені в target)

| Dependency | Де підключено | Для чого | Де реально використовується | Ризики |
|---|---|---|---|---|
| `whisper.xcframework` (локальний) | `VoiceInk.xcodeproj/project.pbxproj` | Local STT через `whisper.cpp` | `Whisper/LibWhisper.swift`, `WhisperState`, `LocalTranscriptionService` | Ручний lifecycle framework, залежність від зовнішнього build-скрипта, можливий ABI drift |
| `FluidAudio` | SPM package (direct) | Parakeet local models + on-device streaming ASR | `ParakeetTranscriptionService.swift`, `ParakeetStreamingProvider.swift`, `VoiceInk.swift` | Package pinned на `main` branch, ризик breaking змін без версії |
| `KeyboardShortcuts` | SPM package (direct) | Глобальні hotkeys, кастомний запис shortcut | `HotkeyManager.swift`, onboarding shortcuts | Поведінка hotkeys залежить від Accessibility і системних конфігів |
| `LaunchAtLogin-Modern` | SPM package (direct) | Запуск при login | `SettingsView.swift` | Pinned на `main` branch |
| `Sparkle` | SPM package (direct) | Auto-update механізм | `VoiceInk.swift` (`UpdaterViewModel`) | Update channel/security posture треба окремо hardenити |
| `mediaremote-adapter` | SPM package (direct) | Pause/resume media під час recording | `PlaybackController.swift` | Зовнішній API медіа контролю, нестабільність між macOS релізами |
| `Zip` | SPM package (direct) | Розпаковка CoreML zip для Whisper | `WhisperState+LocalModelManager.swift` | Обробка великих файлів, помилки unzip/corrupt artifacts |
| `SelectedTextKit` | SPM package (direct) | Витяг selected text для AI enhancement context | `SelectedTextService.swift` | Залежність від AX/API доступів |
| `swift-atomics` | SPM package (direct) | Thread-safe флаги в async download/unzip | `WhisperState+LocalModelManager.swift` | Низький ризик, але критично для race-free continuation handling |

## 2.2 Transitive dependencies (є в `Package.resolved`, але не direct у target)

| Dependency | Джерело | Навіщо з великою ймовірністю | Статус у коді app-level |
|---|---|---|---|
| `AXSwift` | transitive | Accessibility wrappers (ймовірно через SelectedTextKit) | Прямих `import AXSwift` у VoiceInk code немає |
| `KeySender` | transitive | Керування key events в accessibility flow | Прямих імпортів немає |
| `swift-collections` | transitive | Utility структури даних | Прямих імпортів немає |
| `swift-jinja` | transitive | Prompt/template tooling (ймовірно через HF stack) | Прямих імпортів немає |
| `swift-transformers` | transitive | ML helper stack (ймовірно разом із FluidAudio екосистемою) | Прямих імпортів немає |

## 2.3 Risk profile по залежностях
- Branch pinning:
  - `FluidAudio` -> `main`
  - `LaunchAtLogin-Modern` -> `main`
  - `mediaremote-adapter` -> `master`
- Це підвищує ризик неочікуваних змін при update lockfile.
- `whisper.xcframework` збирається зовнішнім процесом (`Makefile`/`BUILDING.md`), тому reproducibility критично залежить від точного toolchain.
- Security surface:
  - мережеві STT провайдери + API keys
  - Sparkle update channel
  - Apple Events/Accessibility маршрути

---

## 3. Функціональна карта VoiceInk по модулях

## 3.1 App shell і orchestration
- Основний контейнер: `VoiceInk/VoiceInk.swift`.
- Ключові state-об’єкти:
  - `WhisperState` (recording/transcription state machine)
  - `HotkeyManager`
  - `AIEnhancementService`
  - `MenuBarManager`
  - `UpdaterViewModel`

## 3.2 Онбордінг
- Вхідна умова: `@AppStorage("hasCompletedOnboarding")`.
- Екрани:
  - `OnboardingView` (welcome)
  - `OnboardingPermissionsView` (permissions + device + shortcut)
  - `OnboardingModelDownloadView` (download default local model)
  - `OnboardingTutorialView` (практичний тест)

## 3.3 Recording + transcription core
- Orchestration:
  - `WhisperState.toggleRecord()` запускає/зупиняє pipeline.
- Capture layer:
  - `Recorder` + `CoreAudioRecorder` (AUHAL).
- STT dispatch:
  - `TranscriptionServiceRegistry` -> local/parakeet/native/cloud.
- Session mode:
  - `FileTranscriptionSession` або `StreamingTranscriptionSession`.

## 3.4 AI enhancement/context
- `AIEnhancementService`:
  - optional screen OCR context
  - optional clipboard context
  - selected text context
  - prompt detection/switching

## 3.5 Privacy cleanup
- `TranscriptionAutoCleanupService`:
  - автоделіт транскриптів + orphan audio cleanup.
- `AudioCleanupManager`:
  - retention deletion старих аудіофайлів.

## 3.6 UX control/services
- `HotkeyManager`:
  - hold-to-record/hands-free режими.
- `MediaController`:
  - mute/unmute system audio.
- `PlaybackController`:
  - pause/resume media playback.

---

## 4. Як зроблено onboarding у VoiceInk

## 4.1 Flow
`welcome -> permissions -> model download -> tutorial -> main app`

## 4.2 Permission gates
- Microphone:
  - `AVCaptureDevice.requestAccess(for: .audio)`.
- Audio device selection:
  - через `AudioDeviceManager` (built-in/custom/prioritized modes).
- Accessibility:
  - `AXIsProcessTrustedWithOptions`.
- Screen Recording:
  - `CGRequestScreenCaptureAccess` + fallback open System Settings.
- Keyboard shortcut:
  - `KeyboardShortcuts.Recorder` і validation через `HotkeyManager`.

## 4.3 Важливий нюанс про Screen Recording
У VoiceInk Screen Recording permission використовується для OCR/contextual enhancement (`ScreenCaptureService.captureAndExtractText()`), а не для meeting audio loopback recording.

---

## 5. Як відбувається запис аудіо для транскрипції в VoiceInk

## 5.1 High-level sequence
1. Hotkey / UI trigger.
2. `WhisperState.toggleRecord()`:
   - створює WAV path в `Recordings`.
   - стартує `Recorder.startRecording`.
3. `Recorder`:
   - стартує `CoreAudioRecorder`.
   - одночасно може:
     - pause media (`PlaybackController`)
     - mute system output (`MediaController`)
4. `CoreAudioRecorder`:
   - AUHAL input capture з конкретного input device.
   - конвертує в `16kHz mono PCM Int16`.
   - пише в WAV.
   - паралельно може емітити ті самі PCM чанки через `onAudioChunk`.
5. Stop recording:
   - `WhisperState` створює `Transcription` entity (pending).
   - викликає `transcribeAudio(on:)`.
6. STT:
   - або streaming session finalize
   - або batch/file transcription.
7. Post-processing:
   - `TranscriptionOutputFilter`
   - optional text formatting
   - dictionary replacements
   - optional AI enhancement
8. Output:
   - save SwiftData
   - paste через `CursorPaster` (з optional clipboard restore / auto-enter).

## 5.2 Streaming/fallback поведінка
- Streaming підтримується лише для конкретних provider+model комбінацій.
- Якщо realtime connect/finalize падає, `StreamingTranscriptionSession` автоматично fallback-иться у file-based transcription для того ж model/provider.

## 5.3 Live partial text
- Під час recording partial transcript приходить через callback `onPartialTranscript` у `TranscriptionSession`.
- `WhisperState.partialTranscript` оновлює recorder UI (особливо notch mode).

---

## 6. Прямі відповіді на питання про meeting/system audio в VoiceInk

## 6.1 Чи є в VoiceInk запис мітингів як окремий режим?
Ні. У snapshot немає окремого meeting recorder pipeline як у Diduny.

## 6.2 Чи є в VoiceInk `system audio + microphone` mix recording?
Ні. Є input-device recording через AUHAL (`CoreAudioRecorder`), але немає шляху захоплення loopback/system output + окремого mic mix у meeting semantics.

## 6.3 Для чого VoiceInk використовує ScreenCaptureKit?
Для захоплення активного вікна і OCR контексту (`ScreenCaptureService`), який потім підмішується в AI enhancement prompt. Не для loopback audio recording.

## 6.4 Чи є в VoiceInk echo cancellation/noise suppression блок?
Ні. Немає AEC/NS DSP pipeline для meeting scenario.

## 6.5 Що таке “Audio Cleanup” у VoiceInk?
Retention deletion старих аудіофайлів і/або транскриптів. Це data lifecycle, не audio quality processing.

---

## 7. Gap-analysis: VoiceInk vs Diduny

| Capability | VoiceInk | Diduny (current) | Gap / висновок |
|---|---|---|---|
| General диктовка mic -> STT | Є, mature | Є | Паритет |
| Local Whisper path | Є | Є | Паритет |
| Cloud STT + streaming | Є (multi-provider) | Є (meeting realtime + async) | Паритет по core і різний provider focus |
| Meeting mode як окремий UX/state | Немає вираженого | Є (`AppDelegate+MeetingRecording`) | Diduny сильніший |
| System audio capture | Немає meeting loopback path | Є (`SystemAudioCaptureService`, SCStream audio) | Diduny сильніший |
| `system + mic` mixing | Немає | Є (`AudioMixerService`) | Diduny сильніший |
| AEC/echo suppression | Немає | Немає окремого AEC layer | Спільний головний gap |
| OCR context | Є | Не core для meeting path | Не критично для meeting roadmap |

## 7.1 Ключова інтерпретація
Для задачі meeting recording + anti-echo VoiceInk не є референсом реалізації міксу. Референсна база вже в Diduny. Тому roadmap нижче будується як еволюція поточного Diduny pipeline, а не порт VoiceInk.

---

## 8. Decision-complete roadmap: meeting + mic + anti-echo (3 tracks)

## 8.1 Загальний принцип
- Primary path: `Track A (ScreenCaptureKit-first)` як default.
- Optional advanced path: `Track B (Virtual-device-first)` під feature-flag.
- Guaranteed fallback: `Track C (Microphone-only)` коли system capture недоступний/нестабільний.

## 8.2 Track A: ScreenCaptureKit-first (Recommended)

### 8.2.1 Архітектура
- System signal:
  - `SCStream` audio output (16k mono PCM), джерело `SystemAudioCaptureService`.
- Mic signal:
  - `AVAudioEngine inputNode` (device-selectable), джерело `AudioMixerService`/окремий mic capture component.
- Reference signal для AEC:
  - system output stream або pre-mix render reference.
- DSP chain:
  - `resample -> level normalize -> AEC -> NS -> limiter -> mix -> sink`.
- Sinks:
  - fallback WAV file
  - realtime transcription PCM stream.

### 8.2.2 Технічні рішення
- Ввести explicit `AudioProcessingPipelineProtocol` і конкретну `SoftwareAECPipeline`.
- У `MeetingRecorderService` додати параметризований `startRecording(configuration:)` із capture strategy + echo mode.
- Виносити всі DSP параметри в settings/profile, не hardcode в recorder.

### 8.2.3 Ризики
- Без якісного reference signal AEC деградує.
- High CPU у long sessions на слабших машинах.
- Drift/latency між system і mic потоками треба компенсувати буферизацією/таймстампами.

### 8.2.4 Release readiness criteria
- Детермінований fallback на mic-only при системних помилках.
- Стабільний 60+ хв session без memory growth/regression.
- Echo reduction проходить приймальні quality тести (див. розділ 11).

## 8.3 Track B: Virtual-device-first (BlackHole/Loopback)

### 8.3.1 Архітектура
- Віртуальний loopback device як основне system audio source.
- Mic як окремий input.
- Мікс/processing виконується або в app graph, або у віртуальному маршруті (залежно від інструмента).

### 8.3.2 Коли обирати
- Потрібен максимально передбачуваний routing у складних multi-app кейсах.
- Користувач готовий до установки/налаштування додаткового аудіо драйвера.

### 8.3.3 Ризики
- Складніший UX onboarding.
- Зовнішній dependency + сумісність після macOS updates.
- Більше support overhead.

### 8.3.4 Статус у roadmap
- Optional track під feature-flag після стабілізації Track A.

## 8.4 Track C: Microphone-only fallback

### 8.4.1 Тригери fallback
- Screen recording permission відсутній/відхилений.
- SCStream audio unavailable.
- Критичні runtime помилки capture graph.

### 8.4.2 Поведінка
- Meeting session не рветься.
- Запис триває з mic-only.
- UI/notification явно показує degraded mode.
- Транскрипція/збереження працює в звичному режимі.

---

## 9. Practical echo-cancellation design для Diduny

## 9.1 Нові контракти сигналів

```swift
struct PCMChunk {
    let data: Data              // mono s16le, 16kHz
    let sampleRate: Int         // 16000
    let channels: Int           // 1
    let timestamp: TimeInterval // monotonic
    let source: AudioSourceKind // .microphone / .system / .mixed
}

enum AudioSourceKind {
    case microphone
    case system
    case mixed
}
```

```swift
protocol AudioProcessingPipelineProtocol {
    func configure(profile: AudioProcessingProfile) throws
    func process(mic: PCMChunk, systemReference: PCMChunk?) throws -> PCMChunk
    func flush() throws -> [PCMChunk]
    func reset()
}
```

## 9.2 Варіант 1 (Recommended): software AEC після розділення signal/reference

### 9.2.1 Pipeline
`mic raw + system ref -> AEC -> NS -> limiter -> mix with system (policy-driven) -> streaming/file`

### 9.2.2 Чому це базовий варіант
- Працює в поточній архітектурі Diduny без вимоги зовнішнього драйвера.
- Повний контроль в коді над параметрами/тюнінгом.
- Добре комбінується з існуючим `SystemAudioCaptureService` і `AudioMixerService`.

### 9.2.3 Обмеження
- Потрібна акуратна синхронізація потоків.
- CPU вищий, ніж у чисто hardware/OS-driven AEC.

## 9.3 Варіант 2: VoiceProcessingIO для mic path + post-mix safeguards

### 9.3.1 Переваги
- Частину AEC/NS дає system audio unit.
- Менше власного DSP-коду.

### 9.3.2 Обмеження
- Працює головно на mic path і не завжди добре лягає на кастомний meeting mix graph.
- Менше контролю над внутрішніми алгоритмами.

## 9.4 Варіант 3: Hybrid policy

### 9.4.1 Склад
- Lightweight AEC + NS + AGC + limiter.
- + optional NLP post-cleanup для залишкового артефактного тексту (не як заміна AEC).

### 9.4.2 Коли треба
- Якщо чистий software AEC не проходить quality thresholds у noisy кімнатах.

## 9.5 Порядок DSP-ланцюга (фіксований)
1. Resample/format unify.
2. Input level normalization.
3. AEC (mic vs system reference).
4. Noise suppression.
5. Limiter / anti-clipping.
6. Mix policy (`systemOnly` / `system+mic` / fallback).
7. Output to realtime + file sink.

---

## 10. Потрібні API / interface / type зміни в Diduny

## 10.1 `MeetingAudioSource` (розширення без breaking змін)
Файл: `/Users/rmarinskyi/IdeaProjects/personal/Diduny/Diduny/Core/Models/MeetingAudioSource.swift`

- Зберегти:
  - `.systemOnly`
  - `.systemPlusMicrophone`
- Додати policy-орієнтовані case-значення для AEC/fallback режимів:
  - `systemPlusMicrophoneAEC`
  - `microphoneFallback`
  - `auto` (strategy-driven)

## 10.2 Нові типи
Розміщення: `/Users/rmarinskyi/IdeaProjects/personal/Diduny/Diduny/Core/Models`

```swift
enum SystemAudioCaptureStrategy: String, Codable, CaseIterable {
    case screenCaptureKitFirst
    case virtualDeviceFirst
    case microphoneOnly
}

enum EchoCancellationMode: String, Codable, CaseIterable {
    case off
    case softwareAEC
    case voiceProcessingIO
    case hybrid
}

enum CaptureFallbackPolicy: String, Codable, CaseIterable {
    case failSession
    case microphoneOnlyContinue
    case systemOnlyContinue
}

struct AudioProcessingProfile: Codable, Equatable {
    var echoMode: EchoCancellationMode
    var noiseSuppressionLevel: Int      // 0...3
    var limiterEnabled: Bool
    var agcEnabled: Bool
}
```

## 10.3 `MeetingRecorderServiceProtocol` (розширення)
Файл: `/Users/rmarinskyi/IdeaProjects/personal/Diduny/Diduny/Core/Protocols/ServiceProtocols.swift`

- Додати overload:

```swift
@available(macOS 13.0, *)
struct MeetingRecordingConfiguration {
    var audioSource: MeetingAudioSource
    var captureStrategy: SystemAudioCaptureStrategy
    var processingProfile: AudioProcessingProfile
    var fallbackPolicy: CaptureFallbackPolicy
}

@available(macOS 13.0, *)
protocol MeetingRecorderServiceProtocol: AnyObject {
    var isRecording: Bool { get }
    var currentRecordingPath: String? { get }
    var audioSource: MeetingAudioSource { get set }
    var recordingDuration: TimeInterval { get }
    func startRecording() async throws
    func startRecording(configuration: MeetingRecordingConfiguration) async throws
    func stopRecording() async throws -> URL?
    func cancelRecording() async
}
```

## 10.4 Новий processing protocol
- Додати `AudioProcessingPipelineProtocol` у `Core/Protocols`.
- Додати concrete implementation у `Core/Services`:
  - `SoftwareAECPipeline`
  - `HybridAudioPipeline` (optional, phase 3/4).

## 10.5 `SettingsStorage` (persisted keys)
Файл: `/Users/rmarinskyi/IdeaProjects/personal/Diduny/Diduny/Core/Storage/SettingsStorage.swift`

Додати:
- `meetingCaptureStrategy`
- `meetingEchoCancellationMode`
- `meetingNoiseSuppressionLevel`
- `meetingFallbackPolicy`
- `meetingAudioDiagnosticsEnabled`
- `meetingProcessingProfileVersion`

---

## 11. Rollout plan (по фазах)

## 11.1 Phase 0: Instrumentation

### Scope
- Додати технічні метрики:
  - estimated SNR proxy
  - clipping rate
  - chunk dropout count
  - end-to-end latency (`capture -> transcript event`)
  - memory slope у long recording.

### Definition of done
- Метрики логуються в діагностичний канал.
- Є мінімальний internal dashboard/report artifact.

### Ризики
- Зайва телеметрія може збільшити overhead.

## 11.2 Phase 1: Capture graph refactor (без UX змін)

### Scope
- Відокремити capture, processing, sink на чіткі шари.
- Впровадити нові типи конфігурації.

### Definition of done
- Поточний UX і функціонал не ламається.
- Regression tests для existing recording pass.

## 11.3 Phase 2: Track A implementation

### Scope
- Реалізувати `screenCaptureKitFirst + softwareAEC`.
- Додати auto fallback до mic-only при capture failure.

### Definition of done
- 60+ хв стабільна сесія.
- Echo reduction видно в тестах double-talk.
- No crash/no deadlock у device switch сценаріях.

## 11.4 Phase 3: Track B (optional, feature-flag)

### Scope
- Додати virtual-device режим.
- Окремий settings UX + readiness checks.

### Definition of done
- Feature disabled by default.
- Документований install/recovery path.

## 11.5 Phase 4: Hardening + release

### Scope
- Full QA matrix.
- Налаштування safe defaults.
- Документація support/playbook.

### Definition of done
- Release checklist закритий.
- Incident rollback plan готовий.

---

## 12. Test cases and scenarios

## 12.1 Onboarding flow
- First launch -> full completion.
- Skip paths на кожному кроці.
- Resume незавершеного онбордінгу.
- Permission denied (mic/accessibility/screen).
- Missing model / incomplete setup гілки.

## 12.2 Recording functional
- Mic-only local transcription.
- Cloud transcription.
- Streaming partial updates + finalize.
- Streaming failure -> batch fallback.
- Cancel recording під час різних станів.

## 12.3 Meeting capture matrix
- `systemOnly`.
- `systemPlusMicrophone`.
- no mic permission.
- no screen permission.
- device hot-switch.
- silent source behaviors.
- 30/60/120 min sessions.

## 12.4 Echo/AEC quality
- Double-talk (користувач + remote speaker одночасно).
- High speaker volume leak.
- Headset vs built-in speakers.
- Quiet room vs noisy room.

Success criteria:
- Відчутне зниження self-echo.
- Без значної деградації intelligibility голосу користувача.
- Без clipping/dropouts/robotic artifacts.

## 12.5 Performance
- CPU/RAM на 30/60/120 хв.
- Memory growth slope.
- File size growth прогнозований.
- WebSocket backpressure handling.
- Buffer overrun/underrun resilience.

## 12.6 Regression
- Clipboard copy/paste flows.
- Hotkeys and notch states.
- Existing transcription library and queue flows.
- Cleanup/retention behaviors.

---

## 13. Recommended implementation order (next actions)
1. Phase 0 instrumentation.
2. Phase 1 refactor with no behavior change.
3. Ввести нові settings + config types.
4. Підключити `AudioProcessingPipelineProtocol`.
5. Реалізувати Track A (software AEC) з auto fallback.
6. Прогнати QA matrix і стабілізацію.
7. Лише після цього експериментальний Track B.

---

## 14. Assumptions and defaults
1. Аналіз виконано по VoiceInk snapshot commit `36427ebfa8d26db130816d4676463df3e3933e0e`.
2. Порівняння і roadmap орієнтовані на поточний код Diduny у цьому workspace.
3. Документ підготовлений українською.
4. Основний deliverable: `/Users/rmarinskyi/IdeaProjects/personal/Diduny/docs/voiceink_audit_and_audio_roadmap.md`.
5. Розглянуті всі 3 стратегії system audio, primary path: `ScreenCaptureKit-first`.
6. Фокус: практичне впровадження без абстрактного AI-hype.

---

## 15. Evidence map (ключові посилання на код)

## 15.1 VoiceInk
- App bootstrap/onboarding gate:
  - `/tmp/VoiceInk/VoiceInk/VoiceInk.swift:22`
  - `/tmp/VoiceInk/VoiceInk/VoiceInk.swift:200`
  - `/tmp/VoiceInk/VoiceInk/VoiceInk.swift:262`
- Onboarding screens:
  - `/tmp/VoiceInk/VoiceInk/Views/Onboarding/OnboardingView.swift:3`
  - `/tmp/VoiceInk/VoiceInk/Views/Onboarding/OnboardingPermissionsView.swift:32`
  - `/tmp/VoiceInk/VoiceInk/Views/Onboarding/OnboardingModelDownloadView.swift:3`
  - `/tmp/VoiceInk/VoiceInk/Views/Onboarding/OnboardingTutorialView.swift:4`
- Recorder orchestration:
  - `/tmp/VoiceInk/VoiceInk/Recorder.swift:7`
  - `/tmp/VoiceInk/VoiceInk/Recorder.swift:89`
  - `/tmp/VoiceInk/VoiceInk/Recorder.swift:162`
- Core audio capture format:
  - `/tmp/VoiceInk/VoiceInk/CoreAudioRecorder.swift:23`
  - `/tmp/VoiceInk/VoiceInk/CoreAudioRecorder.swift:380`
  - `/tmp/VoiceInk/VoiceInk/CoreAudioRecorder.swift:631`
- STT state machine:
  - `/tmp/VoiceInk/VoiceInk/Whisper/WhisperState.swift:147`
  - `/tmp/VoiceInk/VoiceInk/Whisper/WhisperState.swift:297`
- Service routing:
  - `/tmp/VoiceInk/VoiceInk/Services/TranscriptionServiceRegistry.swift:43`
  - `/tmp/VoiceInk/VoiceInk/Services/TranscriptionServiceRegistry.swift:58`
- Streaming providers:
  - `/tmp/VoiceInk/VoiceInk/Services/StreamingTranscription/StreamingTranscriptionService.swift:75`
- ScreenCapture usage for OCR context:
  - `/tmp/VoiceInk/VoiceInk/Services/ScreenCaptureService.swift:7`
  - `/tmp/VoiceInk/VoiceInk/Services/ScreenCaptureService.swift:126`
  - `/tmp/VoiceInk/VoiceInk/Services/AIEnhancement/AIEnhancementService.swift:412`
- Audio cleanup is retention:
  - `/tmp/VoiceInk/VoiceInk/Views/Settings/AudioCleanupSettingsView.swift:109`
  - `/tmp/VoiceInk/VoiceInk/Views/Settings/AudioCleanupManager.swift:95`

## 15.2 Diduny
- Meeting mode orchestration:
  - `/Users/rmarinskyi/IdeaProjects/personal/Diduny/Diduny/App/AppDelegate+MeetingRecording.swift:104`
  - `/Users/rmarinskyi/IdeaProjects/personal/Diduny/Diduny/App/AppDelegate+MeetingRecording.swift:199`
  - `/Users/rmarinskyi/IdeaProjects/personal/Diduny/Diduny/App/AppDelegate+MeetingRecording.swift:317`
- Meeting recorder capture modes:
  - `/Users/rmarinskyi/IdeaProjects/personal/Diduny/Diduny/Core/Services/MeetingRecorderService.swift:27`
  - `/Users/rmarinskyi/IdeaProjects/personal/Diduny/Diduny/Core/Services/MeetingRecorderService.swift:102`
  - `/Users/rmarinskyi/IdeaProjects/personal/Diduny/Diduny/Core/Services/MeetingRecorderService.swift:127`
- System audio capture:
  - `/Users/rmarinskyi/IdeaProjects/personal/Diduny/Diduny/Core/Services/SystemAudioCaptureService.swift:81`
  - `/Users/rmarinskyi/IdeaProjects/personal/Diduny/Diduny/Core/Services/SystemAudioCaptureService.swift:87`
  - `/Users/rmarinskyi/IdeaProjects/personal/Diduny/Diduny/Core/Services/SystemAudioCaptureService.swift:285`
- Mixing and realtime hook:
  - `/Users/rmarinskyi/IdeaProjects/personal/Diduny/Diduny/Core/Services/AudioMixerService.swift:51`
  - `/Users/rmarinskyi/IdeaProjects/personal/Diduny/Diduny/Core/Services/AudioMixerService.swift:53`
  - `/Users/rmarinskyi/IdeaProjects/personal/Diduny/Diduny/Core/Services/AudioMixerService.swift:372`
  - `/Users/rmarinskyi/IdeaProjects/personal/Diduny/Diduny/Core/Services/AudioMixerService.swift:452`
- Existing audio source model:
  - `/Users/rmarinskyi/IdeaProjects/personal/Diduny/Diduny/Core/Models/MeetingAudioSource.swift:3`
- Existing protocol surface:
  - `/Users/rmarinskyi/IdeaProjects/personal/Diduny/Diduny/Core/Protocols/ServiceProtocols.swift:70`
- Existing meeting settings:
  - `/Users/rmarinskyi/IdeaProjects/personal/Diduny/Diduny/Core/Storage/SettingsStorage.swift:89`
  - `/Users/rmarinskyi/IdeaProjects/personal/Diduny/Diduny/Core/Storage/SettingsStorage.swift:217`

