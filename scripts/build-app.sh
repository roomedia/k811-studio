#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
cd "$ROOT"

swift build -c release --product K811Mac
swift build -c release --product k811-agent-event
BIN_DIR="$(swift build -c release --show-bin-path)"
APP="$ROOT/dist/K811 Studio.app"
CONTENTS="$APP/Contents"

rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources" "$CONTENTS/Helpers"
cp "$BIN_DIR/K811Mac" "$CONTENTS/MacOS/K811Mac"
cp "$BIN_DIR/k811-agent-event" "$CONTENTS/Helpers/k811-agent-event"
cp "$ROOT/App/Info.plist" "$CONTENTS/Info.plist"
chmod 755 "$CONTENTS/MacOS/K811Mac" "$CONTENTS/Helpers/k811-agent-event"

codesign --force --sign - --timestamp=none "$APP"
codesign --verify --deep --strict "$APP"

print -r -- "$APP"
