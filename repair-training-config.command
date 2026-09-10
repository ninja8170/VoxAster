#!/bin/zsh
set -euo pipefail

ROOT="$HOME/Documents/OmniVoice-Mac/personal-voice"
TOK="$ROOT/tokens"

echo "Repairing Personal Voice data config..."

python3 - "$ROOT" "$TOK" <<'PY'
import json, sys
from pathlib import Path
root=Path(sys.argv[1])
tok=Path(sys.argv[2])

train_manifest = tok / "train" / "data.lst"
dev_manifest = tok / "dev" / "data.lst"

if not train_manifest.is_file():
    raise SystemExit(f"Missing train manifest: {train_manifest}")
if not dev_manifest.is_file():
    raise SystemExit(f"Missing dev manifest: {dev_manifest}")

data = {
    "train": [{"manifest_path": [str(train_manifest)]}],
    "dev": [{"manifest_path": [str(dev_manifest)]}],
}

out = root / "data_config_personal.json"
out.write_text(json.dumps(data, indent=2))
print("✅ Repaired:", out)
print("Train:", train_manifest)
print("Dev:  ", dev_manifest)
PY

echo ""
echo "You do NOT need to re-tokenize."
echo "Go back to OmniVoice and click Start LoRA Training again."
