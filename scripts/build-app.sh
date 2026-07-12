#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
cd "$ROOT"

SELECTED_DEVELOPER_DIR="$(xcode-select -p 2>/dev/null || true)"
if [[ "$SELECTED_DEVELOPER_DIR" != *"Xcode.app/Contents/Developer"* && -d /Applications/Xcode.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
    SELECTED_DEVELOPER_DIR="$DEVELOPER_DIR"
fi

if [[ "$SELECTED_DEVELOPER_DIR" != *"Xcode.app/Contents/Developer"* ]]; then
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

SWIFT_MAJOR="$(swift --version | sed -n 's/Apple Swift version \([0-9][0-9]*\).*/\1/p')"
if [[ -z "$SWIFT_MAJOR" || "$SWIFT_MAJOR" -lt 6 ]]; then
    echo "Recorder requires Swift 6 or later, but the selected Xcode provides: $(swift --version | head -1)" >&2
    exit 1
fi

swift build -c release --product Recorder

APP="$ROOT/dist/Recorder.app"
CONTENTS="$APP/Contents"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp "$ROOT/.build/release/Recorder" "$CONTENTS/MacOS/Recorder"
cp "$ROOT/Resources/Info.plist" "$CONTENTS/Info.plist"
cp "$ROOT/THIRD_PARTY_NOTICES.md" "$CONTENTS/Resources/THIRD_PARTY_NOTICES.md"

codesign --force --deep --sign - \
    --entitlements "$ROOT/Resources/Recorder.entitlements" \
    "$APP"

echo "$APP"
