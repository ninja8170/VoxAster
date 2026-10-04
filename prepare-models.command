#!/bin/zsh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
PYTHON="${OMNIVOICE_PYTHON:-$HOME/Documents/OmniVoice-Mac/.venv/bin/python}"
export PYTHONDONTWRITEBYTECODE=1 HF_HUB_DISABLE_TELEMETRY=1
PYTHONPATH="$HERE/Backend" "$PYTHON" -B -c 'from provenance import download_models; download_models()'
echo "Verified pinned inference models, including the official Boson tokenizer."
