# TODO Improvements

## Good to have: enhanced screen-recording diarization

The current two-party baseline remains channel-based attribution: microphone audio and system audio are captured and transcribed separately, then merged chronologically. Keep the existing channel names unchanged.

- Detect and mark overlapping speech when microphone and system-audio transcript segments intersect.
- Optionally run offline multi-speaker diarization on the system-audio stem when multiple remote voices are suspected.
- Fall back to the existing channel attribution whenever diarization is unavailable, unstable, or low confidence; diarization failure must never fail transcription.
- Add transcript controls for manually renaming and merging detected speakers.

Revisit after the core recording and transcription flows are stable. Validate with one-on-one interviews, panel interviews, overlapping speech, speaker bleed, and diarizer failure cases.
