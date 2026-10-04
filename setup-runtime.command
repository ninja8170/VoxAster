#!/bin/zsh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
PYTHON="${OMNIVOICE_SETUP_PYTHON:-/opt/homebrew/bin/python3.12}"
VENV="${OMNIVOICE_SETUP_VENV:-$HOME/Documents/OmniVoice-Mac/.venv}"
export PYTHONDONTWRITEBYTECODE=1 HF_HUB_DISABLE_TELEMETRY=1
[[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 ]] || { echo "Requires Apple Silicon macOS."; exit 1; }
command -v ffmpeg >/dev/null || { echo "Install FFmpeg first: brew install ffmpeg"; exit 1; }
[[ -x "$PYTHON" ]] || { echo "Install Python 3.12: brew install python@3.12"; exit 1; }
"$PYTHON" -B -c 'import sys; assert sys.version_info[:2] == (3, 12), "Python 3.12 required"'
[[ ! -e "$VENV" && ! -L "$VENV" ]] || { echo "Existing runtime preserved: $VENV. Use verify-runtime.command; move it aside yourself only if rebuilding is intended."; exit 1; }
"$PYTHON" -m venv "$VENV"
"$VENV/bin/python" -B -m pip install -r "$HERE/requirements.txt"
"$VENV/bin/python" -B -m pip check
OMNIVOICE_PYTHON="$VENV/bin/python" "$HERE/prepare-models.command"
OMNIVOICE_PYTHON="$VENV/bin/python" "$HERE/verify-runtime.command"
echo "Runtime ready. Build with ./build.command. Setup does not install the app."
