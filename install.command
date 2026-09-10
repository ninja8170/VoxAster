#!/bin/zsh
set -euo pipefail
APP="$HOME/Applications/OmniVoice.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RES="$CONTENTS/Resources"
HERE="$(cd "$(dirname "$0")" && pwd)"
OMNI="$HOME/Documents/OmniVoice-Mac/.venv"

echo "Installing OmniVoice Native 3.4.5 — Project Isolation Fix..."
[ -x "$OMNI/bin/python" ] || { echo "Missing OmniVoice environment: $OMNI"; exit 1; }
command -v swiftc >/dev/null || { echo "Run: xcode-select --install"; exit 1; }

"$OMNI/bin/pip" install -q fastapi uvicorn python-multipart

pkill -f "backend.py" >/dev/null 2>&1 || true
sleep 1

rm -rf "$APP"
mkdir -p "$MACOS" "$RES"
cp "$HERE/Backend/backend.py" "$RES/backend.py"

TMPICON="$(mktemp -d)/OmniVoice.iconset"
mkdir -p "$TMPICON"
cp "$HERE"/Assets/icon_*.png "$TMPICON/" 2>/dev/null || true
iconutil -c icns "$TMPICON" -o "$RES/OmniVoice.icns" >/dev/null 2>&1 || true

cat > "$CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>OmniVoice</string>
<key>CFBundleDisplayName</key><string>OmniVoice</string>
<key>CFBundleIdentifier</key><string>local.omnivoice.native</string>
<key>CFBundleExecutable</key><string>OmniVoice</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>3.4.5</string>
<key>CFBundleShortVersionString</key><string>3.4.5</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>CFBundleIconFile</key><string>OmniVoice</string>
<key>NSMicrophoneUsageDescription</key><string>OmniVoice uses the microphone for local voice cloning.</string>
</dict></plist>
PLIST

swiftc "$HERE/Sources/OmniVoice.swift" -parse-as-library   -framework SwiftUI -framework AppKit -framework AVFoundation   -o "$MACOS/OmniVoice"

chmod +x "$MACOS/OmniVoice"
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true
touch "$APP"

echo "✅ OmniVoice Native 3.4.5 — Project Isolation Fix installed"
open "$APP"
