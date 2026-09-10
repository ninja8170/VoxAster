#!/bin/zsh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OMNI_PYTHON="${OMNIVOICE_PYTHON:-$HOME/Documents/OmniVoice-Mac/.venv/bin/python}"
BUILD_ROOT="${1:-$HERE/.build}"
APP="$BUILD_ROOT/OmniVoice.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$HERE"/Backend/*.py "$HERE"/Backend/runtime.json "$APP/Contents/Resources/"
"$OMNI_PYTHON" -B - "$HERE/Backend/runtime.json" "$APP/Contents/Info.plist" <<'PY'
import json,plistlib,sys
version=json.load(open(sys.argv[1]))['native_app_version']
info=dict(CFBundleName='OmniVoice',CFBundleDisplayName='OmniVoice',
 CFBundleIdentifier='local.omnivoice.native',CFBundleExecutable='OmniVoice',
 CFBundlePackageType='APPL',CFBundleVersion=version,CFBundleShortVersionString=version,
 LSMinimumSystemVersion='14.0',NSHighResolutionCapable=True,CFBundleIconFile='OmniVoice',
 NSMicrophoneUsageDescription='OmniVoice uses the microphone for local voice cloning.')
with open(sys.argv[2],'wb') as f: plistlib.dump(info,f)
PY
if [ -d "$HERE/Assets" ]; then
  mkdir -p "$BUILD_ROOT/OmniVoice.iconset"
  cp "$HERE"/Assets/icon_*.png "$BUILD_ROOT/OmniVoice.iconset/"
  iconutil -c icns "$BUILD_ROOT/OmniVoice.iconset" -o "$APP/Contents/Resources/OmniVoice.icns"
fi
swiftc "$HERE"/Sources/*.swift -parse-as-library -framework SwiftUI -framework AppKit -framework AVFoundation -module-cache-path "$BUILD_ROOT/module-cache" -o "$APP/Contents/MacOS/OmniVoice"
codesign --force --deep --sign - "$APP"
echo "Built $APP"
