# Recorder

A native macOS recorder with local transcription, guarded echo cleanup, and crash-isolated speaker diarization.

Recorder captures microphone audio, separate microphone and system-audio meeting stems, camera video, or a display, window, or region. Recordings remain under the user's control in a local library. After the required Core ML models have been downloaded, transcription and speaker processing run on the Mac.

> Recorder is currently distributed as source. The local build is ad-hoc signed for development and is not a notarized public binary.

## Highlights

- Native SwiftUI interface for audio, camera, and ScreenCaptureKit recording.
- Separate microphone and system-audio stems when the capture mode supports them.
- Fully local English transcription after the initial model download.
- Automatic, stable, and enhanced speaker-attribution modes.
- Speaker diarization in an isolated helper process so a native model failure cannot terminate Recorder or discard the ASR result.
- Confidence-gated screen-echo cleanup with preserved rollback media.
- Crash-recoverable recording state, non-destructive trimming, tags, and storage cleanup.
- Configurable global shortcuts and a visible menu-bar recording indicator.

## Privacy at a glance

Recorder contains no upload, analytics, advertising, or telemetry implementation. Network access is used by FluidAudio to download missing or damaged model artifacts from Hugging Face. Inference uses local Core ML models after they are present on disk.

Recordings, stems, thumbnails, manifests, and transcripts are stored unencrypted in the selected local library. They may contain highly sensitive information; users are responsible for protecting the library and obtaining any consent required to record other people.

See [PRIVACY.md](PRIVACY.md) for the data flow, storage locations, permissions, and dependency boundary.

## Requirements

- Apple Silicon Mac running macOS 14 or later.
- A build Mac running macOS 14.5 or later.
- Full Xcode 16.2 or later with its tools selected.
- Internet access for the first package build and initial model downloads.

Select Xcode if necessary:

```sh
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
sudo xcodebuild -runFirstLaunch
```

## Build and run

```sh
scripts/build-app.sh
open dist/Recorder.app
```

The script builds an Apple-Silicon release app, copies its notices and resources, signs nested helpers, and ad-hoc signs the app for local use. Rebuilding with the default bundle identifier retains a stable local Screen Recording identity. See [docs/RELEASING.md](docs/RELEASING.md) before distributing a binary.

## Permissions

Recorder requests only the permissions needed by the chosen capture mode:

| Permission | Used for |
| --- | --- |
| Microphone | Audio, movie, and optional screen microphone capture |
| Camera | Movie capture |
| Screen & System Audio Recording | Display/window/region video and optional system-audio capture |

If macOS asks Recorder to quit after Screen & System Audio Recording access is granted, reopen `dist/Recorder.app`. Global shortcuts use the macOS hot-key API and do not require Accessibility permission.

## Recording shortcuts

The defaults are:

- `⌘⌥M` — start or stop audio recording
- `⌘⌥N` — start or stop full-screen recording
- `⌘⌥B` — start or stop movie recording

Shortcuts, recording devices, system audio, and microphone behavior can be changed in Settings. While one mode is active, other recording shortcuts are blocked until capture finishes. The menu-bar waveform and in-app status remain visible during capture.

## Speaker attribution and echo cleanup

For two-channel meetings, microphone and system audio are transcribed separately and merged chronologically. Enhanced diarization is reserved for mixed or multi-speaker tracks. It runs in `RecorderDiarizer`, a separate helper process with a stable fallback if the model fails.

Audio-only echo cancellation uses Apple's on-device voice processing where compatible. Screen recording avoids live audio-device reconfiguration; after capture, Recorder samples the preserved microphone and system stems, estimates leakage delay, and applies cleanup only when confidence is high. Original files are retained as `*.pre-echo-cleanup.*` rollback media.

The source-checkout repair utility can reprocess older completed screen recordings:

```sh
scripts/repair-screen-echo.sh ~/Movies/Recorder/<recording-folder> \
  --transcribe enhanced --expected-speakers 2
```

This utility currently requires a source checkout and full Xcode; it is not included in the app-only bundle.

## Recording library

The default library is `~/Movies/Recorder`; it can be changed in Settings. Each canonical recording folder may contain:

- `recording.mov` or `recording.m4a`
- `audio.m4a` for video transcription
- `microphone.m4a` and `system.m4a` stems when available
- `manifest.json`
- `transcript.json` and `transcript.txt`
- a video thumbnail
- a recoverable `working` directory if capture or finalization was interrupted

Tag organization uses links without moving the canonical recording folder. Cleanup excludes active, failed, and recoverable recordings and requires separate opt-in before deleting rollback originals.

## Models and reproducibility

The Swift package dependency is pinned to FluidAudio `0.15.5` and source revision `19600a485baa4998812e4654b70d2bab8f2c9949`. Runtime model repositories are requested from Hugging Face by FluidAudio and are not revision- or checksum-pinned by Recorder, so model bytes may change independently of this source revision.

The English Parakeet TDT v2 model is downloaded for transcription. Auto or Enhanced speaker attribution additionally downloads the offline diarization models. Model files are stored by FluidAudio under `~/Library/Application Support/FluidAudio/Models`.

See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for software, model, and research attribution.

## Architecture

Recorder separates UI, capture, finalization, storage, and ML failure domains. See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the component map, recording lifecycle, artifact handling, and fallback design.

## Tests

```sh
swift test --parallel
```

The test suite covers capture timelines, finalization, library recovery, metadata, thumbnails, shortcut policy, transcription planning, speaker alignment, echo detection, guarded cleanup, and helper-process failure handling. Hardware capture and macOS privacy flows require manual validation; see [docs/TESTING.md](docs/TESTING.md).

## Project documentation

- [Architecture](docs/ARCHITECTURE.md)
- [Privacy](PRIVACY.md)
- [Testing](docs/TESTING.md)
- [Releasing](docs/RELEASING.md)
- [Contributing](CONTRIBUTING.md)
- [Security policy](SECURITY.md)
- [History-sanitization plan](docs/HISTORY-SANITIZATION.md)
- [Changelog](CHANGELOG.md)

## License

Recorder is licensed under the [Apache License 2.0](LICENSE). Third-party software and models retain their respective licenses; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
