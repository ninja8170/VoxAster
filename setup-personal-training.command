#!/bin/zsh
set -euo pipefail

ROOT="$HOME/Documents/OmniVoice-Mac/personal-voice"
SRC="$ROOT/training-src"
VENV="$ROOT/training-venv"
PY="/opt/homebrew/bin/python3.12"

echo "Setting up Personal Voice LoRA training 2.7.4..."
mkdir -p "$ROOT"

[ -x "$PY" ] || { echo "Python 3.12 missing. Run: brew install python@3.12"; exit 1; }

if [ ! -d "$SRC/.git" ]; then
  git clone https://github.com/k2-fsa/OmniVoice.git "$SRC"
else
  git -C "$SRC" pull --ff-only
fi

rm -rf "$VENV"
"$PY" -m venv "$VENV"
"$VENV/bin/pip" install --upgrade pip setuptools wheel
"$VENV/bin/pip" install -e "${SRC}[lora]"

echo "Applying OmniVoice macOS DataLoader compatibility patch..."
"$VENV/bin/python" - "$SRC/omnivoice/training/builder.py" <<'PYMAC'
from pathlib import Path
import sys

p = Path(sys.argv[1])
s = p.read_text()

# train loader
s = s.replace(
    "        prefetch_factor=4,\n",
    "        prefetch_factor=(4 if config.num_workers > 0 else None),\n",
)

# eval loader - keep macOS single-process to avoid local-lambda pickling.
s = s.replace(
    "            num_workers=1,\n",
    "            num_workers=0,\n",
)
s = s.replace(
    "            prefetch_factor=2,\n",
    "            prefetch_factor=None,\n",
)
s = s.replace(
    "            prefetch_factor=(2 if config.num_workers > 0 else None),\n",
    "            prefetch_factor=None,\n",
)

p.write_text(s)
print("✅ Patched:", p)
PYMAC


cat > "$ROOT/run-lora.command" <<'RUN'
#!/bin/zsh
set -euo pipefail

ROOT="$HOME/Documents/OmniVoice-Mac/personal-voice"
SRC="$ROOT/training-src"
VENV="$ROOT/training-venv"
DATA="$ROOT/dataset"
OUT="$ROOT/exp"
TOK="$ROOT/tokens"

cd "$SRC"

export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
export PYTORCH_ENABLE_MPS_FALLBACK=1

echo "=== Personal Voice: tokenization ==="
PYTORCH_ENABLE_MPS_FALLBACK=1 "$VENV/bin/python" -m omnivoice.scripts.extract_audio_tokens   --input_jsonl "$DATA/train.jsonl"   --tar_output_pattern "$TOK/train/audios/shard-%06d.tar"   --jsonl_output_pattern "$TOK/train/txts/shard-%06d.jsonl"   --tokenizer_path "eustlb/higgs-audio-v2-tokenizer"   --nj_per_gpu 1   --loader_workers 0   --shuffle True

PYTORCH_ENABLE_MPS_FALLBACK=1 "$VENV/bin/python" -m omnivoice.scripts.extract_audio_tokens   --input_jsonl "$DATA/dev.jsonl"   --tar_output_pattern "$TOK/dev/audios/shard-%06d.tar"   --jsonl_output_pattern "$TOK/dev/txts/shard-%06d.jsonl"   --tokenizer_path "eustlb/higgs-audio-v2-tokenizer"   --nj_per_gpu 1   --loader_workers 0   --shuffle False

echo "=== Personal Voice: configuring LoRA ==="

python3 - "$SRC" "$TOK" "$ROOT" <<'PY'
import json, sys
from pathlib import Path
src=Path(sys.argv[1]); tok=Path(sys.argv[2]); root=Path(sys.argv[3])

train=json.loads((src/"examples/config/train_config_finetune_lora.json").read_text())
train["attn_implementation"]="sdpa"
train["steps"]=1000
train["save_steps"]=250
train["keep_last_n_checkpoints"]=2
train["learning_rate"]=1e-4
train["num_workers"]=0
train["mixed_precision"]="no"
train["allow_tf32"]=False
(root/"train_config_personal.json").write_text(json.dumps(train,indent=2))

data = {
    "train": [
        {
            "manifest_path": [str(tok / "train" / "data.lst")]
        }
    ],
    "dev": [
        {
            "manifest_path": [str(tok / "dev" / "data.lst")]
        }
    ]
}
(root/"data_config_personal.json").write_text(json.dumps(data,indent=2))
PY

echo "=== Personal Voice: LoRA training ==="
export PYTORCH_ENABLE_MPS_FALLBACK=1
"$VENV/bin/accelerate" launch   --num_processes 1   -m omnivoice.cli.train   --train_config "$ROOT/train_config_personal.json"   --data_config "$ROOT/data_config_personal.json"   --output_dir "$OUT"
RUN

chmod +x "$ROOT/run-lora.command"

echo ""
echo "✅ Personal Voice training environment installed"
echo "   $VENV"
echo ""
echo "Training is experimental on Apple Silicon."
