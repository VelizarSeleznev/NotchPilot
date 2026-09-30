#!/usr/bin/env bash
# Build, bundle, sign and (re)launch NotchPilot.
# Usage: script/build_and_run.sh [run|install|logs]
set -euo pipefail
cd "$(dirname "$0")/.."

MODE="${1:-run}"
APP_NAME="NotchPilot"
APP_ID="com.velizard.NotchPilot"
IDENTITY="${NOTCHPILOT_SIGN_IDENTITY:-Apple Development: velizar.seleznev@gmail.com (VMQ79QRJFB)}"
INSTALL_DIR="${NOTCHPILOT_INSTALL_DIR:-$HOME/Applications}"
APP="dist/$APP_NAME.app"

swift build -c release --arch arm64
BIN="$(swift build -c release --arch arm64 --show-bin-path)/$APP_NAME"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
cp Bridge/np_bridge.pl "$APP/Contents/Resources/"
clang -dynamiclib -fobjc-arc -O2 -arch arm64 -framework Foundation \
  Bridge/np_bridge.m -o "$APP/Contents/Resources/libnp_bridge.dylib"

# perl loads the bridge dylib; it must carry a valid signature too.
codesign --force --sign "$IDENTITY" "$APP/Contents/Resources/libnp_bridge.dylib"
codesign --force --sign "$IDENTITY" --identifier "$APP_ID" --options runtime \
  --entitlements script/NotchPilot.entitlements "$APP"
codesign --verify --strict --deep --verbose=2 "$APP"

pkill -x "$APP_NAME" >/dev/null 2>&1 || true
mkdir -p "$INSTALL_DIR"
rm -rf "$INSTALL_DIR/$APP_NAME.app"
ditto "$APP" "$INSTALL_DIR/$APP_NAME.app"

case "$MODE" in
  install) ;;
  run) open "$INSTALL_DIR/$APP_NAME.app" ;;
  logs) open "$INSTALL_DIR/$APP_NAME.app"; log stream --style compact --predicate "process == \"$APP_NAME\"" ;;
  *) echo "usage: $0 [run|install|logs]" >&2; exit 2 ;;
esac
