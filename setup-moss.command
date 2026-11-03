#!/bin/zsh
# Installs Cast's optional "Together" engine (MOSS-TTSD, Apache-2.0) in its own
# Python 3.13 environment. VoxAster's own runtime is not touched.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
MANIFEST="$HERE/Backend/moss.json"
DATA_ROOT="${OMNIVOICE_DATA_ROOT:-$HOME/Documents/OmniVoice-Mac}"
ENGINE="${OMNIVOICE_MOSS_HOME:-$DATA_ROOT/engines/moss}"
[[ "$(uname -m)" == "arm64" ]] || { echo "MOSS-TTSD needs an Apple Silicon Mac."; exit 1; }
PY313="$(command -v python3.13 || true)"
[[ -n "$PY313" ]] || { echo "Python 3.13 is required. Install it with: brew install python@3.13"; exit 1; }
VERSION="$("$PY313" -I -c 'import json,sys;print(json.load(open(sys.argv[1]))["package_version"])' "$MANIFEST")"
mkdir -p "$ENGINE"
if [[ ! -x "$ENGINE/venv/bin/python" ]]; then
  echo "Creating the MOSS-TTSD environment in $ENGINE/venv"
  "$PY313" -m venv "$ENGINE/venv"
fi
"$ENGINE/venv/bin/python" -I -m pip install --quiet --upgrade pip
echo "Installing mlx-speech $VERSION"
"$ENGINE/venv/bin/python" -I -m pip install --quiet "mlx-speech==$VERSION"
echo "Downloading MOSS-TTSD (about 9 GB) at pinned revisions"
"$ENGINE/venv/bin/python" -I - "$MANIFEST" "$ENGINE/models" <<'PY'
import json, sys
from huggingface_hub import snapshot_download
manifest, models = json.load(open(sys.argv[1])), sys.argv[2]
for key, folder in (("codec", "codec"), ("model", "ttsd")):
    path = snapshot_download(manifest[f"{key}_repo"], revision=manifest[f"{key}_revision"],
                             local_dir=f"{models}/{folder}", allow_patterns=[f"{manifest['variant']}/*"])
    print(f"  {manifest[f'{key}_repo']} → {path}")
PY
"$ENGINE/venv/bin/python" -I -c 'import mlx.core as mx, mlx_speech; assert "gpu" in str(mx.default_device()).lower(); print("MLX on", mx.default_device())'
echo "MOSS-TTSD is ready. In VoxAster, open Cast and choose Engine › Together."
