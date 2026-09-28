#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
swift build -c release --product DesktopOrganizer
BIN_DIR="$(swift build -c release --show-bin-path)"
APP="$PWD/dist/DesktopOrganizer.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/DesktopOrganizer" "$APP/Contents/MacOS/DesktopOrganizer"
cp Resources/Organizer-Info.plist "$APP/Contents/Info.plist"
swift scripts/make-assets.swift "$PWD/.build/assets"
iconutil -c icns "$PWD/.build/assets/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP"
codesign --verify --strict "$APP"
printf '\nBuilt: %s\n' "$APP"
