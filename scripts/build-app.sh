#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release --product ClaudeTouchBar
swift build -c release --product cctb
BIN=$(swift build -c release --show-bin-path)
APP="build/Claude Touch Bar.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
cp "$BIN/ClaudeTouchBar" "$APP/Contents/MacOS/ClaudeTouchBar"
cp "$BIN/cctb" "$APP/Contents/Helpers/cctb"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"
codesign --force --sign - "$APP/Contents/Helpers/cctb"
codesign --force --sign - "$APP"
echo "Built $APP"
if [ "${1:-}" = "--install" ]; then
  pkill -x ClaudeTouchBar || true
  rm -rf "/Applications/Claude Touch Bar.app"
  cp -R "$APP" /Applications/
  open "/Applications/Claude Touch Bar.app"
  echo "Installed to /Applications"
fi
