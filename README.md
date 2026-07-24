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

## Global recording shortcut

While Recorder is running, press `⌘⌥M` for audio, `⌘⌥N` for the entire screen, or `⌘⌥B` for movie/video from any app. Press the same shortcut again to stop, save, and start local transcription automatically. While one mode is recording, the other mode shortcuts are blocked until capture finishes; the active recording can also be stopped from Recorder's UI or menu-bar menu. The modifier combination and letter for every mode can be changed under **Settings → Global Recording Shortcut**, which prevents duplicate mappings before applying changes. Settings also provides system-audio and microphone options. Shortcut screen and movie recordings default to 1080p at 30 fps and use the preferred internal microphone/camera.

Recorder adds a subtle menu-bar waveform: muted gray with no suffix while idle, then bold with a small `a` for audio, `s` for screen, or `v` for movie/video capture. The menu shows elapsed time and can stop, save, and transcribe the active capture.

Because these are system-wide shortcuts, Recorder reserves the three configured key combinations while it is open; other apps will not receive them during that time.

## Speaker echo cancellation

For compatible audio-only captures, **Echo cancellation: Auto** uses Apple's on-device voice processing to remove speaker playback from the default microphone before the stems are mixed. Automatic gain control is disabled and other-audio ducking is minimized so the local voice and meeting volume remain natural. Screen recording deliberately avoids live voice processing because it can reconfigure Core Audio underneath ScreenCaptureKit, delaying or failing capture. Instead, Auto analyzes representative sections of the completed system and microphone stems, estimates a stable leakage delay, and attenuates the matching system-audio activity in the microphone only when detection confidence is high. The cleaned microphone stem is used for the final movie and transcription. The original movie, audio, and microphone stem are retained as `*.pre-echo-cleanup.*` rollback files; cleanup Settings list them separately and never delete them without explicit opt-in. Detection or processing failures safely retain the raw recording. The recording manifest and Info popover report whether cancellation was actually applied. Set the option to **Off** in Settings to preserve raw microphone audio.

Older screen recordings can be repaired on demand with the same guarded, non-destructive pipeline. Close or leave Recorder idle, then run:

```sh
scripts/repair-screen-echo.sh ~/Movies/Recorder/<recording-folder> --transcribe enhanced --expected-speakers 2
```

The command only accepts completed screen recordings, changes nothing when confidence is insufficient, keeps raw media and the previous transcript as `*.pre-echo-cleanup.*`, and can immediately regenerate the transcript from the cleaned microphone stem.

If a cleaned legacy recording was already transcribed, `--clean-existing-transcript` applies only the conservative time-aligned cross-channel de-duplication pass and preserves the prior files as `transcript.pre-cross-channel-dedup.*`.

Use `--reprocess` to rebuild an already-cleaned recording from its preserved raw
movie and microphone stem after cleanup improvements. The original rollback
files are read-only inputs and are never replaced.

## Recording library

Recorder defaults to `~/Movies/Recorder`. The location can be changed in Settings. Every recording has its own folder containing:

- `recording.mov` or `recording.m4a`
- `audio.m4a` for video transcription
- separate `microphone.m4a` and `system.m4a` stems when available
- `manifest.json`
- `transcript.json` and `transcript.txt`
- a thumbnail for video recordings
- a `working` directory retained if capture or finalization is interrupted

The sidebar can be filtered by any existing tag. **Rename & Tag** offers the current tag list as well as an **Add New Tag…** option; organization links are updated without moving the canonical media folder. Settings also reports disposable library items and provides a confirmed cleanup action. Cleanup excludes active, failed, and recoverable recordings plus all current media, manifests, stems, transcripts, thumbnails, and exports. Preserved pre-echo-cleanup originals are listed separately and are deleted only when explicitly selected.

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
