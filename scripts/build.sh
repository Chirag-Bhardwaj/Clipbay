#!/bin/zsh
# Builds Clipbay.app (release), signs it, and installs it to /Applications.
#   ./scripts/build.sh            build + install + launch
#   ./scripts/build.sh --no-run   build + install only
set -euo pipefail
cd "$(dirname "$0")/.."

APP=build/Clipbay.app
IDENTITY="${CLIPBAY_SIGN_IDENTITY:-$(security find-identity -p codesigning -v | awk -F'"' 'NR==1{print $2}')}"

swift build -c release

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Clipbay "$APP/Contents/MacOS/Clipbay"
cp Resources/Info.plist "$APP/Contents/Info.plist"

if [[ ! -f build/AppIcon.icns ]]; then
  swift scripts/make_icon.swift build/AppIcon.iconset
  iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

if [[ -n "$IDENTITY" ]]; then
  codesign --force --deep --options runtime --sign "$IDENTITY" "$APP"
else
  codesign --force --deep --sign - "$APP"
fi

pkill -x Clipbay 2>/dev/null || true
sleep 0.5
rm -rf /Applications/Clipbay.app
cp -R "$APP" /Applications/Clipbay.app
echo "Installed /Applications/Clipbay.app (signed with: ${IDENTITY:-ad-hoc})"

if [[ "${1:-}" != "--no-run" ]]; then
  open /Applications/Clipbay.app
fi
