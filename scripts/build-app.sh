#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"
export CLANG_MODULE_CACHE_PATH="$PROJECT_ROOT/.build/module-cache"
BUILD_ARGS=(--disable-sandbox --configuration release --cache-path .build/cache --config-path .build/config --security-path .build/security)
swift build "${BUILD_ARGS[@]}" --product GeoBoxPlayer
BIN_DIR="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)"
APP_DIR="$PROJECT_ROOT/dist/GeoBox Player.app"
mkdir -p "$APP_DIR/Contents/MacOS"
cp "$BIN_DIR/GeoBoxPlayer" "$APP_DIR/Contents/MacOS/GeoBoxPlayer"
cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>GeoBoxPlayer</string>
<key>CFBundleIdentifier</key><string>jp.namipi.GeoBoxPlayer</string>
<key>CFBundleName</key><string>GeoBox Player</string>
<key>CFBundleDisplayName</key><string>GeoBox Player</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>CFBundleDocumentTypes</key><array><dict>
<key>CFBundleTypeName</key><string>GeoBox Project</string>
<key>LSItemContentTypes</key><array><string>jp.namipi.geobox-player.project</string></array>
<key>CFBundleTypeExtensions</key><array><string>player</string></array>
<key>CFBundleTypeRole</key><string>Editor</string>
</dict></array>
<key>UTExportedTypeDeclarations</key><array><dict>
<key>UTTypeIdentifier</key><string>jp.namipi.geobox-player.project</string>
<key>UTTypeDescription</key><string>GeoBox Player Project</string>
<key>UTTypeConformsTo</key><array><string>public.json</string></array>
<key>UTTypeTagSpecification</key><dict>
<key>public.filename-extension</key><array><string>player</string></array>
<key>public.mime-type</key><string>application/json</string>
</dict></dict></array>
</dict></plist>
PLIST
codesign --force --sign - --identifier jp.namipi.GeoBoxPlayer "$APP_DIR"
printf 'Built: %s\n' "$APP_DIR"
