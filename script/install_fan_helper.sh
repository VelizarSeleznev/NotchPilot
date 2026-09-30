#!/usr/bin/env bash
# Builds and installs the root fan helper (asks for your password once).
# Undo: script/install_fan_helper.sh uninstall
set -euo pipefail
cd "$(dirname "$0")/.."
LABEL="com.velizard.notchpilot.fand"
BIN="/Library/PrivilegedHelperTools/$LABEL"
PLIST="/Library/LaunchDaemons/$LABEL.plist"
IDENTITY="${NOTCHPILOT_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
  | grep -E '"(Developer ID Application|Apple Development):' | head -1 | sed -E 's/.*"(.*)"/\1/' || true)}"
IDENTITY="${IDENTITY:--}"

if [[ "${1:-}" == "uninstall" ]]; then
  echo auto > /Users/Shared/NotchPilot/fan-mode; sleep 5
  sudo launchctl bootout system "$PLIST" 2>/dev/null || true
  sudo rm -f "$BIN" "$PLIST"
  echo "removed"; exit 0
fi

mkdir -p dist
swiftc -O FanHelper/smc.swift FanHelper/main.swift -o dist/notchpilot-fand -framework IOKit
codesign --force --sign "$IDENTITY" --identifier "$LABEL" --options runtime dist/notchpilot-fand

mkdir -p /Users/Shared/NotchPilot
[[ -f /Users/Shared/NotchPilot/fan-mode ]] || echo auto > /Users/Shared/NotchPilot/fan-mode

sudo install -o root -g wheel -m 755 dist/notchpilot-fand "$BIN"
sudo install -o root -g wheel -m 644 FanHelper/$LABEL.plist "$PLIST"
sudo launchctl bootout system "$PLIST" 2>/dev/null || true
sudo launchctl bootstrap system "$PLIST"
sleep 2
echo "installed; status: $(cat /Users/Shared/NotchPilot/fan-status 2>/dev/null)"
