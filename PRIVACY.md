# Privacy

Recorder is designed as a local-first recording and transcription tool. This document describes the behavior implemented by this repository and the external dependency boundary.

## Data flow

1. Recorder captures a selected microphone, camera, display, window, region, or system-audio stream.
2. Capture services write temporary media into the recording's local `working` directory.
3. Finalization creates local media and optional separate microphone/system stems.
4. FluidAudio loads local Core ML models and produces transcript or speaker-segment results on the Mac.
5. Recorder writes the transcript, thumbnail, and manifest into the same local recording folder.

Recorder does not implement media or transcript upload, analytics, advertising, account login, or telemetry.

## Network access

FluidAudio downloads missing model files from Hugging Face. It may also re-download a model cache that it determines is incomplete or unusable. The package supports an operator-supplied model registry or network proxy through inherited environment variables; Recorder does not expose those settings in its UI.

Recorder pins the FluidAudio source dependency, but it does not currently pin or independently verify the revision or SHA-256 digest of downloaded model artifacts. See `README.md` for the reproducibility boundary.

Outside FluidAudio model acquisition and cache recovery, Recorder's source implements no network path for capture, playback, transcript rendering, export, or inference.

## Local storage

The default recording library is `~/Movies/Recorder`. Users can choose another folder. Recordings are stored unencrypted and can include:

- camera, screen, microphone, and system audio
- preserved pre-cleanup media
- transcripts and speaker labels
- thumbnails
- titles, tags, timestamps, and error messages
- selected device identifiers, display/window identifiers, capture region, and encoding settings in `manifest.json`

FluidAudio stores downloaded model artifacts under `~/Library/Application Support/FluidAudio/Models`.

UserDefaults stores shortcut and processing preferences, the selected library path, and a security-scoped bookmark when one can be created.

## Permissions

- **Microphone** is requested only for a configuration that captures microphone audio.
- **Camera** is requested only for movie capture.
- **Screen & System Audio Recording** is requested for ScreenCaptureKit video or system-audio capture.
- Global shortcuts use the macOS hot-key API and do not require Accessibility access.

Permission denial is surfaced as an error; Recorder does not attempt to bypass macOS privacy controls.

## Retention and deletion

Recorder retains canonical media and transcripts until the user deletes a recording. Temporary cleanup is conservative and excludes active, failed, and recoverable recordings. Pre-echo-cleanup originals require a separate explicit opt-in before deletion.

Deleting files in Recorder is a local filesystem operation. Existing backups, filesystem snapshots, or synced-folder copies remain governed by the user's storage configuration.

## Recording consent

The menu-bar indicator and app state show when Recorder is capturing, but they do not replace consent. Users are responsible for complying with workplace policies and all laws governing audio, video, screen, and meeting recording.

## Scope

This policy covers Recorder source at the checked-out revision. It does not make guarantees for modified builds, operating-system behavior, upstream package changes, model-hosting services, or third-party backup and synchronization software.
