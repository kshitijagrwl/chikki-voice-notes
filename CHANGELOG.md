# Changelog

## v0.2 — 2026-05-12

### Added
- **Speaker diarization** (#1) — `pyannote-audio` runs on Apple Silicon MPS, aligns turns with Whisper segments via O(n+m) interval sweep. Anonymous `Speaker A / B / C` labels in the transcript and notes. Requires `HF_TOKEN` in `.env` and accepting the `pyannote/speaker-diarization-3.1` EULA on Hugging Face. CLI: `--diarize/-d` on `record`, `quick`, `transcribe`, `reprocess`. Config: `diarization.enabled`, `min_speakers`, `max_speakers`.
- **Speaker identification** (#1) — enroll recurring speakers and Chikki matches them by embedding cosine similarity. CLI: `enroll <name> <audio.wav>`, `speakers`, `unenroll <name>`. Registry at `speakers/registry.json` with per-speaker `.npy` embeddings (gitignored). Config: `diarization.identify`, `match_threshold`.
- **System audio capture** (#2) — new Swift `chikki-syscap` helper using ScreenCaptureKit captures the other side of Zoom/Meet/Slack calls. Mic + system mixed to mono for transcription; stereo archive (L=mic, R=system) saved alongside. Falls back to mic-only on missing binary or denied permission. Config: `recording.system_audio`, `recording.mix_mode`.
- **Hinglish transliteration fix** (#5) — single combined Gemini Flash prompt corrects English-Hindi code-switching artifacts before extracting structured notes. No extra API call. Config: `processing.fix_hinglish` (default on).
- **Calendar auto-record** (#10) — EventKit watcher polls every 30s for upcoming meetings with Zoom/Meet/Teams/Webex URLs. 10s pre-roll notification with Cancel; auto-stops at `endDate + trailing_buffer_sec`. Config: `calendar.auto_record_enabled`, `lead_time_sec`, `trailing_buffer_sec`, `require_conf_link`.
- **Settings window** (#11) — dedicated SwiftUI Settings scene with sidebar nav: General, Recording, Transcription, Diarization, Processing, Calendar, Shortcuts, Permissions, About. Reads/writes `config.yaml` via Yams, preserving unknown keys. Permissions pane surfaces Mic / Screen Recording / Calendar / Accessibility status with deep-links to System Settings.

### Changed
- **Prompts split**: `prompts.json` → `prompts/meetings.json` (meeting-type templates) and new `prompts/pipeline.json` (pipeline-stage fragments).
- **Menubar dropdown** reduced to Start/Stop, processing status, last-note preview, upcoming-meeting countdown, Open Settings, Quit. All configuration moved into the Settings window.
- **MenuBarExtra** now uses `.window` style — fixes the timer redraw stealing hover focus and makes the Settings shortcut work reliably.
- **Transcript outputs** include `[Speaker A]:` line prefixes (in `*.txt`) and a `speaker` key per segment (in `*.json`) when diarization is enabled. Output unchanged when off.

### Fixed
- Long note titles no longer balloon the menubar panel horizontally — fixed-width panel with vertical text wrapping.
- Menubar rows render as flat menu items, not embossed buttons.

### Internal
- New module `src/diarizer.py` (pyannote pipeline + alignment).
- New module `src/speaker_db.py` (embedding registry + cosine match).
- New Swift sources: `SystemAudioCaptureCLI/main.swift`, `CalendarWatcher.swift`, `ConfigStore.swift`.
- `environment.yml` adds `pyannote.audio` and `torch`.
