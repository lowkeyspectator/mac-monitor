#!/bin/zsh
# Builds MacMonitor.app (universal: Apple Silicon + Intel) next to this script.
# Needs only the Xcode Command Line Tools:  xcode-select --install
#
#   ./build.sh            build MacMonitor.app
#   ./build.sh --zip      also create MacMonitor.zip for distribution
set -e
cd "$(dirname "$0")"
VERSION=1.2.0
APP=MacMonitor.app
BUILD=.build
rm -rf "$APP" "$BUILD"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$BUILD"

for ARCH in arm64 x86_64; do
  echo "Compiling for $ARCH…"
  swiftc -O -parse-as-library -swift-version 5 \
    -target "$ARCH-apple-macosx15.0" \
    -framework IOKit -framework SwiftUI -framework AppKit -framework ServiceManagement \
    Sources/*.swift -o "$BUILD/MacMonitor-$ARCH"
done
lipo -create "$BUILD"/MacMonitor-* -output "$APP/Contents/MacOS/MacMonitor"

# App icon (generated once into Resources/ by Scripts/make-icon.swift)
[[ -f Resources/AppIcon.icns ]] || swift Scripts/make-icon.swift Resources
cp Resources/AppIcon.icns "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Mac Monitor</string>
  <key>CFBundleDisplayName</key><string>Mac Monitor</string>
  <key>CFBundleExecutable</key><string>MacMonitor</string>
  <key>CFBundleIdentifier</key><string>io.github.lowkeyspectator.macmonitor</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST

codesign --force --sign - "$APP" >/dev/null || { echo "error: codesign failed (see message above)" >&2; exit 1; }
echo "Built $(pwd)/$APP (version $VERSION)"

if [[ "$1" == "--zip" ]]; then
  rm -f MacMonitor.zip
  ditto -c -k --keepParent "$APP" MacMonitor.zip
  echo "Packaged $(pwd)/MacMonitor.zip"
fi
