# Third-Party Notices

Recorder uses the following open-source software and models. Model files are downloaded directly to the user's Mac on first use and are not redistributed in this repository or the application bundle.

## FluidAudio

Copyright FluidInference contributors.

- Source: <https://github.com/FluidInference/FluidAudio>
- Pinned package version: `0.15.5`
- Pinned source revision: `19600a485baa4998812e4654b70d2bab8f2c9949`
- License: Apache License 2.0

The complete Apache License 2.0 text is included in the repository's root `LICENSE` file and copied into distributed application bundles.

FluidAudio includes or derives implementation from components used by its offline diarization pipeline:

- **fastcluster**, copyright Daniel Müllner and Google Inc., BSD 2-Clause License. The complete terms are in `ThirdPartyLicenses/fastcluster-LICENSE.md`.
- **VBx**, by BUT Speech@FIT contributors, Apache License 2.0. The complete Apache License 2.0 terms are in the root `LICENSE` file. Upstream source: <https://github.com/BUTSpeechFIT/VBx>.

## NVIDIA Parakeet TDT 0.6B v2 / FluidInference Core ML conversion

Used for English automatic speech recognition.

- Model: <https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v2-coreml>
- Base model: NVIDIA Parakeet TDT 0.6B v2
- Core ML conversion and Swift integration: FluidInference contributors
- License: Creative Commons Attribution 4.0 International (`CC-BY-4.0`)
- License terms: <https://creativecommons.org/licenses/by/4.0/legalcode>

The downloaded artifact is a Core ML conversion of the upstream NVIDIA model. Recorder does not modify or redistribute the model files.

## FluidInference Speaker Diarization Core ML Models

Used for optional offline speaker diarization.

- Model: <https://huggingface.co/FluidInference/speaker-diarization-coreml>
- Based on: pyannote speaker segmentation, WeSpeaker embeddings, and VBx speaker clustering
- Core ML conversion: FluidInference contributors
- License: Creative Commons Attribution 4.0 International (`CC-BY-4.0`), as documented by the model publisher
- License terms: <https://creativecommons.org/licenses/by/4.0/legalcode>

Relevant research citations are maintained in the upstream model card linked above. Recorder does not modify or redistribute the model files.

The original projects, model creators, and authors retain all rights granted by their respective licenses. These notices preserve attribution and do not replace or modify the upstream license terms.
