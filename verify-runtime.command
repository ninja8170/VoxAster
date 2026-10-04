#!/bin/zsh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
PYTHON="${OMNIVOICE_PYTHON:-$HOME/Documents/OmniVoice-Mac/.venv/bin/python}"
PYTHONPATH="$HERE/Backend" "$PYTHON" -B - <<'PYVERIFY'
import json
import fastapi, uvicorn, multipart, httpx, torch
from provenance import MANIFEST, resolve_base_model, runtime_provenance
assert torch.backends.mps.is_available(), 'Apple Silicon MPS is required'
p=runtime_provenance(resolve_base_model())
assert p['package_version']==MANIFEST['expected_package_version'], 'Unexpected package version'
assert p['package_commit']==MANIFEST['expected_package_commit'], 'Unexpected package commit'
assert p['model_revision']==MANIFEST['model_revision'], 'Unexpected snapshot revision'
assert p['audio_tokenizer_source']==MANIFEST['audio_tokenizer']['repo_id']
assert p['audio_tokenizer_revision']==MANIFEST['audio_tokenizer']['revision']
assert p['audio_tokenizer_weights_sha256']==MANIFEST['audio_tokenizer']['sha256']['model.safetensors']
print(json.dumps(p, indent=2))
PYVERIFY
"$PYTHON" -B -m pip check
