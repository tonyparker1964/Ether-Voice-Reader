#!/bin/bash
# Builds Ether Reader and installs it to /Applications.
# Uses Xcode if it is installed; otherwise Apple's free Command Line Tools.
set -e
cd "$(dirname "$0")"
APP_NAME="Ether Reader"
OUT="build/$APP_NAME.app"
rm -rf build && mkdir -p build

fail() { echo "$1"; read -r -p "Press Return to close."; exit 1; }

if xcodebuild -version >/dev/null 2>&1; then
  echo "Building with Xcode…"
  if ! xcodebuild -project EtherReader.xcodeproj -target EtherReader -configuration Release \
        SYMROOT="$PWD/build/xcode" build > build/build.log 2>&1; then
    grep -E "error:" build/build.log | head -30
    fail "Build failed. Copy the errors above to Claude. Full log: macOS/build/build.log"
  fi
  cp -R "build/xcode/Release/$APP_NAME.app" "$OUT"
else
  if ! xcrun --find swiftc >/dev/null 2>&1; then
    echo "Apple's Command Line Tools are needed (free, about 1 GB)."
    echo "A window will open — click Install. When it finishes, run this script again."
    xcode-select --install 2>/dev/null || true
    fail ""
  fi
  echo "Building with Command Line Tools…"
  SDK="$(xcrun --sdk macosx --show-sdk-path)"
  mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
  if ! xcrun swiftc -O -parse-as-library -swift-version 5 \
        -target arm64-apple-macos14.0 -sdk "$SDK" \
        EtherReader/*.swift -o "$OUT/Contents/MacOS/$APP_NAME" 2> build/build.log; then
    grep -E "error:" build/build.log | head -30
    fail "Build failed. Copy the errors above to Claude. Full log: macOS/build/build.log"
  fi
  cp EtherReader/ether_tts.py EtherReader/requirements.txt "$OUT/Contents/Resources/"
  cat > "$OUT/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key><string>$APP_NAME</string>
	<key>CFBundleIdentifier</key><string>com.ether.reader</string>
	<key>CFBundleName</key><string>$APP_NAME</string>
	<key>CFBundleDisplayName</key><string>$APP_NAME</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>1.0</string>
	<key>CFBundleVersion</key><string>1</string>
	<key>LSMinimumSystemVersion</key><string>14.0</string>
	<key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
	<key>NSHighResolutionCapable</key><true/>
	<key>NSMicrophoneUsageDescription</key><string>Ether Reader uses your microphone to test your mic and record your voice sample.</string>
	<key>NSRemovableVolumesUsageDescription</key><string>Ether Reader keeps its voice engine, model and recordings on your external drive.</string>
	<key>NSDocumentsFolderUsageDescription</key><string>Ether Reader opens text files you choose to narrate.</string>
</dict>
</plist>
PLIST
  codesign --force --deep --sign - "$OUT" >/dev/null 2>&1 || true
fi

rm -rf "/Applications/$APP_NAME.app"
cp -R "$OUT" /Applications/
echo "Installed to /Applications/$APP_NAME.app"
open "/Applications/$APP_NAME.app"
