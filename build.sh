#!/bin/bash
# Builds MacoPiP.app into ./build. Pass --install to copy it to ~/Applications and launch it.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP=build/MacoPiP.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/MacoPiP "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"

# A stable signing identity keeps the Screen Recording grant across rebuilds; ad-hoc ("-") does not.
IDENTITY="${CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ {print $2; exit}')}"
codesign --force --options runtime --sign "${IDENTITY:--}" "$APP"
echo "Built $APP (signed with: ${IDENTITY:-ad-hoc})"

if [[ "${1:-}" == "--install" ]]; then
    pkill -x MacoPiP || true
    mkdir -p ~/Applications
    rm -rf ~/Applications/MacoPiP.app
    cp -R "$APP" ~/Applications/
    open ~/Applications/MacoPiP.app
    echo "Installed and launched ~/Applications/MacoPiP.app"
fi
