# План: meeting audio тільки для macOS 14.4+

Дата: 2026-02-13

## Scope

- Підтримуємо лише `macOS 14.4+`.
- Системне аудіо: тільки через Core Audio Process Tap.
- Мікрофон: через `AVAudioEngine` (або Core Audio input unit, якщо потрібно пізніше).
- Старі macOS не підтримуємо взагалі: fail-fast з явним повідомленням.

## Ціль

- Записувати `system + microphone` без "випадання кадрів" і без ефекту "по черзі чути лише одне джерело".
- Мати стабільний mixed WAV + той самий mono PCM stream для realtime STT.

## Архітектура (цільова)

## 1) Capture Layer

- `ProcessTapSystemCaptureService`:
  - створює process tap (`AudioHardwareCreateProcessTap`);
  - віддає chunks з timestamp (host time / sample time).
- `MicrophoneCaptureService`:
  - знімає mic буфери + timestamp.

## 2) Buffering Layer

- Для кожного source окремий SPSC ring buffer:
  - `systemRing`,
  - `micRing`.
- У callback тільки copy+enqueue (без disk I/O і без heavy conversion).

## 3) Mix Layer (frame-driven)

- Окремий worker тікає fixed quantum (10ms = 160 frame @16k).
- На кожен quantum:
  - читає system chunk за target timestamp;
  - читає mic chunk за target timestamp;
  - якщо chunk відсутній: підставляє тишу лише на цей quantum.
- Мікс: `mixed = clamp((system * gainS) + (mic * gainM))`.

## 4) Sink Layer

- Єдиний output pipeline:
  - WAV writer (fallback file),
  - realtime PCM s16le 16k mono callback (для Soniox).
- І файл, і realtime отримують один і той самий post-mix stream.

## План робіт

## Фаза 0. Contract + fail-fast

1. Додати runtime guard:
   - якщо OS < 14.4: одразу `unsupportedOS` і зупинка старту.
2. В `MeetingRecorderService` залишити тільки один mixed backend для `systemPlusMicrophone`.
3. Прибрати/ізолювати legacy branch на ScreenCaptureKit для meeting mode.

Критерій:
- На 14.4+ запис стартує.
- На <14.4 показуємо чітку помилку без часткового старту.

## Фаза 1. System capture через Process Tap

1. Створити `ProcessTapSystemCaptureService.swift`.
2. Підняти tap + callback delivery в PCM float32 (native format).
3. Нормалізувати формати до внутрішнього `float32 mono 16k` (через converter worker, не в callback).
4. Додати health metrics:
   - `tap_callbacks_per_sec`,
   - `tap_drop_count`.

Критерій:
- Чистий system-only capture стабільно 60+ хв без обривів.

## Фаза 2. Timestamped mixer

1. Замінити поточний queue-length mixer у `AudioMixerService`.
2. Ввести структуру `AudioChunk { source, timestamp, sampleRate, frames }`.
3. Реалізувати ring buffer + mixer clock.
4. Ввести telemetry:
   - `system_underflow`,
   - `mic_underflow`,
   - `ring_overflow`,
   - `max_sync_delta_ms`.

Критерій:
- Немає "чергування каналів" при джитері одного джерела.
- У long-run тесті не росте latency/черга безконтрольно.

## Фаза 3. Інтеграція у MeetingRecorderService

1. Оновити orchestration:
   - старт order: system tap -> mic -> mixer worker -> sink.
2. stop/cancel:
   - гарантований flush останніх quantum,
   - коректний teardown без втрати хвоста файлу.
3. Зберегти поточні callback-и UI/transcription без зміни API назовні.

Критерій:
- Start/Stop/Cancel стабільні в 20+ циклах підряд.

## Фаза 4. Тести

1. Unit:
   - ring buffer boundary,
   - timestamp alignment,
   - mix saturation/clamp.
2. Integration:
   - system only,
   - mic only,
   - system+mic з асинхронним джитером.
3. Soak:
   - 1h/2h запис,
   - перевірка memory slope,
   - перевірка drift між джерелами.

Критерій:
- Без крешів/корупції WAV.
- Drift у межах заданого порогу (напр. < 40ms p95).

## Definition of Done

- Під `macOS 14.4+` meeting recording працює тільки через Process Tap backend.
- `system + mic` мікс не має артефакту "слухається один канал в моменті".
- Реaltime і файл ідуть з одного post-mix потоку.
- Є базові метрики і логи для прод-діагностики.

## Що свідомо НЕ робимо

- Не підтримуємо macOS < 14.4.
- Не додаємо BlackHole/віртуальні драйвери.
- Не робимо AEC/NS у цій ітерації.

