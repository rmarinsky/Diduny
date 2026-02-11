# Task: Add Offline Speaker Diarization to Diduny

## Goal
Add on-device speaker diarization to meeting recordings so transcripts show speaker labels (Speaker 1, Speaker 2, etc.) without sending audio to a server.

## Research Summary

### whisper.cpp — no native diarization
- whisper.cpp does transcription only, no speaker tracking
- Experimental `tinydiarize` model adds speaker-change tokens but is not production-ready
- Cannot rely on whisper.cpp alone for diarization

### Recommended: FluidAudio (Pure Swift, Core ML)
- GitHub: https://github.com/FluidInference/FluidAudio
- Uses pyannote models converted to Core ML format
- Runs on Apple Neural Engine (ANE) — fast and battery-efficient
- ~10x speedup on CPU, ~20x on GPU vs PyTorch
- SPM integration, pure Swift API
- Requires macOS 14+ (Diduny already targets 14.0+)
- Core ML model: https://huggingface.co/FluidInference/speaker-diarization-coreml

### Alternative: sherpa-onnx (C++ with C API)
- GitHub: https://github.com/k2-fsa/sherpa-onnx
- Uses ONNX runtime, cross-platform
- Similar bridging pattern to existing whisper.cpp integration (BridgingHeader.h)
- Uses pyannote-segmentation-3-0 + embedding models
- More control over model selection but requires C++ bridging work
- Docs: https://k2-fsa.github.io/sherpa/onnx/speaker-diarization/index.html

### Alternative: Falcon by Picovoice (Commercial)
- https://picovoice.ai/platform/falcon/
- Native C SDK for macOS (x86_64, arm64)
- Claims 5x higher accuracy than cloud APIs
- Has a whisper.cpp integration guide: https://picovoice.ai/blog/whisper-cpp-speaker-diarization/
- Requires paid license (AccessKey)

## Quality: Offline vs Cloud
- 2-4 speakers (typical meetings): offline is competitive (~10% DER)
- 5+ speakers or noisy: cloud still has an edge
- Gap is narrowing fast as of 2025-2026

## Implementation Plan (FluidAudio approach)

### 1. Add FluidAudio dependency
```swift
// Package.swift or Xcode SPM
dependencies: [
    .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "1.0.0")
]
```

### 2. Create DiarizationService
- New file: `Diduny/Core/Services/DiarizationService.swift`
- Swift actor wrapping FluidAudio's SpeakerDiarization
- Input: audio file URL (WAV from meeting recording)
- Output: array of speaker segments with timestamps

```swift
import FluidAudio

actor DiarizationService {
    static let shared = DiarizationService()

    func diarize(audioURL: URL) async throws -> [SpeakerSegment] {
        let diarization = try await SpeakerDiarization()
        return try await diarization.process(audioURL: audioURL)
    }
}

struct SpeakerSegment {
    let speaker: String      // "Speaker 1", "Speaker 2"
    let start: TimeInterval
    let end: TimeInterval
    let text: String?        // filled after alignment with transcription
}
```

### 3. Alignment: merge diarization + transcription
After both whisper transcription and diarization complete:
- For each transcribed word/segment (with timestamps from Whisper):
  - Find which speaker segment overlaps the most
  - Assign that speaker label
- Group consecutive words from the same speaker into utterances
- Produce final text: "Speaker 1: ... \n Speaker 2: ..."

### 4. Integration points in Diduny

| Component | Change |
|-----------|--------|
| `RecordingQueueService` | Add `.transcribeWithDiarization` action |
| `RecordingDetailView` | Toggle or option to enable diarization when processing |
| `Recording` model | Add `diarizedSegments: [SpeakerSegment]?` field |
| `RecordingDetailView` | Display speaker-labeled transcript with colored labels |
| `MeetingRecorderService` | Optionally run diarization after meeting recording stops |
| `TranscriptionSettingsView` | Add diarization on/off toggle in Meeting section |

### 5. Processing pipeline for meetings
1. Meeting recording stops -> save audio file
2. Run transcription (Whisper local or Soniox cloud)
3. Run diarization (FluidAudio, parallel with transcription)
4. Align: merge transcription words with speaker segments
5. Save diarized transcript to recording

### 6. UI for diarized transcript
- Each speaker gets a color label
- Segments displayed as chat-like bubbles or labeled paragraphs
- Copy button produces formatted text with speaker labels

## Implementation Plan (sherpa-onnx approach, if FluidAudio doesn't work)

### 1. Build sherpa-onnx as xcframework
- Similar to `build_whisper_xcframework.sh`
- Build sherpa-onnx C library for macOS arm64 + x86_64
- Create bridging header `SherpaBridge.h`

### 2. Download models
- Segmentation model: `sherpa-onnx-pyannote-segmentation-3-0`
- Embedding model: `3dspeaker_speech_eres2net_base_sv_zh-cn_3dspeaker_16k`
- Bundle models or download on first use (like WhisperModelManager)

### 3. Create DiarizationContext.swift
- Swift actor wrapping sherpa-onnx C API (similar to WhisperContext.swift)
- Initialize with model paths
- Process audio buffer, return speaker segments

## Notes
- Start with FluidAudio — least effort, native Swift, best Apple Silicon perf
- Fall back to sherpa-onnx if FluidAudio has issues (model size, accuracy, API limitations)
- Diarization adds ~30-40 seconds per hour of audio (pyannote-based models)
- Models are ~80-200 MB depending on configuration
- For meetings, diarization can run in parallel with transcription for better UX
