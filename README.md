# meeting-recorder

macOS meeting recorder with Polish transcription and speaker diarization. Captures system audio + mic, transcribes locally with Whisper.cpp, identifies speakers with pyannote, and extracts requirements from Polish transcripts.

## Install

```bash
git clone git@github.com:jborkowski/meeting-recorder.git
cd meeting-recorder
swift build -c release
sudo cp .build/arm64-apple-macosx/release/meeting-recorder /usr/local/bin/
```

## Dependencies

```bash
brew install blackhole-16ch whisper-cpp
```

After installing BlackHole, restart CoreAudio:

```bash
sudo killall coreaudiod
```

Set BlackHole as your meeting app's audio output (Google Meet/Zoom/Teams → Settings → Audio → BlackHole 16ch).

## HF_TOKEN (diarization only)

Diarization uses pyannote models, which require a HuggingFace token:

1. Create a free account at https://huggingface.co/join
2. Generate a token at https://huggingface.co/settings/tokens
3. Accept the license for both gated models:
   - https://huggingface.co/pyannote/speaker-diarization-3.1 (click "Agree and access repository")
   - https://huggingface.co/pyannote/segmentation-3.0 (click "Agree and access repository")
4. Export the token:

```bash
export HF_TOKEN=hf_...
```

## Usage

### One-shot recording

```bash
# Mono (better for transcription + diarization)
meeting-recorder capture --duration 1800 --mono

# Stereo (mic=left, system=right — only useful for 2-person calls)
meeting-recorder capture --duration 1800
```

### Auto-capture daemon

Monitors BlackHole audio levels and auto-records when a meeting starts:

```bash
meeting-recorder daemon
```

Configurable thresholds:

```bash
meeting-recorder daemon --start-threshold -35 --start-window 1.5 --stop-threshold -55 --stop-window 45
```

### Transcription

First run auto-downloads the Whisper model (~3GB, one-time):

```bash
meeting-recorder transcribe --input meeting.wav
```

Output: `meeting.md` with Polish transcription and timestamps.

### Speaker diarization

First run downloads pyannote models (~1GB, one-time):

```bash
meeting-recorder diarize --input meeting.wav --token hf_...
```

Output: `meeting.speakers.json` with `[{start, end, speaker}, ...]`.

### Requirements extraction

Extracts Wymagania (Requirements), Akcje (Action Items), and Decyzje (Decisions) from Polish transcripts:

```bash
meeting-recorder process --input meeting.md
```

### Full pipeline

```bash
meeting-recorder capture --duration 1800 --mono
meeting-recorder transcribe --input ~/MeetingRecordings/2026-05-05_213632.wav
meeting-recorder diarize --input ~/MeetingRecordings/2026-05-05_213632.wav
meeting-recorder process --input ~/MeetingRecordings/2026-05-05_213632.md
```

### List audio devices

```bash
meeting-recorder capture --list-devices
```

## Models

| Model | Size | Location |
|-------|------|----------|
| Whisper large-v3 | ~3GB | `~/Library/Application Support/com.meetingrecorder/Models/ggml-large-v3.bin` |
| pyannote 3.1 | ~1GB | uv cache (`~/.cache/uv/`) |

## Privacy

Everything runs locally. No audio leaves your machine. Transcription and diarization are offline. The only network egress is model download (one-time) and optional Google Docs upload (not yet implemented).
