#!/bin/zsh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OMNI_PYTHON="${OMNIVOICE_PYTHON:-$HOME/Documents/OmniVoice-Mac/.venv/bin/python}"
TEST_BUILD="${1:-$HERE/.build/tests}"
mkdir -p "$TEST_BUILD"
PYTHONPATH="$HERE/Backend" "$OMNI_PYTHON" -B -m unittest discover -s "$HERE/Tests" -p 'test_*.py' -v
swiftc -D PHASE1_TESTS "$HERE"/Sources/*.swift "$HERE"/Tests/*.swift -parse-as-library -framework SwiftUI -framework AppKit -framework AVFoundation -module-cache-path "$TEST_BUILD/module-cache" -o "$TEST_BUILD/ui-tests"
"$TEST_BUILD/ui-tests"
for script in build.command install.command test.command setup-personal-training.command repair-mac-training.command repair-training-config.command; do
  zsh -n "$HERE/$script"
done
"$HERE/build.command" "$TEST_BUILD/release"
codesign --verify --deep --strict "$TEST_BUILD/release/OmniVoice.app"
APP="$TEST_BUILD/release/OmniVoice.app"
STATE_BEFORE="$TEST_BUILD/bundle-state-before.txt"
STATE_AFTER="$TEST_BUILD/bundle-state-after.txt"
find "$APP/Contents" -type f -exec shasum -a 256 {} \; | sort > "$STATE_BEFORE"
test -z "$(find "$APP/Contents" \( -type d -name __pycache__ -o -type f -name '*.pyc' \) -print -quit)"
mkdir -p "$TEST_BUILD/bytecode-probe-data"
(
  cd "$APP/Contents/Resources"
  OMNIVOICE_DATA_ROOT="$TEST_BUILD/bytecode-probe-data" \
  PYTHONPATH="$APP/Contents/Resources" \
  PYTHONDONTWRITEBYTECODE=1 \
  "$OMNI_PYTHON" -B -c 'import backend, generation, performance, performance_audio, performance_script, provenance, speech_text, training_safety'
)
test -z "$(find "$APP/Contents" \( -type d -name __pycache__ -o -type f -name '*.pyc' \) -print -quit)"
find "$APP/Contents" -type f -exec shasum -a 256 {} \; | sort > "$STATE_AFTER"
cmp "$STATE_BEFORE" "$STATE_AFTER"
codesign --verify --deep --strict "$APP"
echo "PASS: production Python launch configuration preserves the signed bundle"
"$OMNI_PYTHON" -B - "$HERE/Backend/runtime.json" "$TEST_BUILD/release/OmniVoice.app" <<'PY'
import json,plistlib,sys
from pathlib import Path
manifest=json.loads(Path(sys.argv[1]).read_text())
app=Path(sys.argv[2]); info=plistlib.loads((app/'Contents/Info.plist').read_bytes())
assert info['CFBundleShortVersionString']==manifest['native_app_version']
for name in ['backend.py','generation.py','speech_text.py','performance_script.py','performance_audio.py','performance.py','provenance.py','training_safety.py','runtime.json']:
 assert (app/'Contents/Resources'/name).read_bytes()==(Path(sys.argv[1]).parent/name).read_bytes()
print('PASS: release bundle provenance, resources and code signature')
PY
