#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ICONSET_DIR="$PROJECT_ROOT/.build/AppIcon.iconset"
mkdir -p "$ICONSET_DIR"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$PROJECT_ROOT/Resources/AppIcon.png" --out "$ICONSET_DIR/icon_${size}x${size}.png" >/dev/null
    retina_size=$((size * 2))
    sips -z "$retina_size" "$retina_size" "$PROJECT_ROOT/Resources/AppIcon.png" --out "$ICONSET_DIR/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil --convert icns "$ICONSET_DIR" --output "$PROJECT_ROOT/Resources/AppIcon.icns"
