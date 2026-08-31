# Security Policy

## Supported versions

Security fixes are applied to the latest revision on the default branch. No long-term support release line is currently maintained.

## Reporting a vulnerability

Do not include sensitive recordings, transcripts, credentials, private file paths, or exploit details in a public issue.

Use GitHub's private vulnerability reporting feature when it is enabled for the repository. If private reporting is unavailable, open a public issue containing only a minimal, non-sensitive request for a private contact channel.

Include the affected revision, macOS and Xcode versions, reproduction conditions, and expected impact. Use synthetic media wherever possible.

## Security boundaries

- Recorder is a local desktop application and does not provide authentication or multi-user isolation.
- The recording library is not encrypted by Recorder. Filesystem permissions, FileVault, backups, and sync tools are controlled by the user and operating system.
- Model artifacts are downloaded by FluidAudio from an external registry and are not currently independently checksum-pinned by Recorder.
- The standard source build is ad-hoc signed. Only a Developer ID-signed, hardened, and notarized artifact should be presented as an official downloadable binary.
