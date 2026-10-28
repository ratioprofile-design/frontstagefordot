#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "$(uname -s)" != Darwin ]]; then
  echo 'App bundling requires macOS and the Xcode command line tools.' >&2
  exit 1
fi
swift build -c release --product Frontstage --arch arm64 --scratch-path .build/mac-arm64
swift build -c release --product Frontstage --arch x86_64 --scratch-path .build/mac-x86_64
arm_path="$(swift build -c release --arch arm64 --scratch-path .build/mac-arm64 --show-bin-path)"
intel_path="$(swift build -c release --arch x86_64 --scratch-path .build/mac-x86_64 --show-bin-path)"
app_path="$PWD/build/DOT.app"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
xcrun lipo -create "$arm_path/Frontstage" "$intel_path/Frontstage" -output "$app_path/Contents/MacOS/Frontstage"
xcrun lipo "$app_path/Contents/MacOS/Frontstage" -verify_arch arm64 x86_64
cp Resources/Info.plist "$app_path/Contents/Info.plist"
# Copy DOT app icons and assets
cp Resources/*.icns "$app_path/Contents/Resources/" 2>/dev/null || true
if [[ -d Resources/Assets ]]; then
  cp -R Resources/Assets/* "$app_path/Contents/Resources/" 2>/dev/null || true
fi
find "$app_path" -name "._*" -delete
# Release identities enable hardened runtime signing; default artifacts remain development builds.
if [[ -n "${FRONTSTAGE_SIGNING_IDENTITY:-}" ]]; then
  codesign --force --options runtime --timestamp --sign "$FRONTSTAGE_SIGNING_IDENTITY" "$app_path"
else
  codesign --force --sign - "$app_path"
fi
plutil -lint "$app_path/Contents/Info.plist"
codesign --verify --strict "$app_path"
/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister -f "$app_path" 2>/dev/null || true
ditto -c -k --keepParent "$app_path" build/DOT-macOS.zip
echo "Built $app_path"
