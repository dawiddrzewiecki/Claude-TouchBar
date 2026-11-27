#!/bin/bash
# Builds "Claude Touch Bar.app".
#   scripts/build-app.sh             build for this Mac
#   scripts/build-app.sh --install   build and copy to /Applications
#   UNIVERSAL=1 scripts/build-app.sh build arm64 + x86_64 (needs an SDK with both slices)
#
# Runs on macOS 10.15 Catalina and later. If SwiftPM can't run (common with older or
# partially installed Command Line Tools, e.g. "unable to lookup item 'PlatformPath'"),
# it falls back to calling swiftc directly.
set -euo pipefail
cd "$(dirname "$0")/.."

MIN_MACOS="10.15"
OUT="build/obj"
APP="build/Claude Touch Bar.app"

if [ "${UNIVERSAL:-0}" = "1" ]; then ARCHS="arm64 x86_64"; else ARCHS="$(uname -m)"; fi

build_with_swiftpm() {
  local arch_flags=()
  for a in $ARCHS; do arch_flags+=(--arch "$a"); done
  # --arch is only accepted for multi-arch builds by newer SwiftPM; skip it for native builds.
  [ "${UNIVERSAL:-0}" = "1" ] || arch_flags=()
  swift build -c release --product ClaudeTouchBar "${arch_flags[@]+"${arch_flags[@]}"}" &&
  swift build -c release --product cctb "${arch_flags[@]+"${arch_flags[@]}"}" &&
  BIN=$(swift build -c release --show-bin-path "${arch_flags[@]+"${arch_flags[@]}"}") &&
  cp "$BIN/ClaudeTouchBar" "$OUT/ClaudeTouchBar" &&
  cp "$BIN/cctb" "$OUT/cctb"
}

build_with_swiftc() {
  local sdk; sdk=$(xcrun --sdk macosx --show-sdk-path)
  local slices_app=() slices_cli=()
  for a in $ARCHS; do
    local d="$OUT/$a"; mkdir -p "$d"
    local tgt="$a-apple-macos$MIN_MACOS"
    echo "swiftc: $tgt"
    swiftc -O -sdk "$sdk" -target "$tgt" -parse-as-library -whole-module-optimization \
      -module-name ClaudeBarCore -emit-module -emit-module-path "$d/ClaudeBarCore.swiftmodule" \
      -emit-library -static -o "$d/libClaudeBarCore.a" Sources/ClaudeBarCore/*.swift
    swiftc -O -sdk "$sdk" -target "$tgt" -I "$d" -L "$d" -lClaudeBarCore \
      -module-name ClaudeTouchBar -o "$d/ClaudeTouchBar" Sources/ClaudeTouchBar/*.swift
    swiftc -O -sdk "$sdk" -target "$tgt" -I "$d" -L "$d" -lClaudeBarCore \
      -module-name cctb -o "$d/cctb" Sources/cctb/*.swift
    slices_app+=("$d/ClaudeTouchBar"); slices_cli+=("$d/cctb")
  done
  lipo -create "${slices_app[@]}" -output "$OUT/ClaudeTouchBar"
  lipo -create "${slices_cli[@]}" -output "$OUT/cctb"
}

rm -rf "$OUT"; mkdir -p "$OUT"
if [ "${USE_SWIFTC:-0}" != "1" ] && build_with_swiftpm; then
  echo "Built with SwiftPM"
else
  echo "SwiftPM unavailable or failed — building with swiftc"
  build_with_swiftc
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
cp "$OUT/ClaudeTouchBar" "$APP/Contents/MacOS/ClaudeTouchBar"
cp "$OUT/cctb" "$APP/Contents/Helpers/cctb"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"
codesign --force --sign - "$APP/Contents/Helpers/cctb"
codesign --force --sign - "$APP"
echo "Built $APP ($(lipo -archs "$APP/Contents/MacOS/ClaudeTouchBar"), macOS $MIN_MACOS+)"
if [ "${1:-}" = "--install" ]; then
  pkill -x ClaudeTouchBar || true
  rm -rf "/Applications/Claude Touch Bar.app"
  cp -R "$APP" /Applications/
  open "/Applications/Claude Touch Bar.app"
  echo "Installed to /Applications"
fi
