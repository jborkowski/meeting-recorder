# Changelog

## [0.0.1.0] - 2026-05-05

### Added
- `capture` subcommand — dual-source stereo WAV recording (mic + system audio)
- `daemon` subcommand — VAD-based auto-capture with configurable dBFS thresholds
- `transcribe` subcommand — Whisper.cpp integration for local Polish transcription
- `process` subcommand — Polish keyword heuristics extraction (Wymagania/Akcje/Decyzje)
- `--list-devices` flag to enumerate available CoreAudio devices
- BlackHole virtual audio device detection and multi-device capture

### Changed
- Initial project setup with Swift Package Manager
- ArgumentParser integration for structured CLI interface
