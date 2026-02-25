# Аналіз meeting-аудіо (system + mic) і редизайн pipeline

Дата: 2026-02-13

## TL;DR

- Симптом "ніби слухається один канал в моменті" пояснюється не стерео/моно, а логікою міксу без таймлайна.
- Поточний міксер змішує черги за принципом "що приїхало", без прив'язки до timestamp, і має fallback в single-source після `1.0s`.
- Для стабільного запису без пропусків треба перейти на frame-driven mixer з timestamp + ring buffer на кожне джерело.
- Для macOS 14.4+ найкращий шлях: Core Audio Process Tap (driver-free system capture) + mic capture, далі єдиний міксер.

## Як зроблено зараз (факт по коду)

### 1) Режими запису

- `MeetingRecorderService` має 2 режими:
  - `systemOnly`: прямий запис через `SystemAudioCaptureService` у WAV.
  - `systemPlusMicrophone`: `SystemAudioCaptureService` у callback mode + `AudioMixerService` для міксу.
- Дивись:
  - `Diduny/Core/Services/MeetingRecorderService.swift:85`
  - `Diduny/Core/Services/MeetingRecorderService.swift:127`

### 2) System audio capture

- `SystemAudioCaptureService` стартує `SCStream` і вмикає audio capture.
- Поточна конфігурація ріже потік одразу до `16kHz mono`:
  - `Diduny/Core/Services/SystemAudioCaptureService.swift:87`
  - `Diduny/Core/Services/SystemAudioCaptureService.swift:88`
- У mixed-режимі буфери летять через callback `onAudioBuffer` у `AudioMixerService`.

### 3) Mixed pipeline

- Mic знімається tap-ом `AVAudioEngine.inputNode`.
- Кожен буфер (mic/system) копіюється, конвертується і додається в окремі масиви `micSamples/systemSamples`.
- Далі `mixAndWriteAvailableFrames(...)` бере:
  - або `min(micAvailable, systemAvailable)` (коли обидва є),
  - або один source, якщо інший "завис" більше `sourceStallThreshold = 1.0s`.
- Дивись:
  - `Diduny/Core/Services/AudioMixerService.swift:43`
  - `Diduny/Core/Services/AudioMixerService.swift:45`
  - `Diduny/Core/Services/AudioMixerService.swift:51`
  - `Diduny/Core/Services/AudioMixerService.swift:386`
  - `Diduny/Core/Services/AudioMixerService.swift:395`
  - `Diduny/Core/Services/AudioMixerService.swift:426`

## Чому з'являється ефект "слухається один канал"

## 1) Немає спільного timeline між джерелами

- У міксер не передається timestamp буфера:
  - не використовується `AVAudioTime` з mic tap callback,
  - не використовується `CMSampleBuffer` PTS для system.
- Через це синхронізація йде по довжині черг/часу приходу, а не по часу семплів.

## 2) Fallback у single-source закладений у дизайн

- Якщо одне джерело затрималось >1000ms, міксер пише тільки друге.
- Це прямо дає "фрагментами чути лише system або лише mic".

## 3) Конвертація і мікс в одному serial `writeQueue`

- При джитері/піках CPU один source може накопичитись швидше, інший відставати.
- Без frame clock це перетворюється на "рваний" баланс джерел.

## 4) Раннє даунсемплення до 16k mono на system path

- Це не головна причина пропусків, але зменшує headroom для якісного вирівнювання/обробки.

## Як переробити, щоб не втрачати "кадри" (рекомендована архітектура)

## Ціль

- Міксер працює в фіксованому quantum (наприклад 10ms = 160 семплів @16k).
- Кожне джерело має свій timestamped ring buffer.
- На кожен quantum:
  - читаємо system chunk по цільовому часу,
  - читаємо mic chunk по цільовому часу,
  - якщо конкретного source chunk нема: пишемо тишу лише на цей quantum, не блокуємо весь pipeline.

## Базові правила pipeline

- У real-time callback робити тільки:
  - мінімальну валідацію,
  - copy у lock-free/SPSC ring buffer.
- Ніяких важких конверсій/алокацій/дискових write у callback.
- Конвертацію, мікс, encode/write робити в окремому worker.
- Додати метрики:
  - `system_underflow`, `mic_underflow`,
  - `ring_overflow`,
  - `max_queue_lag_ms`,
  - `mixed_quanta_written`.

## Capture strategy

- macOS 14.4+:
  - primary: Core Audio Process Tap (`AudioHardwareCreateProcessTap`) для system audio.
- macOS 13.x-14.3:
  - fallback: поточний ScreenCaptureKit path, але з новим timestamped mixer.

## Бібліотеки / компоненти, які реально допоможуть

## 1) Core Audio Process Taps (native API, не third-party)

- Що дає: driver-free system capture (без BlackHole), менше "магії" ніж SCStream у задачі суто аудіо.
- Джерела:
  - Apple docs: [Capturing system audio with Core Audio taps](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps)
  - Apple API: [AudioHardwareCreateProcessTap](https://developer.apple.com/documentation/coreaudio/audiohardwarecreateprocesstap%28_%3A_%3A%29)

## 2) insidegui/AudioCap (Swift, BSD-2-Clause) — практичний референс

- Не готова "ліба", а sample-проєкт, але дуже корисний як стартовий каркас.
- Показує повний шлях: `CATapDescription` -> `AudioHardwareCreateProcessTap` -> aggregate device -> IOProc callback.
- Репо:
  - [AudioCap](https://github.com/insidegui/AudioCap)

## 3) SFBAudioEngine (MIT, Swift + Objective-C)

- Добре закриває надійний encode/decode/format conversion layer.
- Актуальний реліз на момент перевірки: `0.11.0` (2026-01-19).
- Репо:
  - [SFBAudioEngine](https://github.com/sbooth/SFBAudioEngine)

## 4) AudioKit (MIT, Swift)

- Зручно для audio graph/DSP/mixing, SPM-friendly.
- Але system audio capture саме по собі не вирішує: все одно потрібен ScreenCaptureKit або Core Audio Tap.
- Репо:
  - [AudioKit](https://github.com/AudioKit/AudioKit)

## 5) BlackHole (GPL-3.0) — тільки як fallback/окремий install

- Надійний loopback driver, але GPL-ліцензія.
- Для комерційного closed-source app не вбудовувати напряму без окремої ліцензійної домовленості.
- Репо:
  - [BlackHole](https://github.com/ExistentialAudio/BlackHole)

## Що рекомендую для Diduny

## Фаза 1 (мінімум ризику, швидкий ефект)

- Не міняти UI/флоу.
- Замінити внутрішню логіку `AudioMixerService` на timestamped ring-buffer mixer.
- Додати telemetry по underflow/overflow.

## Фаза 2 (кращий system capture на нових macOS)

- Додати новий capture backend:
  - `CoreAudioTapSystemCaptureService` (14.4+),
  - fallback на існуючий `SystemAudioCaptureService` (SCStream).

## Фаза 3 (опційно)

- Якщо потрібне echo/noise clean-up:
  - підключати WebRTC APM (AEC/NS/AGC) перед фінальним mix.
  - Джерело: [WebRTC Audio Processing Module](https://webrtc.googlesource.com/src/%2B/refs/heads/main/modules/audio_processing/g3doc/audio_processing_module.md)

## Важливі зовнішні примітки

- З WWDC22 видно, що ScreenCaptureKit для audio типово демонструється в `48kHz stereo`, і окремо підкреслюється роль `sampleHandlerQueue`.
  - [Meet ScreenCaptureKit (WWDC22)](https://developer.apple.com/kr/videos/play/wwdc2022/10156/)
- Поточний код Diduny примусово ставить `16kHz mono` вже на вході system stream, що добре для економії, але гірше для гнучкого міксу.
