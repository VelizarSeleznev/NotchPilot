#!/usr/bin/env bash
# Build, bundle, sign and (re)launch NotchPilot.
# Usage: script/build_and_run.sh [run|install|logs|release]
#   release: ad-hoc signed zip in dist/ for sharing (no install).
# Signing: NOTCHPILOT_SIGN_IDENTITY, else the first Apple Development / Developer ID
# identity in the keychain, else ad-hoc. A stable identity keeps macOS permissions
# across rebuilds; ad-hoc builds ask again after every rebuild.
set -euo pipefail
cd "$(dirname "$0")/.."

MODE="${1:-run}"
APP_NAME="NotchPilot"
APP_ID="com.velizard.NotchPilot"
INSTALL_DIR="${NOTCHPILOT_INSTALL_DIR:-$HOME/Applications}"
APP="dist/$APP_NAME.app"

if [[ "$MODE" == "release" ]]; then
  IDENTITY="-"
else
  IDENTITY="${NOTCHPILOT_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -E '"(Developer ID Application|Apple Development):' | head -1 | sed -E 's/.*"(.*)"/\1/' || true)}"
  IDENTITY="${IDENTITY:--}"
fi
echo "signing with: $IDENTITY"

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

if [[ "$MODE" == "release" ]]; then
  VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)"
  ZIP="dist/$APP_NAME-$VERSION.zip"
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"
  echo "$ZIP"; shasum -a 256 "$ZIP"
  exit 0
fi

pkill -x "$APP_NAME" >/dev/null 2>&1 || true
mkdir -p "$INSTALL_DIR"
rm -rf "$INSTALL_DIR/$APP_NAME.app"
ditto "$APP" "$INSTALL_DIR/$APP_NAME.app"

case "$MODE" in
  install) ;;
  run) open "$INSTALL_DIR/$APP_NAME.app" ;;
  logs) open "$INSTALL_DIR/$APP_NAME.app"; log stream --style compact --predicate "process == \"$APP_NAME\"" ;;
  *) echo "usage: $0 [run|install|logs|release]" >&2; exit 2 ;;
esac
