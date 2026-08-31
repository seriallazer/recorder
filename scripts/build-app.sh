#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
cd "$ROOT"

BUNDLE_ID="${RECORDER_BUNDLE_ID:-local.recorder.app}"
VERSION="${RECORDER_VERSION:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)}"
BUILD_NUMBER="${RECORDER_BUILD_NUMBER:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Resources/Info.plist)}"
SIGN_IDENTITY="${RECORDER_SIGN_IDENTITY:--}"
SIGN_TIMESTAMP="${RECORDER_SIGN_TIMESTAMP:-}"
if [[ -z "$SIGN_TIMESTAMP" ]]; then
    if [[ "$SIGN_IDENTITY" == "-" ]]; then
        SIGN_TIMESTAMP=none
    else
        SIGN_TIMESTAMP=timestamp
    fi
fi
BUNDLE_ID_PATTERN='^[A-Za-z0-9][A-Za-z0-9-]*([.][A-Za-z0-9][A-Za-z0-9-]*)+$'
VERSION_PATTERN='^[0-9]+([.][0-9]+){1,2}$'
BUILD_NUMBER_PATTERN='^[0-9]+$'

if [[ ! $BUNDLE_ID =~ $BUNDLE_ID_PATTERN ]]; then
    echo "RECORDER_BUNDLE_ID must be a reverse-DNS bundle identifier." >&2
    exit 2
fi
if [[ ! $VERSION =~ $VERSION_PATTERN ]]; then
    echo "RECORDER_VERSION must contain two or three numeric components." >&2
    exit 2
fi
if [[ ! $BUILD_NUMBER =~ $BUILD_NUMBER_PATTERN ]]; then
    echo "RECORDER_BUILD_NUMBER must be numeric." >&2
    exit 2
fi
if [[ "$SIGN_TIMESTAMP" != "none" && "$SIGN_TIMESTAMP" != "timestamp" ]]; then
    echo "RECORDER_SIGN_TIMESTAMP must be 'none' or 'timestamp'." >&2
    exit 2
fi

SELECTED_DEVELOPER_DIR="${DEVELOPER_DIR:-$(xcode-select -p 2>/dev/null || true)}"
if [[ ( -z "$SELECTED_DEVELOPER_DIR" || "$SELECTED_DEVELOPER_DIR" == *"/CommandLineTools" ) && -d /Applications/Xcode.app/Contents/Developer ]]; then
    SELECTED_DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

if [[ "$SELECTED_DEVELOPER_DIR" == *"/CommandLineTools" || ! -x "$SELECTED_DEVELOPER_DIR/usr/bin/xcodebuild" ]]; then
    cat >&2 <<'MESSAGE'
Recorder requires full Xcode with Swift 6; Command Line Tools alone are insufficient.

1. Update macOS to 14.5 or later (System Settings > General > Software Update).
2. Install Xcode 16.2 or later.
3. Select it and finish setup:
   sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
   sudo xcodebuild -runFirstLaunch
4. Run this script again.
MESSAGE
    exit 1
fi

export DEVELOPER_DIR="$SELECTED_DEVELOPER_DIR"

SWIFT_MAJOR="$(swift --version | sed -n 's/Apple Swift version \([0-9][0-9]*\).*/\1/p')"
if [[ -z "$SWIFT_MAJOR" || "$SWIFT_MAJOR" -lt 6 ]]; then
    echo "Recorder requires Swift 6 or later, but the selected Xcode provides: $(swift --version | head -1)" >&2
    exit 1
fi

swift build -c release --product Recorder
swift build -c release --product RecorderDiarizer

APP="$ROOT/dist/Recorder.app"
CONTENTS="$APP/Contents"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp "$ROOT/.build/release/Recorder" "$CONTENTS/MacOS/Recorder"
cp "$ROOT/.build/release/RecorderDiarizer" "$CONTENTS/MacOS/RecorderDiarizer"
cp "$ROOT/Resources/Info.plist" "$CONTENTS/Info.plist"
cp "$ROOT/THIRD_PARTY_NOTICES.md" "$CONTENTS/Resources/THIRD_PARTY_NOTICES.md"
cp "$ROOT/LICENSE" "$CONTENTS/Resources/LICENSE"
cp "$ROOT/NOTICE" "$CONTENTS/Resources/NOTICE"
cp -R "$ROOT/ThirdPartyLicenses" "$CONTENTS/Resources/ThirdPartyLicenses"
cp "$ROOT/Resources/AppIcon.icns" "$CONTENTS/Resources/AppIcon.icns"

/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$CONTENTS/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$CONTENTS/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$CONTENTS/Info.plist"

SIGNING_ARGUMENTS=(--force --sign "$SIGN_IDENTITY")
if [[ "$SIGN_IDENTITY" != "-" ]]; then
    SIGNING_ARGUMENTS+=(--options runtime)
    if [[ "$SIGN_TIMESTAMP" == "timestamp" ]]; then
        SIGNING_ARGUMENTS+=(--timestamp)
    else
        SIGNING_ARGUMENTS+=(--timestamp=none)
    fi
fi

codesign "${SIGNING_ARGUMENTS[@]}" \
    --identifier "$BUNDLE_ID.diarizer" \
    "$CONTENTS/MacOS/RecorderDiarizer"

APP_SIGNING_ARGUMENTS=("${SIGNING_ARGUMENTS[@]}")
if [[ "$SIGN_IDENTITY" == "-" ]]; then
    APP_SIGNING_ARGUMENTS+=(--requirements "=designated => identifier \"$BUNDLE_ID\"")
fi
APP_SIGNING_ARGUMENTS+=(--entitlements "$ROOT/Resources/Recorder.entitlements")

codesign "${APP_SIGNING_ARGUMENTS[@]}" "$APP"

codesign --verify --deep --strict --verbose=2 "$APP"

echo "$APP ($BUNDLE_ID $VERSION build $BUILD_NUMBER)"
