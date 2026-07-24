#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
cd "$ROOT"

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <recording-folder> [--reprocess] [--transcribe automatic|stable|enhanced] [--expected-speakers 2-6] [--clean-existing-transcript]" >&2
    exit 2
fi

SELECTED_DEVELOPER_DIR="$(xcode-select -p 2>/dev/null || true)"
if [[ "$SELECTED_DEVELOPER_DIR" != *"Xcode.app/Contents/Developer"* && -d /Applications/Xcode.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

swift build -c release --product RecorderEchoRepair
swift build -c release --product RecorderDiarizer
exec "$ROOT/.build/release/RecorderEchoRepair" "$@"
