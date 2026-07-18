# TODO Improvements

## Good to have: speaker attribution editing and evaluation

The two-party baseline is channel-based attribution: microphone audio and system audio are captured and transcribed separately, then merged chronologically. Enhanced offline diarization is available for mixed tracks and panels, with isolated-process crash containment and stable fallback.

- Add transcript controls for manually renaming and merging detected speakers.
- Add a small labeled evaluation set and report diarization error rate for one-on-one interviews, panels, speaker bleed, and overlap.
- Explore voice enrollment so mixed recordings can identify `You` without relying on speaker-duration heuristics.

Keep channel attribution as the fallback whenever diarization is unavailable, unstable, or low confidence.
