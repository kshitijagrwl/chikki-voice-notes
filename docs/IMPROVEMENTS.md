# Improvements & Roadmap

Architectural bottlenecks, planned improvements, and ideas for the Granola voice pipeline.
Last updated: 2026-03-21

---

## Critical (Will hit within weeks of regular use)

### 1. Speaker Diarization
**Problem**: Multi-person meetings produce a single text stream. Action items can't be attributed to speakers. Gemini has to guess who said what.
**Impact**: Meeting notes from group calls are significantly less useful without speaker labels.
**Options**:
- `pyannote-audio` — best open-source diarization, needs HuggingFace token, GPU-friendly
- `NeMo MSDD` (NVIDIA) — multi-scale diarization, pairs well with Parakeet
- Apple SpeechAnalyzer (macOS 26+) — may include speaker segmentation natively (TBD)
**Effort**: Medium. Post-transcription step, needs segment alignment with transcript.

### 2. System Audio Capture
**Problem**: Currently mic-only. For Zoom/Meet/Slack calls, need to capture what others are saying too.
**Impact**: Can only transcribe your side of remote meetings.
**Options**:
- `BlackHole` (virtual audio driver) — creates a loopback device, combine with mic via aggregate device
- `ScreenCaptureKit` (macOS 13+) — native API for system audio, but Python bindings (PyObjC) are unreliable on macOS 15+
- Swift helper binary using ScreenCaptureKit — most reliable path, called from Python
**Effort**: Medium. BlackHole is quick but requires user setup. Swift helper is robust but needs compilation.

### 3. Long Recording Chunking
**Problem**: Whisper processes in 30s windows internally. For 2+ hour recordings, memory pressure grows and transcription accuracy drifts (hallucinations at segment boundaries).
**Impact**: Long meetings produce garbled sections, especially near the end.
**Options**:
- Explicit chunking with 5s overlap + segment deduplication
- VAD-based splitting (split on silence) before transcription
- Parakeet handles long-form better natively (CTC architecture, no windowing)
**Effort**: Low-Medium. VAD split is straightforward with `silero-vad` or `webrtcvad`.

---

## Important (Will matter at scale)

### 4. Audio Preprocessing Pipeline
**Problem**: Raw mic audio goes straight to transcription. Background noise, varying levels, compression artifacts from calls all degrade accuracy.
**Impact**: 5-15% WER degradation in noisy environments.
**Options**:
- **macOS Voice Isolation** — `AUVoiceIO` audio unit provides neural noise suppression, echo cancellation, and AGC. Available on Apple Silicon + macOS 13+. This is what FaceTime/Zoom use. Can be accessed via a small Swift/ObjC helper.
- **macOS Mic Modes** — `AVCaptureDevice.MicrophoneMode.voiceIsolation` applies system-level voice isolation. User can enable it in Control Center, or we can hint at it.
- `noisereduce` Python library — spectral gating, simple but effective for stationary noise
- `demucs` (Meta) — neural source separation, can isolate vocals from background
**Recommendation**: Leverage macOS Voice Isolation first (it's free, hardware-optimized, already running). Add `noisereduce` as a fallback for imported files that weren't recorded on Mac.
**Effort**: Low for mic mode hint, Medium for AUVoiceIO integration.

### 5. Hindi-English Code-Switching
**Problem**: Standard Whisper drops Hindi words or romanizes them incorrectly in mixed conversations ("humein" becomes "who may", "karna hai" becomes "gonna high").
**Impact**: Common in Indian workplace conversations. Makes transcripts unreliable for the exact people this tool is built for.
**Options**:
- `ai4bharat/indicwhisper` (already integrated) — trained on Indian language data
- `ai4bharat/indic-conformer-600m-multilingual` — newer, supports 22 languages
- Language detection per segment — auto-switch between Whisper (English) and IndicWhisper (mixed)
- Post-processing with Gemini — "fix transliteration errors in this transcript given it's from an Indian English speaker"
**Effort**: Low (already have engine switching). Medium for auto-detection.

### 6. Semantic Search Across Notes
**Problem**: After 50+ voice notes, finding "that thing about the auth refactor from last Tuesday" is impossible without reading every file.
**Impact**: Grows linearly worse with usage. The archive becomes a graveyard.
**Options**:
- Local embedding model (e.g., `nomic-embed-text` via MLX) + `sqlite-vss` or `ChromaDB`
- Integrate with openclaw's `memosyne` plugin (already enabled)
- Simple: TF-IDF index over note text files with `whoosh` or `tantivy`
**Effort**: Medium. The memosyne integration path is probably shortest.

---

## Important (Will matter at scale)

### 11. Dedicated Settings Window
**Problem**: The menubar dropdown is overflowing as features grow (recording, transcription, diarization, processing, calendar, shortcuts, permissions). It's not a viable surface for configuration.
**Impact**: New features (diarization enrollment, system audio toggles, calendar filters) need real form UI and permission-state surfacing.
**Options**:
- Native SwiftUI `Settings` scene in the existing `menubar/` app, reading/writing `config.yaml` via `Yams`
- Sidebar nav like Docker Desktop: General, Recording, Transcription, Diarization, Processing, Calendar, Shortcuts, Permissions, About
- Menubar reduced to Start/Stop/last-status/Open Settings/Quit
**Effort**: Medium. Scaffold + General/Permissions panes is one PR; each feature pane lands with its feature.

---

## Nice-to-Have (Quality of life)

### 7. Apple SpeechAnalyzer as 4th Engine
**Problem/Opportunity**: Apple's new SpeechAnalyzer (WWDC25, macOS 26+) is fully on-device, auto-updating, handles long-form audio, and optimized per hardware model. Zero model download, zero memory overhead (runs outside app process).
**Impact**: Could be the zero-config default for English transcription.
**Integration path**: Swift CLI helper that takes an audio file, returns JSON transcript. Called from Python like any subprocess. The `hear` CLI tool (github.com/sveinbjornt/hear) already wraps the older SFSpeechRecognizer — similar pattern for SpeechAnalyzer.
**Blocker**: Requires macOS 26 (currently in beta). SpeechAnalyzer is Swift-only API.
**Effort**: Low once macOS 26 ships. Write a ~50 line Swift CLI, call from Python.

### 8. Streaming/Real-Time Transcription
**Problem**: Currently batch — record, then transcribe. For long meetings, you wait.
**Options**:
- Chunked pipeline: process 30s windows while still recording
- Parakeet MLX is fast enough for near-realtime on Apple Silicon
- SpeechAnalyzer supports true streaming with volatile + finalized results
**Effort**: High. Requires rearchitecting the recorder to emit chunks.

### 9. Meeting Type Templates
**Problem**: A standup, a 1-on-1, and a brainstorm need different extraction prompts.
**Options**:
- Config-based prompt templates keyed by meeting type
- Auto-detect meeting type from first 60s of transcript
- CLI flag: `--type standup`, `--type brainstorm`, `--type interview`
**Effort**: Low. Just prompt variants in config.

### 10. Automatic Recording Triggers
**Problem**: Forgetting to hit record.
**Options**:
- Calendar integration — auto-record when a meeting starts (detect Zoom/Meet opening)
- Audio detection — start recording when voice is detected after silence
- Cron-based scheduled recordings
**Effort**: Medium. Calendar integration needs AppleScript or EventKit.

---

## macOS Native Capabilities to Leverage

These are "free" improvements we get from the OS — no third-party models needed.

| Capability | API | What it does | How to use |
|---|---|---|---|
| **Voice Isolation** | `AVCaptureDevice.MicrophoneMode` | Neural noise suppression, isolates voice from background | User enables in Control Center, or Swift helper sets it |
| **Echo Cancellation** | `AUVoiceIO` | Removes echo from speakers feeding back into mic | Swift audio unit, pre-process before recording |
| **Auto Gain Control** | `AUVoiceIO` | Normalizes volume across speakers at different distances | Same as above |
| **On-device STT** | `SpeechAnalyzer` (macOS 26+) | Apple's own transcription, auto-updates, zero setup | Swift CLI helper, ~50 lines |
| **System Audio** | `ScreenCaptureKit` | Capture audio from any app (Zoom, Meet, etc.) | Swift helper, reliable path |
| **Dictation** | System Dictation | Already handles noise well, uses Apple's models | Can use `hear` CLI as quick fallback |

### Quick Win: Voice Isolation Hint
The simplest improvement is to detect if Voice Isolation is enabled and suggest it if not:
```python
# In recorder.py, on start:
# "Tip: Enable Voice Isolation in Control Center > Mic Mode for best results"
```
This gives us Apple's neural noise cancellation for free — no code, no model, no latency.
