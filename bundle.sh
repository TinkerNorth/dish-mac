#!/bin/bash
# Wrap the SwiftPM executable in a minimal .app bundle so macOS treats it
# as a regular application (proper Dock icon, window focus, Cmd-Tab, etc.).
# Re-run after every `swift build`.
set -euo pipefail

CONFIG="${1:-debug}"
BIN="$(swift build --configuration "$CONFIG" --show-bin-path)/Dish"
if [ ! -x "$BIN" ]; then
  echo "Binary not found at $BIN — run 'swift build' first." >&2
  exit 1
fi

# The VERSION file is the single source of truth for the app's self-reported
# version (mirrors satellite's VERSION gate). A hardcoded plist version here
# would make every build self-report the same number — fatal for the
# "update both" protocol-mismatch UX.
VERSION="$(tr -d '[:space:]' < "$PWD/VERSION")"
case "$VERSION" in
  [0-9]*.[0-9]*) ;;
  *) echo "VERSION file missing or malformed ('$VERSION') — it must hold a semver-ish version." >&2; exit 1 ;;
esac

APP="$PWD/Dish.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Dish"
cp "$PWD/Resources/Dish.icns" "$APP/Contents/Resources/Dish.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>Dish</string>
    <key>CFBundleDisplayName</key>     <string>Dish</string>
    <key>CFBundleIdentifier</key>      <string>com.tinkernorth.dish.mac</string>
    <key>CFBundleVersion</key>         <string>${VERSION}</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleExecutable</key>      <string>Dish</string>
    <key>CFBundleIconFile</key>        <string>Dish</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>LSMinimumSystemVersion</key>  <string>13.0</string>
    <key>NSHighResolutionCapable</key> <true/>
    <key>NSLocalNetworkUsageDescription</key>
        <string>Dish discovers Satellite servers on your local network.</string>
    <key>NSBonjourServices</key>
        <array><string>_satellite._udp</string></array>
</dict>
</plist>
PLIST

echo "Built $APP"
echo "Launch: open $APP"
