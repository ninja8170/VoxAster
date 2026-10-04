#!/bin/zsh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OMNI_PYTHON="${OMNIVOICE_PYTHON:-$HOME/Documents/OmniVoice-Mac/.venv/bin/python}"
TEST_BUILD="${1:-$HERE/.build/tests}"
mkdir -p "$TEST_BUILD"
TEST_BUILD="$(cd "$TEST_BUILD" && pwd)"
PYTHONPATH="$HERE/Backend" "$OMNI_PYTHON" -B -m unittest discover -s "$HERE/Tests" -p 'test_*.py' -v
swiftc -D PHASE1_TESTS "$HERE"/Sources/*.swift "$HERE"/Tests/*.swift -parse-as-library -framework SwiftUI -framework AppKit -framework AVFoundation -module-cache-path "$TEST_BUILD/module-cache" -o "$TEST_BUILD/ui-tests"
"$TEST_BUILD/ui-tests"
for script in build.command install.command test.command setup-runtime.command verify-runtime.command prepare-models.command; do
  zsh -n "$HERE/$script"
done
"$HERE/build.command" "$TEST_BUILD/release"
if [[ "${VOXASTER_UNSIGNED:-0}" != "1" ]]; then codesign --verify --deep --strict "$TEST_BUILD/release/VoxAster.app"; fi
APP="$TEST_BUILD/release/VoxAster.app"
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
  "$OMNI_PYTHON" -B -c 'import backend, generation, performance, performance_audio, performance_script, provenance, speech_text'
)
test -z "$(find "$APP/Contents" \( -type d -name __pycache__ -o -type f -name '*.pyc' \) -print -quit)"
find "$APP/Contents" -type f -exec shasum -a 256 {} \; | sort > "$STATE_AFTER"
cmp "$STATE_BEFORE" "$STATE_AFTER"
if [[ "${VOXASTER_UNSIGNED:-0}" != "1" ]]; then codesign --verify --deep --strict "$APP"; fi
echo "PASS: production Python launch configuration preserves bundle contents"
"$OMNI_PYTHON" -B - "$HERE/Backend/runtime.json" "$TEST_BUILD/release/VoxAster.app" <<'PY'
import json,plistlib,sys
from pathlib import Path
manifest=json.loads(Path(sys.argv[1]).read_text())
app=Path(sys.argv[2]); info=plistlib.loads((app/'Contents/Info.plist').read_bytes())
assert info['CFBundleShortVersionString']==manifest['native_app_version']
assert app.name == 'VoxAster.app'
assert info['CFBundleName'] == info['CFBundleDisplayName'] == 'VoxAster'
assert info['CFBundleExecutable'] == 'VoxAster'
assert (app/'Contents/MacOS'/info['CFBundleExecutable']).is_file()
assert info['CFBundleIconFile'] == 'VoxAster'
assert (app/'Contents/Resources/VoxAster.icns').is_file()
# Preserve macOS preferences/permission identity across the product rename.
assert info['CFBundleIdentifier'] == 'local.omnivoice.native'
assert info['NSMicrophoneUsageDescription'].startswith('VoxAster ')
assert not (app/'Contents/MacOS/OmniVoice').exists()
for name in ['backend.py','generation.py','speech_text.py','performance_script.py','performance_audio.py','performance.py','provenance.py','runtime.json','bootstrap.py','runtime_check.py','bootstrap-lock.json']:
 assert (app/'Contents/Resources'/name).read_bytes()==(Path(sys.argv[1]).parent/name).read_bytes()
source=Path(sys.argv[1]).parent.parent
for relative in ['LICENSE','THIRD_PARTY.md','PRIVACY.md','Notice','Licenses/BOSON-HIGGS-AUDIO-2.txt','Licenses/META-LLAMA-3.txt']:
 assert (app/'Contents/Resources'/relative).read_bytes()==(source/relative).read_bytes()
assert not (app/'Contents/Resources/training_safety.py').exists()
print('PASS: release bundle provenance, resources, licence notices (signature verification only in signed mode)')
PY

AUDIT_OPTIONS=()
if [[ "${VOXASTER_UNSIGNED:-0}" == "1" ]]; then AUDIT_OPTIONS+=(--unsigned); fi
"$OMNI_PYTHON" -B "$HERE/tools/audit-bundle.py" "$APP" "${AUDIT_OPTIONS[@]}" --inventory "$TEST_BUILD/bundle-inventory.json"
