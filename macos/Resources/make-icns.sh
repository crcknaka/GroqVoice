#!/bin/bash
# Builds Resources/AppIcon.icns from make-icon.swift (needs only the CLT).
set -euo pipefail
cd "$(dirname "$0")"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
swiftc -O -o "$TMP/make-icon" make-icon.swift -framework AppKit 2>/dev/null
"$TMP/make-icon" "$TMP/icon-1024.png"
SET="$TMP/AppIcon.iconset"; mkdir -p "$SET"
for s in 16 32 128 256 512; do
  sips -z $s $s "$TMP/icon-1024.png" --out "$SET/icon_${s}x${s}.png" >/dev/null
  d=$((s*2)); sips -z $d $d "$TMP/icon-1024.png" --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o AppIcon.icns
cp "$TMP/icon-1024.png" icon-preview.png
echo "Built $(pwd)/AppIcon.icns"
