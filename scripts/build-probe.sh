#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"
APP="$PWD/dist/DesktopOrganizerProbe.app"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN_DIR/DesktopProbe" "$APP/Contents/MacOS/DesktopProbe"
cp Resources/Probe-Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
codesign --verify --strict "$APP"
printf '\nBuilt: %s\n' "$APP"
