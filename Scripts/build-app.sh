#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
CONFIGURATION="${1:-release}"
APP="$ROOT/.build/Repotra.app"

cd "$ROOT"
swift build -c "$CONFIGURATION"
BIN_PATH="$(swift build -c "$CONFIGURATION" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_PATH/Repotra" "$APP/Contents/MacOS/Repotra"
cp "$ROOT/Config/Info.plist" "$APP/Contents/Info.plist"
plutil -replace CFBundleExecutable -string Repotra "$APP/Contents/Info.plist"
plutil -replace CFBundleIdentifier -string com.erokin.Repotra "$APP/Contents/Info.plist"
codesign --force --deep --sign - "$APP"
echo "$APP"
