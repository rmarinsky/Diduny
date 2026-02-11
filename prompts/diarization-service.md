# Task: Implement Speaker Diarization Service

## Goal
Build a backend service that accepts an audio file and returns a transcript
with speaker labels (Speaker 1, Speaker 2, etc.) and timestamps.

## Stack
- Python 3.11+
- FastAPI for the HTTP API
- pyannote-audio 3.x for speaker diarization
- whisperX for word-level alignment + speaker assignment
- OR: Whisper (openai-whisper / faster-whisper) + pyannote-audio combined manually

## Architecture

### Input
- Audio file (WAV, MP3, M4A) via multipart upload
- Optional parameters:
  - `num_speakers` (int, optional) — if known, improves accuracy
  - `min_speakers` / `max_speakers` (int, optional) — range hint
  - `language` (str, optional) — ISO 639-1 code, e.g. "uk", "en"

### Output (JSON)
```json
{
  "speakers": ["Speaker 1", "Speaker 2"],
  "segments": [
    {
      "speaker": "Speaker 1",
      "start": 0.0,
      "end": 2.5,
      "text": "Hello, how are you?"
    },
    {
      "speaker": "Speaker 2",
      "start": 2.7,
      "end": 5.1,
      "text": "I'm doing well, thanks."
    }
  ],
  "full_text": "Speaker 1: Hello, how are you?\nSpeaker 2: I'm doing well, thanks."
}
```

### Processing Pipeline

1. **Receive audio** — save temp file, convert to 16kHz mono WAV if needed (ffmpeg/pydub)
2. **Transcribe** — run Whisper (or faster-whisper for speed) to get word-level timestamps
3. **Diarize** — run pyannote-audio pipeline to get speaker segments with timestamps
4. **Align** — assign each transcribed word/segment to a speaker based on time overlap
5. **Merge** — combine consecutive words from the same speaker into sentences
6. **Return** — structured JSON response

### Implementation Details

#### pyannote-audio setup
- Requires HuggingFace token (accept pyannote model terms at hf.co)
- Model: `pyannote/speaker-diarization-3.1`
- Embedding model: `pyannote/wespeaker-voxceleb-resnet34-LM` (bundled)
- Pipeline initialization:
  ```python
  from pyannote.audio import Pipeline
  pipeline = Pipeline.from_pretrained(
      "pyannote/speaker-diarization-3.1",
      use_auth_token="HF_TOKEN"
  )
  pipeline.to(torch.device("cuda"))  # if GPU available
  ```

#### Whisper setup (choose one)
- `faster-whisper` (CTranslate2-based, 4x faster than openai-whisper)
- Use `word_timestamps=True` for alignment
- Use `large-v3` model for best accuracy, `medium` for speed/accuracy balance

#### Alignment strategy
For each Whisper word segment (start, end, word):
- Find which pyannote speaker segment overlaps the most
- Assign that speaker to the word
- Group consecutive words with same speaker into utterances

#### API Endpoints
- `POST /transcribe` — upload audio, get diarized transcript
- `GET /health` — service health check
- Optional: `POST /transcribe/stream` — SSE for progress updates
  (useful for long files: "diarizing...", "transcribing...", "aligning...")

### Performance Considerations
- Load models once at startup, reuse across requests
- For GPU: pyannote + whisper can share the same CUDA device
- For CPU-only: use `faster-whisper` with `int8` quantization
- Large files (1h+): process in chunks or use async workers (Celery/ARQ)
- Temp files: clean up after processing

### Error Handling
- No speech detected → return empty segments with message
- Single speaker detected → return all segments as "Speaker 1"
- Audio too short (<1s) → return error
- Unsupported format → return error with supported formats list

### Optional Enhancements
- Speaker embedding cache — re-identify known speakers across recordings
- Language auto-detection — let Whisper detect, pass to pyannote
- Overlap handling — mark overlapping speech segments
- Confidence scores — include per-segment confidence
- ONNX export — for faster inference without PyTorch overhead:
  ```python
  # Export pyannote segmentation model to ONNX
  # Export embedding model to ONNX
  # Use onnxruntime for inference (no torch dependency in production)
  ```

### Dependencies
```
fastapi
uvicorn
python-multipart
pyannote.audio>=3.1
faster-whisper>=1.0
torch
torchaudio
pydub
ffmpeg-python
```

### Docker Considerations
- Base image: `nvidia/cuda:12.1-runtime` for GPU, `python:3.11-slim` for CPU
- Model weights: download at build time or mount as volume (~3GB total)
- Memory: ~4GB RAM minimum (CPU), ~6GB VRAM (GPU)
