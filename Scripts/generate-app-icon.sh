#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
SOURCE="$ROOT/Resources/AppIcon.svg"
ICONSET="$ROOT/Resources/AppIcon.iconset"
OUTPUT="$ROOT/Resources/AppIcon.icns"
WORK="$(mktemp -d)"

trap 'rm -rf "$WORK" "$ICONSET"' EXIT

mkdir -p "$ICONSET"
MASTER="$WORK/AppIcon.png"
sips -s format png "$SOURCE" --out "$MASTER" >/dev/null

if [[ ! -f "$MASTER" ]]; then
    print -u2 "Unable to render $SOURCE with sips."
    exit 1
fi

validate_transparent_corners() {
    swift -e '
        import AppKit
        import Darwin

        guard let image = NSImage(contentsOfFile: CommandLine.arguments[1]),
              let data = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: data) else {
            fputs("Unable to inspect icon alpha.\n", stderr)
            exit(1)
        }

        let corners = [
            (0, 0),
            (bitmap.pixelsWide - 1, 0),
            (0, bitmap.pixelsHigh - 1),
            (bitmap.pixelsWide - 1, bitmap.pixelsHigh - 1),
        ]
        let isTransparent = corners.allSatisfy { point in
            (bitmap.colorAt(x: point.0, y: point.1)?.alphaComponent ?? 1) < 0.01
        }
        guard isTransparent else {
            fputs("Icon corners must remain transparent.\n", stderr)
            exit(1)
        }
    ' "$1"
}

validate_transparent_corners "$MASTER"

for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$MASTER" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" "$MASTER" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done

iconutil -c icns "$ICONSET" -o "$OUTPUT"
sips -s format png "$OUTPUT" --out "$WORK/AppIcon-final.png" >/dev/null
validate_transparent_corners "$WORK/AppIcon-final.png"
echo "$OUTPUT"
