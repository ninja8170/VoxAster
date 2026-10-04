#!/bin/zsh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
"$HERE/verify-runtime.command"
"$HERE/build.command"
APP="$HOME/Applications/VoxAster.app"
SOURCE="$HERE/.build/VoxAster.app"
codesign --verify --deep --strict "$SOURCE"
# Never terminate an unidentified process or replace a running app.
if pgrep -x VoxAster >/dev/null || pgrep -x OmniVoice >/dev/null || lsof -nP -iTCP:8011 -sTCP:LISTEN >/dev/null; then
  echo "Quit VoxAster and any legacy app, and stop the backend before installing. Port 8011 must be free."
  exit 1
fi
mkdir -p "$HOME/Applications"
STAGE="$(mktemp -d "$HOME/Applications/.voxaster-install.XXXXXX")"
trap 'rmdir "$STAGE" 2>/dev/null || true' EXIT
ditto "$SOURCE" "$STAGE/VoxAster.app"
codesign --verify --deep --strict "$STAGE/VoxAster.app"
BACKUP="$HOME/Applications/VoxAster-backup-$(date +%Y%m%d-%H%M%S).app"
[[ ! -e "$BACKUP" ]] || { echo "Backup already exists; installation stopped."; exit 1; }
if [[ -e "$APP" ]]; then
  codesign --verify --deep --strict "$APP"
  mv "$APP" "$BACKUP"
fi
if ! mv "$STAGE/VoxAster.app" "$APP"; then
  [[ ! -e "$APP" && -e "$BACKUP" ]] && mv "$BACKUP" "$APP"
  exit 1
fi
if ! codesign --verify --deep --strict "$APP"; then
  mv "$APP" "$STAGE/failed.app"
  [[ -e "$BACKUP" ]] && ditto "$BACKUP" "$APP"
  echo "Signature failed; new app retained at $STAGE/failed.app; previous bundle restored if present."
  exit 1
fi
echo "Installed $APP. Backup (if replacing an app): $BACKUP"
open "$APP"
