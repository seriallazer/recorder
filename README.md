# Recorder

A native macOS 14+ recorder with fully local English transcription and optional speaker diarization. It records microphone audio, audio-only meetings with separate system and microphone stems, camera video, or a display/window/region.

## Requirements

- Apple Silicon Mac running macOS 14 or later
- A build Mac running macOS 14.5 or later
- Full Xcode 16.2 or later with its tools selected (`sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`)
- Internet access for the first build and the first local-model download

The finished app does not require Xcode. Recordings never leave the Mac, and model inference makes no network requests after the initial model download.

## Build

```sh
chmod +x scripts/build-app.sh
scripts/build-app.sh
open dist/Recorder.app
```

If the Mac is still on macOS 14.4, update macOS before installing Xcode. Apple requires macOS 14.5 or later for Xcode 16.x, which supplies the Swift 6 toolchain required by FluidAudio.

On first use, macOS requests camera and microphone access as needed. Screen & System Audio Recording access is needed for screen recording and for the optional **Record meeting/system audio** toggle in audio mode. If macOS asks you to quit the app after granting access, reopen `dist/Recorder.app`.

Local builds use a stable designated requirement for `local.recorder.app`, so rebuilding the same app does not create a new Screen Recording identity. When upgrading from an older build that used a code-hash identity, remove the old Recorder entry from Privacy & Security → Screen & System Audio Recording once, reopen the newly built app, and grant access again. Later rebuilds retain that identity.

## Recording library

Recorder defaults to `~/Movies/Recorder`. The location can be changed in Settings. Every recording has its own folder containing:

- `recording.mov` or `recording.m4a`
- `audio.m4a` for video transcription
- separate `microphone.m4a` and `system.m4a` stems when available
- `manifest.json`
- `transcript.json` and `transcript.txt`
- a thumbnail for video recordings
- a `working` directory retained if capture or finalization is interrupted

## Local models

FluidAudio 0.15.5 is pinned exactly for reproducible builds. The first transcription downloads and validates the English Parakeet TDT v2 Core ML model. Auto or Enhanced mode downloads the offline speaker models on first use; later runs use the local cache.

Speaker attribution defaults to **Auto**. For long mixed recordings, Auto analyzes eight 20-second sections distributed across the timeline, ignores tiny outlier clusters, and selects stable labels for one meaningful voice or full enhanced diarization for multiple voices. Short recordings are analyzed in full. Separate microphone and system-audio stems remain preferred and Auto samples only the remote channel when deciding whether a panel needs additional separation.

**Stable** and **Enhanced** remain available as global settings and per-recording overrides. Enhanced diarization runs in a separate `RecorderDiarizer` helper process with a one-item Core ML batch on memory-constrained Macs. A native model crash or ordinary inference error cannot terminate Recorder or discard the ASR result: transcription automatically falls back to stable single-track/channel labels and records the decision or fallback in the transcript.

Third-party attribution and model-license details are recorded in `THIRD_PARTY_NOTICES.md` and copied into the app bundle.

## Tests

```sh
swift test
```

Hardware capture and macOS permission flows require manual validation because automated tests cannot grant privacy permissions.
