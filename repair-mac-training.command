#!/bin/zsh
set -euo pipefail

ROOT="$HOME/Documents/OmniVoice-Mac/personal-voice"
SRC="$ROOT/training-src"
VENV="$ROOT/training-venv"
RUNNER="$ROOT/run-lora.command"

echo "Applying OmniVoice Personal Voice Mac fixes..."

[ -f "$SRC/omnivoice/training/builder.py" ] || { echo "Training source not found."; exit 1; }
[ -f "$RUNNER" ] || { echo "Training runner not found."; exit 1; }

"$VENV/bin/python" - "$SRC/omnivoice/training/builder.py" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); s=p.read_text()

s=s.replace("        prefetch_factor=4,\n",
            "        prefetch_factor=(4 if config.num_workers > 0 else None),\n")
s=s.replace("            num_workers=1,\n",
            "            num_workers=0,\n")
s=s.replace("            prefetch_factor=2,\n",
            "            prefetch_factor=None,\n")
s=s.replace("            prefetch_factor=(2 if config.num_workers > 0 else None),\n",
            "            prefetch_factor=None,\n")

p.write_text(s)
print("✅ DataLoader patched")
PY

python3 - "$RUNNER" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); s=p.read_text()

if 'export PATH="/opt/homebrew/bin:' not in s:
    s=s.replace(
        'cd "$SRC"\n',
        'cd "$SRC"\nexport PATH="/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"\n'
    )

needle='train["learning_rate"]=1e-4'
if 'train["num_workers"]=0' not in s and needle in s:
    s=s.replace(
        needle,
        needle + '\\ntrain["num_workers"]=0\\ntrain["mixed_precision"]="no"\\ntrain["allow_tf32"]=False'
    )

p.write_text(s)
p.chmod(0o755)
print("✅ Training runner patched")
PY

echo ""
echo "✅ Mac training compatibility applied."
echo "Reopen OmniVoice and prepare the dataset once, then start training."
