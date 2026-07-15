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
for bundle in "$BIN_PATH"/*.bundle(N); do
    cp -R "$bundle" "$APP/Contents/Resources/"
done
cp "$ROOT/Config/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
plutil -replace CFBundleExecutable -string Repotra "$APP/Contents/Info.plist"
plutil -replace CFBundleIdentifier -string com.erokin.Repotra "$APP/Contents/Info.plist"
codesign --force --deep --sign - "$APP"
echo "$APP"
