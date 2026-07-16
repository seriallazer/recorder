# Recorder

A native macOS 14+ recorder with fully local English transcription and speaker diarization. It records microphone audio, camera video, or a display/window/region with optional system audio and microphone stems.

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

On first use, macOS requests camera and microphone access as needed. Screen recording access is requested only when you press **Request Screen Recording Access** in the screen-recording setup. If macOS asks you to quit the app after granting access, reopen `dist/Recorder.app`.

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

FluidAudio 0.15.5 is pinned exactly for reproducible builds. The first transcription downloads and validates the English Parakeet TDT v2 Core ML model and the offline diarization models. Later transcriptions use the local cache.

Third-party attribution and model-license details are recorded in `THIRD_PARTY_NOTICES.md` and copied into the app bundle.

## Tests

```sh
swift test
```

Hardware capture and macOS permission flows require manual validation because automated tests cannot grant privacy permissions.
