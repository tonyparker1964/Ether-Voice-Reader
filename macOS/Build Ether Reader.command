#!/bin/bash
# Builds Ether Reader with Xcode and copies it to Applications.
set -e
cd "$(dirname "$0")"
if ! xcodebuild -version >/dev/null 2>&1; then
  echo "Xcode is required. Install it from the App Store, open it once, then run this again."
  echo "If Xcode is installed, run: sudo xcode-select -s /Applications/Xcode.app"
  read -r -p "Press Return to close."; exit 1
fi
echo "Building Ether Reader…"
if ! xcodebuild -project EtherReader.xcodeproj -target EtherReader -configuration Release \
      SYMROOT="$PWD/build" build > build.log 2>&1; then
  echo "Build failed. The errors are below (full log in macOS/build.log):"
  grep -E "error:" build.log | head -30
  read -r -p "Press Return to close."; exit 1
fi
rm -rf "/Applications/Ether Reader.app"
cp -R "build/Release/Ether Reader.app" /Applications/
echo "Installed to /Applications/Ether Reader.app"
open "/Applications/Ether Reader.app"
