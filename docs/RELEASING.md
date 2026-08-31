# Releasing

Recorder's default build is intended for local development. Publishing a downloadable app requires a stable public bundle identifier, Developer ID signing, hardened runtime, notarization, and validation on a clean Mac.

## Versioning

Choose an annotated tag such as `v1.0.0`. Set a monotonically increasing numeric build number. The build script accepts:

- `RECORDER_BUNDLE_ID` (default `local.recorder.app`)
- `RECORDER_VERSION` (default from `Resources/Info.plist`)
- `RECORDER_BUILD_NUMBER` (default from `Resources/Info.plist`)
- `RECORDER_SIGN_IDENTITY` (default `-` for ad-hoc signing)
- `RECORDER_SIGN_TIMESTAMP` (defaults to `none` for ad-hoc builds and `timestamp` for Developer ID builds)

A suitable public identity is `io.github.seriallazer.recorder`. Changing an already-shipped bundle identifier creates a new macOS privacy identity, so decide it before the first public binary.

## Source release

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift test --parallel
scripts/build-app.sh
git diff --check
```

Confirm that `LICENSE`, `NOTICE`, `THIRD_PARTY_NOTICES.md`, and `ThirdPartyLicenses/` are present in the source archive.

## Developer ID build

Use a secret-management mechanism for certificates and notarization credentials. Never place `.p12` files, passwords, API keys, or provisioning profiles in the repository.

```sh
export RECORDER_BUNDLE_ID=io.github.seriallazer.recorder
export RECORDER_VERSION=1.0.0
export RECORDER_BUILD_NUMBER=1
export RECORDER_SIGN_IDENTITY='Developer ID Application: ORGANIZATION (TEAMID)'
export RECORDER_SIGN_TIMESTAMP=timestamp

scripts/build-app.sh
```

The script signs `RecorderDiarizer` first, then the containing app. A Developer ID build enables the hardened runtime and requests a secure timestamp. Recorder is not currently configured for Mac App Store sandbox distribution; do not add `com.apple.security.app-sandbox` without revalidating file access, model downloads, ScreenCaptureKit, audio capture, and helper execution.

## Inspect and package

```sh
codesign --verify --deep --strict --verbose=2 dist/Recorder.app
codesign -d --verbose=4 dist/Recorder.app
codesign -d --entitlements :- dist/Recorder.app

ditto -c -k --keepParent dist/Recorder.app "dist/Recorder-${RECORDER_VERSION}.zip"
shasum -a 256 "dist/Recorder-${RECORDER_VERSION}.zip" > "dist/Recorder-${RECORDER_VERSION}.zip.sha256"
```

## Notarize

Use a notarytool keychain profile or an App Store Connect API key supplied by the release environment:

```sh
xcrun notarytool submit "dist/Recorder-${RECORDER_VERSION}.zip" \
  --keychain-profile recorder-notary --wait
xcrun stapler staple dist/Recorder.app
xcrun stapler validate dist/Recorder.app
spctl --assess --type execute --verbose=4 dist/Recorder.app
```

Recreate the archive and checksum after stapling, because stapling changes the app bundle.

## Release checklist

- CI is green on the tagged revision.
- The changelog contains the release date and version.
- License and third-party notices are bundled.
- The bundle identifier, version, build number, Team ID, hardened runtime, and timestamp are correct.
- Notarization is accepted and stapled.
- Gatekeeper accepts the app on a clean Apple Silicon Mac.
- Camera, microphone, screen/system audio, helper execution, model download, and offline inference pass the manual matrix.
- Screenshots and demo media contain only synthetic content.
- The release contains the app archive and matching SHA-256 file.

`RecorderEchoRepair` remains a source-checkout developer utility and is not currently shipped in the app archive.
