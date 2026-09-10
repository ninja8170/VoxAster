#!/bin/zsh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OMNI_PYTHON="${OMNIVOICE_PYTHON:-$HOME/Documents/OmniVoice-Mac/.venv/bin/python}"
# Check existing dependencies; never install or upgrade the synthesis runtime.
"$OMNI_PYTHON" -B -c 'import fastapi, uvicorn, multipart, omnivoice'
"$HERE/build.command"
APP="$HOME/Applications/OmniVoice.app"
# Only stop this app's backend, after a successful build.
pkill -f "$APP/Contents/Resources/backend.py" >/dev/null 2>&1 || true
if [ -d "$APP" ]; then
  mv "$APP" "$HOME/Applications/OmniVoice-backup-$(date +%Y%m%d-%H%M%S).app"
fi
ditto "$HERE/.build/OmniVoice.app" "$APP"
open "$APP"
