# Proxy Service Migration - API Contract & Test Plan

## Current Architecture

```
Diduny App  →  Soniox API (api.soniox.com)
            →  Soniox RT WebSocket (stt-rt.soniox.com)
```

## Target Architecture

```
Diduny App  →  Proxy Service  →  Soniox API
                    ↓
              Billing / Usage Tracking
```

---

## API Contract (Endpoints the Proxy Must Support)

### Soniox REST Endpoints (base: `https://api.soniox.com/v1`)

| # | Method | Path | Purpose |
|---|--------|------|---------|
| 1 | `POST` | `/files` | Upload audio file (multipart/form-data) |
| 2 | `POST` | `/transcriptions` | Create transcription job |
| 3 | `GET` | `/transcriptions/{id}` | Poll job status |
| 4 | `GET` | `/transcriptions/{id}/transcript` | Get transcript result |
| 5 | `GET` | `/models` | Test connection / validate API key |

### Soniox WebSocket Endpoint

| # | Protocol | URL | Purpose |
|---|----------|-----|---------|
| 6 | `wss` | `stt-rt.soniox.com/transcribe-websocket` | Realtime streaming transcription |

### Google Translate Endpoint

| # | Method | URL | Purpose |
|---|--------|-----|---------|
| 7 | `GET` | `translate.googleapis.com/translate_a/single` | Text translation (Cmd+C+C) |

### Authentication

All requests use: `Authorization: Bearer <API_KEY>`
WebSocket sends API key in the initial JSON config message.

---

## Endpoint Details

### 1. POST /files

**Request:**
- Content-Type: `multipart/form-data; boundary=<UUID>`
- Body: single file part with `name="file"`, `filename="recording.{ext}"`, `Content-Type: audio/{mime}`

**Supported formats:** WAV, M4A/AAC, MP3, FLAC, OGG

**Response (200/201):**
```json
{
  "id": "<file_id>",
  "filename": "recording.wav",
  "size": 123456,
  "created_at": "2024-01-01T00:00:00Z",
  "client_reference_id": null
}
```

### 2. POST /transcriptions

**Request:** `Content-Type: application/json`

Three variants:

**a) Standard transcription (voice dictation & file transcription):**
```json
{
  "file_id": "<file_id>",
  "model": "stt-async-v4",
  "language_hints": ["uk", "en"],
  "language_hints_strict": true,
  "context": "<voice_note_processing_prompt>"
}
```

**b) Meeting with diarization:**
```json
{
  "file_id": "<file_id>",
  "model": "stt-async-v4",
  "enable_speaker_diarization": true,
  "language_hints": ["uk", "en"],
  "language_hints_strict": true
}
```

**c) Translation:**
```json
{
  "file_id": "<file_id>",
  "model": "stt-async-v4",
  "context": "<voice_note_processing_prompt>",
  "translation": {
    "type": "two_way",
    "language_a": "en",
    "language_b": "uk"
  },
  "language_hints": ["en", "uk"],
  "language_hints_strict": true
}
```

**Response (200/201):**
```json
{
  "id": "<transcription_id>",
  "status": "queued",
  "model": "stt-async-v4",
  "error_message": null
}
```

### 3. GET /transcriptions/{id}

**Response:**
```json
{
  "id": "<transcription_id>",
  "status": "queued | processing | completed | error",
  "error_message": "<if error>",
  "error_type": "<if error>"
}
```

**Polling:** every 1s, max 60 attempts.

### 4. GET /transcriptions/{id}/transcript

**Response:**
```json
{
  "id": "<transcription_id>",
  "text": "<full text>",
  "tokens": [
    {
      "text": "word",
      "start_ms": 100,
      "end_ms": 500,
      "confidence": 0.95,
      "speaker": "Speaker 1",
      "language": "uk",
      "translation_status": "translation",
      "source_language": "uk"
    }
  ]
}
```

### 5. GET /models

**Response:** 200 = valid key, 401/403 = invalid key.

### 6. GET /translate (Text Translation - Google Translate)

**Current implementation:** Uses free Google Translate endpoint directly from the app.
**Proxy migration:** Route through proxy to track usage and enable future billing.

**Endpoint:** `GET https://translate.googleapis.com/translate_a/single`

**Query Parameters:**
| Param | Value | Description |
|-------|-------|-------------|
| `client` | `gtx` | Client identifier |
| `sl` | `auto` | Source language (auto-detect) |
| `tl` | `uk` / `en` / etc | Target language code |
| `dt` | `t` | Data type (translation) |
| `dj` | `1` | JSON response format |
| `q` | `<text>` | Source text to translate |

**Trigger:** Double Cmd+C (copies selected text, then auto-translates)

**Language detection:** Uses Apple NLLanguageRecognizer locally, then:
- If source is Ukrainian → target English (or first non-UK favorite)
- If source is English → target Ukrainian (or first non-EN favorite)
- Otherwise → first favorite language

**Response:**
```json
{
  "sentences": [
    { "trans": "translated sentence 1" },
    { "trans": "translated sentence 2" }
  ]
}
```

**Auto-copy:** Result is automatically copied to clipboard after translation.

### 7. WebSocket: /transcribe-websocket

**Initial config (JSON string):**
```json
{
  "api_key": "<API_KEY>",
  "model": "stt-rt-v4",
  "audio_format": "s16le",
  "sample_rate": 16000,
  "num_channels": 1,
  "enable_speaker_diarization": true,
  "language_hints": ["uk", "en"],
  "language_hints_strict": true,
  "translation": { ... },
  "enable_endpoint_detection": true,
  "max_endpoint_delay_ms": 1200
}
```

**Data flow:**
- Client → Server: binary audio chunks (s16le PCM, 16kHz mono)
- Client → Server: `{"type": "finalize"}` + empty binary frame to end
- Server → Client: JSON with `tokens[]`, `finished`, `error_code`, `error_message`

---

## Features List

| # | Feature | API Used | Notes |
|---|---------|----------|-------|
| 1 | Voice dictation | Soniox REST (upload → transcribe → poll → get) | Standard flow, includes voice note context prompt |
| 2 | File transcription | Soniox REST (same as voice) | Accepts WAV/M4A/MP3/FLAC/OGG/MP4/MOV |
| 3 | Translation (voice) | Soniox REST (with `translation` param) | Two-way EN↔UK, pairs languages automatically |
| 4 | Meeting recording (async) | Soniox REST (with `enable_speaker_diarization`) | Long recordings, formatted with `[MM:SS] Speaker N:` |
| 5 | Realtime meeting transcription | Soniox WebSocket | Streaming audio chunks, incremental tokens |
| 6 | Realtime meeting translation | Soniox WebSocket (with `translation` config) | Same WS with translation config |
| 7 | Text translation (Cmd+C+C) | Google Translate REST | Double Cmd+C triggers, auto-detects language, auto-copies result |
| 8 | Test connection | Soniox REST `GET /models` | API key validation |
| 9 | Local transcription (Whisper) | None (on-device) | No proxy needed |

---

## Test Plan

### Category 1: File Upload Passthrough

| # | Test | Method | Expected |
|---|------|--------|----------|
| 1.1 | Upload WAV file | POST /files | 200/201, returns `file_id` |
| 1.2 | Upload M4A file | POST /files | 200/201, returns `file_id` |
| 1.3 | Upload MP3 file | POST /files | 200/201, returns `file_id` |
| 1.4 | Upload FLAC file | POST /files | 200/201, returns `file_id` |
| 1.5 | Upload OGG file | POST /files | 200/201, returns `file_id` |
| 1.6 | Upload large file (>25MB meeting recording) | POST /files | 200/201, handles large payload |
| 1.7 | Upload with invalid auth | POST /files | 401/403 passthrough |
| 1.8 | Upload empty file | POST /files | Error passthrough from Soniox |
| 1.9 | Upload MP4 video file | POST /files | 200/201, returns `file_id` |

### Category 2: Standard Transcription

| # | Test | Method | Expected |
|---|------|--------|----------|
| 2.1 | Create transcription job | POST /transcriptions | 200/201, returns `transcription_id` with status `queued` |
| 2.2 | Create with language hints | POST /transcriptions | Language hints forwarded to Soniox |
| 2.3 | Create with context prompt | POST /transcriptions | Context string forwarded correctly |
| 2.4 | Poll status - queued | GET /transcriptions/{id} | Returns `status: "queued"` |
| 2.5 | Poll status - processing | GET /transcriptions/{id} | Returns `status: "processing"` |
| 2.6 | Poll status - completed | GET /transcriptions/{id} | Returns `status: "completed"` |
| 2.7 | Poll status - error | GET /transcriptions/{id} | Returns error_message, error_type |
| 2.8 | Get transcript text | GET /transcriptions/{id}/transcript | Returns `text` and `tokens[]` array |
| 2.9 | Get transcript with token timestamps | GET /transcriptions/{id}/transcript | Tokens have `start_ms`, `end_ms` |
| 2.10 | Invalid transcription ID | GET /transcriptions/{bad_id} | Error passthrough |

### Category 3: Translation

| # | Test | Method | Expected |
|---|------|--------|----------|
| 3.1 | Create translation job (EN→UK) | POST /transcriptions | `translation` field forwarded |
| 3.2 | Create translation job (UK→EN) | POST /transcriptions | `translation` field forwarded |
| 3.3 | Get translated transcript | GET /transcriptions/{id}/transcript | Tokens with `translation_status: "translation"` |
| 3.4 | Translation tokens have `source_language` | GET /transcriptions/{id}/transcript | `source_language` field present |

### Category 4: Meeting Recording (Diarization)

| # | Test | Method | Expected |
|---|------|--------|----------|
| 4.1 | Create diarized transcription | POST /transcriptions | `enable_speaker_diarization: true` forwarded |
| 4.2 | Get diarized transcript | GET /transcriptions/{id}/transcript | Tokens have `speaker` field |
| 4.3 | Speaker timestamps present | GET /transcriptions/{id}/transcript | Tokens have correct `start_ms`/`end_ms` |
| 4.4 | Long recording (>1 hour) | Full flow | Completes within polling timeout |

### Category 5: WebSocket Realtime Streaming

| # | Test | Method | Expected |
|---|------|--------|----------|
| 5.1 | WebSocket connection with valid key | wss connect | Connection established |
| 5.2 | WebSocket connection with invalid key | wss connect | Error response |
| 5.3 | Send initial config JSON | wss text msg | Config forwarded to Soniox |
| 5.4 | Stream audio binary chunks | wss binary msg | Chunks forwarded, tokens received back |
| 5.5 | Receive incremental tokens | wss receive | Tokens with `text`, `is_final`, `speaker` |
| 5.6 | Send finalize message | wss text msg | `{"type": "finalize"}` forwarded |
| 5.7 | Send empty binary frame (end-of-stream) | wss binary msg | Empty frame forwarded |
| 5.8 | Receive `finished: true` signal | wss receive | Session ends cleanly |
| 5.9 | WebSocket with diarization config | wss connect | Speaker labels in tokens |
| 5.10 | WebSocket with translation config | wss connect | Translation tokens received |
| 5.11 | Connection keepalive (ping/pong) | wss | Proxy maintains ping every 30s |
| 5.12 | Reconnection after disconnect | wss | Client reconnects (up to 3 attempts) |

### Category 6: Auth & Connection

| # | Test | Method | Expected |
|---|------|--------|----------|
| 6.1 | Test connection - valid key | GET /models | 200 |
| 6.2 | Test connection - invalid key | GET /models | 401/403 |
| 6.3 | Missing Authorization header | Any endpoint | 401 from proxy |
| 6.4 | Expired/revoked key | Any endpoint | Error passthrough |

### Category 7: Text Translation

| # | Test | Method | Expected |
|---|------|--------|----------|
| 7.1 | Translate short text (EN→UK) | GET /translate | Translated text returned |
| 7.2 | Translate short text (UK→EN) | GET /translate | Translated text returned |
| 7.3 | Translate with auto-detect language | GET /translate | `sl=auto` works, correct target resolved |
| 7.4 | Translate to arbitrary language | GET /translate | Any `tl` code forwarded correctly |
| 7.5 | Translate long text (multiple sentences) | GET /translate | Multiple `sentences` joined correctly |
| 7.6 | Translate empty text | GET /translate | Handled gracefully (error or empty) |
| 7.7 | Google API error passthrough | GET /translate | Error status + body forwarded |
| 7.8 | Special characters in text (URL encoding) | GET /translate | Query param `q` properly encoded |

### Category 8: Error Passthrough

| # | Test | Method | Expected |
|---|------|--------|----------|
| 8.1 | Soniox 500 error | Any | Proxy returns same status + body |
| 8.2 | Soniox timeout | Any | Proxy returns gateway timeout |
| 8.3 | Transcription job fails | GET /transcriptions/{id} | `status: "error"` with error_message |
| 8.4 | Invalid JSON body | POST /transcriptions | Error passthrough |
| 8.5 | WebSocket server error | wss | `error_code` + `error_message` forwarded |
| 8.6 | Google Translate 429 rate limit | GET /translate | Error forwarded |

### Category 9: Proxy-Specific (Billing Preparation)

| # | Test | Method | Expected |
|---|------|--------|----------|
| 9.1 | Request logged with user identity | Any | Usage record created |
| 9.2 | File upload size tracked | POST /files | Bytes recorded for billing |
| 9.3 | Transcription job type tracked | POST /transcriptions | Type (standard/translation/diarization) recorded |
| 9.4 | WebSocket session duration tracked | wss | Session start/end times recorded |
| 9.5 | WebSocket audio bytes tracked | wss | Total streamed bytes recorded |
| 9.6 | Text translation requests tracked | GET /translate | Character count recorded for billing |
| 9.7 | Concurrent requests handled | Multiple | No cross-contamination between users |

### Category 10: E2E Smoke Tests (App → Proxy → Soniox/Google)

| # | Test | Flow | Expected |
|---|------|------|----------|
| 10.1 | Voice dictation E2E | Record → upload → transcribe → get text | Text copied to clipboard |
| 10.2 | File transcription E2E | Select file → upload → transcribe → get text | Text copied, duration correct |
| 10.3 | Voice translation E2E | Record → upload → translate → get text | Translated text returned |
| 10.4 | Meeting recording E2E | Record meeting → upload → diarize → get text | Formatted with speakers |
| 10.5 | Realtime meeting E2E | Start meeting → stream audio → receive tokens → finalize | Incremental transcription works |
| 10.6 | Text translation E2E | Cmd+C+C → translate text → auto-copy | Translated text in clipboard |
| 10.7 | Test connection E2E | Settings → Test Connection | "Connection successful" |

---

## Summary

- **6 Soniox REST endpoints** to proxy (5 paths + 1 connection test)
- **1 Soniox WebSocket endpoint** to proxy (bidirectional: binary audio + JSON control/responses)
- **1 Google Translate endpoint** to proxy (text translation)
- **9 features** total (8 use external API, 1 is local-only)
- **64 tests** across 10 categories
