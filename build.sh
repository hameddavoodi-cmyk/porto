#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="Porto"
APP="$ROOT/build/${APP_NAME}.app"
BIN="$APP/Contents/MacOS/${APP_NAME}"
RES="$APP/Contents/Resources"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$RES"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleExecutable</key><string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key><string>com.hameddavodi.porto</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key><string>${APP_NAME}</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0.0</string>
    <key>CFBundleVersion</key><string>2</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# Copy app icon
cp "$ROOT/Resources/AppIcon.icns" "$RES/AppIcon.icns"

# Copy menu bar icons (template-style, auto adapts to dark/light)
cp "$ROOT/Resources/MenuBarIcon.png"    "$RES/MenuBarIcon.png"
cp "$ROOT/Resources/MenuBarIcon@2x.png" "$RES/MenuBarIcon@2x.png"

swiftc -O -parse-as-library \
    "$ROOT"/Sources/App.swift \
    "$ROOT"/Sources/AppDelegate.swift \
    "$ROOT"/Sources/Models.swift \
    "$ROOT"/Sources/Shell.swift \
    "$ROOT"/Sources/PortScanner.swift \
    "$ROOT"/Sources/DockerScanner.swift \
    "$ROOT"/Sources/LaunchctlScanner.swift \
    "$ROOT"/Sources/ServiceMonitor.swift \
    "$ROOT"/Sources/MenuView.swift \
    -o "$BIN" \
    -framework SwiftUI -framework AppKit

codesign --force --deep --sign - "$APP"

# Refresh icon cache so Finder/Dock pick up the new AppIcon
touch "$APP"

(cd "$ROOT/build" && rm -f "${APP_NAME}.zip" && /usr/bin/ditto -c -k --sequesterRsrc --keepParent "${APP_NAME}.app" "${APP_NAME}.zip")

echo "Built: $APP"
echo "Zip:   $ROOT/build/${APP_NAME}.zip"
