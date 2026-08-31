# Testing

## Automated checks

Use an Apple Silicon Mac with full Xcode 16.2 or later selected.

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

xcodebuild -version
swift --version
swift package resolve
swift test --parallel
scripts/build-app.sh

git diff --check
plutil -lint Resources/Info.plist Resources/Recorder.entitlements
zsh -n scripts/build-app.sh scripts/repair-screen-echo.sh
codesign --verify --deep --strict --verbose=2 dist/Recorder.app
```

The app assembly check should also confirm these bundle files:

```sh
test -x dist/Recorder.app/Contents/MacOS/Recorder
test -x dist/Recorder.app/Contents/MacOS/RecorderDiarizer
test -f dist/Recorder.app/Contents/Info.plist
test -f dist/Recorder.app/Contents/Resources/AppIcon.icns
test -f dist/Recorder.app/Contents/Resources/LICENSE
test -f dist/Recorder.app/Contents/Resources/NOTICE
test -f dist/Recorder.app/Contents/Resources/THIRD_PARTY_NOTICES.md
test -f dist/Recorder.app/Contents/Resources/ThirdPartyLicenses/fastcluster-LICENSE.md
```

## Manual permission matrix

Automated tests cannot grant macOS privacy permissions. Validate each state with a fresh development bundle identity when permission behavior changes.

| Permission state | Expected behavior |
| --- | --- |
| Microphone not determined | Prompt appears before microphone capture |
| Microphone denied | Capture does not start; actionable error appears |
| Camera not determined | Prompt appears before movie capture |
| Camera denied | Movie capture does not start; actionable error appears |
| Screen capture not determined | Setup can request access and explains restart behavior |
| Screen capture denied | Screen/system-audio capture does not start |
| All required permissions granted | Selected capture starts and visible status updates |

Resetting TCC permissions changes local system state. If needed, perform it manually with the bundle identifier documented in `docs/RELEASING.md`, then reopen the app and re-grant access.

## Manual capture matrix

For every capture, verify duration, playback, manifest state, stems, transcript source labels, thumbnail where applicable, and stop behavior from both UI and the matching global shortcut.

- Microphone-only audio
- Microphone plus system-audio meeting
- System-audio-only capture
- Camera with and without microphone
- Entire display
- Individual window
- Selected region
- 24, 30, and 60 fps where offered
- Stop from app, menu bar, and global shortcut
- Attempt a different shortcut while capture is active

Use synthetic speech and a test desktop with no personal notifications, file names, accounts, or private window titles.

## Lifecycle and recovery

- Force-quit during capture; confirm the next launch marks the recording failed and keeps working media.
- Simulate finalization failure; confirm source files remain.
- Start two stop requests nearly simultaneously; confirm finalization runs once.
- Cancel transcription and enhanced diarization; confirm cancellation is not reported as a model crash.
- Remove or corrupt the diarization helper in a disposable build; confirm the ASR result receives stable labels.
- Exercise low-disk handling before capture begins.

## Echo cleanup

- Use a synthetic delayed system-audio leak and confirm cleanup is applied with preserved originals.
- Use unrelated microphone/system tracks and confirm cleanup declines to modify them.
- Reprocess an already-cleaned recording from rollback inputs.
- Confirm rollback cleanup requires explicit opt-in.
- Confirm a failed cleanup leaves playable raw media and an accurate manifest.

## Model and network behavior

- On a clean model cache, confirm the UI describes the download and failures are recoverable.
- After models are valid, disconnect networking and confirm transcription completes.
- Record the exact FluidAudio package revision and model provenance used for release qualification.
- Do not place real model caches in the repository or CI artifacts.

## Release artifact checks

For a Developer ID-signed and notarized artifact, additionally run:

```sh
codesign -d --verbose=4 dist/Recorder.app
codesign -d --entitlements :- dist/Recorder.app
spctl --assess --type execute --verbose=4 dist/Recorder.app
xcrun stapler validate dist/Recorder.app
```

Open the final archive on a second Apple Silicon Mac that has never run a development build. Validate first-launch Gatekeeper, TCC prompts, helper execution, model download, capture, and offline inference.
