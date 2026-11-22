#!/bin/zsh
# Builds MacMonitor.app next to this script. Needs only the Xcode Command Line Tools.
set -e
cd "$(dirname "$0")"
APP=MacMonitor.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
swiftc -O -parse-as-library -swift-version 5 \
  -target "$(uname -m)-apple-macosx14.0" \
  -framework IOKit -framework SwiftUI -framework AppKit \
  Sources/*.swift -o "$APP/Contents/MacOS/MacMonitor"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Mac Monitor</string>
  <key>CFBundleDisplayName</key><string>Mac Monitor</string>
  <key>CFBundleExecutable</key><string>MacMonitor</string>
  <key>CFBundleIdentifier</key><string>local.macmonitor</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP" >/dev/null 2>&1
echo "Built $(pwd)/$APP"
