#!/bin/zsh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OMNI_PYTHON="${OMNIVOICE_PYTHON:-$HOME/Documents/OmniVoice-Mac/.venv/bin/python}"
BUILD_ROOT="${1:-$HERE/.build}"
APP="$BUILD_ROOT/VoxAster.app"
# Refuse output aliases that could delete the installed app or the checkout.
"$OMNI_PYTHON" -B - "$APP" "$HERE" <<'PYSAFE'
import sys
from pathlib import Path
app, source = map(lambda p: Path(p).resolve(), sys.argv[1:])
protected = [base/name for base in (Path.home()/'Applications', Path('/Applications'))
             for name in ('VoxAster.app', 'OmniVoice.app')]
assert app not in [p.resolve() for p in protected], 'Build outside installed application locations'
assert app != source and app not in source.parents, 'Unsafe build output'
PYSAFE
rm -rf "$APP" "$BUILD_ROOT/VoxAster.iconset"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$HERE/LICENSE" "$HERE/THIRD_PARTY.md" "$HERE/PRIVACY.md" "$HERE/Notice" "$APP/Contents/Resources/"
cp -R "$HERE/Licenses" "$APP/Contents/Resources/Licenses"
cp "$HERE"/Backend/*.py "$HERE"/Backend/*.json "$APP/Contents/Resources/"
"$OMNI_PYTHON" -B - "$HERE/Backend/runtime.json" "$APP/Contents/Info.plist" <<'PY'
import json,plistlib,sys
version=json.load(open(sys.argv[1]))['native_app_version']
info=dict(CFBundleName='VoxAster',CFBundleDisplayName='VoxAster',
 CFBundleIdentifier='local.omnivoice.native',CFBundleExecutable='VoxAster',
 CFBundlePackageType='APPL',CFBundleVersion=version,CFBundleShortVersionString=version,
 LSMinimumSystemVersion='14.0',NSHighResolutionCapable=True,CFBundleIconFile='VoxAster',
 NSMicrophoneUsageDescription='VoxAster uses the microphone for local voice cloning.',
 NSDocumentsFolderUsageDescription='VoxAster stores voice references, generated audio and its local runtime in your Documents folder.')
with open(sys.argv[2],'wb') as f: plistlib.dump(info,f)
PY
if [ -d "$HERE/Assets" ]; then
  mkdir -p "$BUILD_ROOT/VoxAster.iconset"
  cp "$HERE"/Assets/icon_*.png "$BUILD_ROOT/VoxAster.iconset/"
  iconutil -c icns "$BUILD_ROOT/VoxAster.iconset" -o "$APP/Contents/Resources/VoxAster.icns"
fi
swiftc "$HERE"/Sources/*.swift -O -target arm64-apple-macosx14.0 -parse-as-library -framework SwiftUI -framework AppKit -framework AVFoundation -module-cache-path "$BUILD_ROOT/module-cache" -o "$APP/Contents/MacOS/VoxAster"
# There is one Mach-O executable and no nested code to sign. Never use --deep
# to hide a missing nested-code signing plan if the bundle architecture changes.
SIGN_IDENTITY="${VOXASTER_SIGN_IDENTITY:--}"
SIGN_OPTIONS=(--force --options runtime --entitlements "$HERE/Resources/VoxAster.entitlements")
if [[ "$SIGN_IDENTITY" != "-" ]]; then
  [[ "$SIGN_IDENTITY" == "Developer ID Application: "* ]] || { echo "Use a Developer ID Application identity, or omit VOXASTER_SIGN_IDENTITY for local ad-hoc builds."; exit 1; }
  SIGN_OPTIONS+=(--timestamp)
fi
if [[ "${VOXASTER_UNSIGNED:-0}" != "1" ]]; then
  codesign "${SIGN_OPTIONS[@]}" --sign "$SIGN_IDENTITY" "$APP"
  codesign --verify --deep --strict "$APP"
fi
echo "Built $APP"
