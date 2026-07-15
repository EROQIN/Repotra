#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
SOURCE="$ROOT/Resources/AppIcon.svg"
ICONSET="$ROOT/Resources/AppIcon.iconset"
OUTPUT="$ROOT/Resources/AppIcon.icns"
WORK="$(mktemp -d)"

trap 'rm -rf "$WORK" "$ICONSET"' EXIT

mkdir -p "$ICONSET"
qlmanage -t -s 1024 -o "$WORK" "$SOURCE" >/dev/null 2>&1
MASTER="$WORK/AppIcon.svg.png"

if [[ ! -f "$MASTER" ]]; then
    print -u2 "Unable to render $SOURCE with Quick Look."
    exit 1
fi

for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$MASTER" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" "$MASTER" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done

iconutil -c icns "$ICONSET" -o "$OUTPUT"
echo "$OUTPUT"
