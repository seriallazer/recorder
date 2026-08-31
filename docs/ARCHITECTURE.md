# Architecture

Recorder is a Swift Package containing a SwiftUI application, a reusable core module, and two command-line helpers. The design keeps capture, media transformation, storage, and machine-learning failures in separate domains.

## Component map

```text
RecorderApp (SwiftUI, settings, menu bar, global shortcuts)
       |
       v
RecordingCoordinator ---------> RecordingLibrary
       |                              |
       |                              +--> manifest.json / local media / transcript
       |
       +--> AudioCaptureService ------+
       +--> CameraCaptureService -----+--> working media and optional stems
       +--> ScreenCaptureService -----+
                                      |
                                      v
                              MediaFinalizer
                                      |
                         ScreenEchoCleanup (guarded)
                                      |
                                      v
                         LocalTranscriptionService
                            |                 |
                            v                 v
                    FluidAudio ASR    RecorderDiarizer helper
                                             |
                                      stable-label fallback
```

`RecorderEchoRepair` is a source-checkout command-line utility that applies the guarded screen-echo repair service to an existing completed recording.

## Targets

- **RecorderApp** owns SwiftUI views, Settings, menu-bar UI, and global hot-key registration.
- **RecorderCore** owns domain models, capture services, lifecycle coordination, local storage, media finalization, echo processing, transcription planning, and testable policies.
- **RecorderDiarizer** isolates offline speaker-model execution in a child process.
- **RecorderEchoRepair** validates and repairs a completed screen recording from the command line.

## Recording lifecycle

A `RecordingManifest` records the state transition:

```text
idle -> previewing -> recording -> finalizing -> ready
                                      |           |
                                      v           v
                                    failed   transcribing -> ready
                                                  |
                                                  v
                                                failed
```

The coordinator creates a canonical recording folder and `working` directory before capture. The active recording is published immediately so every UI control sees the same state. Finalization copies or transforms source artifacts into stable paths, updates the manifest atomically, and removes the working directory only after success.

On launch, manifests left in an active state are marked failed rather than deleted. Recoverable source files remain available in the working directory.

## Capture paths

- Audio capture can retain separate microphone and system stems and create a playable mix.
- Camera capture normalizes host-clock microphone timestamps onto the movie timeline before writing.
- Screen capture uses ScreenCaptureKit for display, window, or region frames and optional system audio. Microphone audio is captured independently when enabled.

Permission checks happen before the selected capture service starts. Capture services report late failures back to the coordinator so the manifest and working media remain coherent.

## Echo cleanup

Compatible audio-only recordings can use Apple's voice-processing audio unit during capture. Screen recording deliberately avoids this live path because Core Audio reconfiguration can interfere with ScreenCaptureKit.

For screen recordings, the post-capture cleanup pipeline:

1. Samples representative sections of microphone and system stems.
2. Estimates leakage delay and confidence.
3. Declines to modify media when evidence is insufficient.
4. Preserves original movie, microphone stem, and transcript as `*.pre-echo-cleanup.*` files.
5. Applies attenuation only around matching system-audio activity.
6. Rebuilds final media and optionally regenerates the transcript.

Rollback files are immutable inputs during reprocessing and require explicit opt-in for cleanup.

## Transcription and speaker attribution

`LocalTranscriptionService` plans one or more tracks based on available stems and selected speaker mode. Parakeet ASR runs serially to limit memory pressure. Separate microphone/system tracks receive stable source labels and are merged by time.

Enhanced speaker processing runs in `RecorderDiarizer`. The parent process supplies an input path and temporary result path, discards helper output on failure, and falls back to stable labels while preserving the ASR transcript. Cancellation terminates the helper and remains cancellation rather than being misclassified as model failure.

## Storage model

`RecordingLibrary` owns canonical folders and atomic manifest writes. Human-readable organization paths are symbolic links; canonical media does not move when a title or tag changes. Path normalization and relative-path checks prevent organization links from escaping the selected library root.

Cleanup distinguishes disposable temporary items from rollback media and ignores active, failed, and recoverable recordings.

## Trust boundaries

- macOS provides camera, microphone, and ScreenCaptureKit permission enforcement.
- Recorder trusts the user-selected filesystem location and does not encrypt it.
- FluidAudio owns runtime model download and cache behavior.
- The diarization helper is a crash-containment boundary, not a security sandbox.
- The local build is ad-hoc signed; public binary trust requires Developer ID signing and notarization.
