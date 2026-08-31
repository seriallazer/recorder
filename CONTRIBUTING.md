# Contributing

Thanks for helping improve Recorder.

## Development setup

Recorder requires an Apple Silicon Mac, macOS 14.5 or later for development, and full Xcode 16.2 or later.

```sh
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
swift test --parallel
scripts/build-app.sh
```

## Before opening a pull request

- Keep capture and finalization failure paths non-destructive.
- Preserve raw or rollback media whenever a new transformation can fail.
- Keep transcription inference local; document any new network access explicitly.
- Add tests for state-machine, path, cleanup, alignment, or policy changes.
- Run the automated checks in `docs/TESTING.md`.
- Use only synthetic recordings, transcripts, device names, paths, and screenshots.
- Update `CHANGELOG.md` for user-visible changes.
- Update third-party notices when adding or changing dependencies or model artifacts.

## Privacy

Never commit real recordings, transcripts, window titles, device identifiers, user home paths, credentials, signing certificates, provisioning profiles, or model caches. Report security issues using `SECURITY.md`, not a public issue containing sensitive details.

## License

Unless explicitly stated otherwise, contributions intentionally submitted to this project are licensed under the Apache License 2.0.
