# Changelog

## [0.0.1.0] - 2026-05-05

### Added
- CLI binary `meeting-recorder capture` for Phase 0 audio capture proof
- `--duration` flag to control recording length
- `--output` flag to specify WAV output path
- `--list-devices` flag to enumerate available audio devices
- Stereo 16kHz 16-bit WAV output compatible with Whisper.cpp
- BlackHole virtual audio device detection
- CoreAudio aggregate device enumeration

### Changed
- Initial project setup with Swift Package Manager
- ArgumentParser integration for structured CLI interface
