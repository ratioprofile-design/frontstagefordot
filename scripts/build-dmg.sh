#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "$(uname -s)" != Darwin ]]; then
  echo 'DMG packaging requires macOS.' >&2
  exit 1
fi
if [[ "${1:-}" != --skip-build ]]; then ./scripts/build-macos-app.sh; fi
app_path="$PWD/build/DOT.app"
test -f "$app_path/Contents/MacOS/DOT"
codesign --verify --strict "$app_path"
staging_path="$(mktemp -d "$PWD/build/dmg-staging.XXXXXX")"
trap 'rm -rf "$staging_path"' EXIT
ditto "$app_path" "$staging_path/DOT.app"
ln -s /Applications "$staging_path/Applications"
find "$staging_path" -name "._*" -delete
hdiutil create -volname DOT -srcfolder "$staging_path" -ov -format UDZO -fs HFS+ build/DOT.dmg
hdiutil verify build/DOT.dmg
echo 'Built build/DOT.dmg'
