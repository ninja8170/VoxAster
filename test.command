#!/bin/zsh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OMNI_PYTHON="${OMNIVOICE_PYTHON:-$HOME/Documents/OmniVoice-Mac/.venv/bin/python}"
TEST_BUILD="${1:-$HERE/.build/tests}"
mkdir -p "$TEST_BUILD"
PYTHONPATH="$HERE/Backend" "$OMNI_PYTHON" -B -m unittest discover -s "$HERE/Tests" -p 'test_*.py' -v
swiftc -D PHASE1_TESTS "$HERE"/Sources/*.swift "$HERE/Tests/GenerationTests.swift" -parse-as-library -framework SwiftUI -framework AppKit -framework AVFoundation -module-cache-path "$TEST_BUILD/module-cache" -o "$TEST_BUILD/ui-tests"
"$TEST_BUILD/ui-tests"
zsh -n "$HERE/build.command" "$HERE/install.command" "$HERE/test.command"
"$HERE/build.command" "$TEST_BUILD/release"
codesign --verify --deep --strict "$TEST_BUILD/release/OmniVoice.app"
"$OMNI_PYTHON" -B - "$HERE/Backend/runtime.json" "$TEST_BUILD/release/OmniVoice.app" <<'PY'
import json,plistlib,sys
from pathlib import Path
manifest=json.loads(Path(sys.argv[1]).read_text())
app=Path(sys.argv[2]); info=plistlib.loads((app/'Contents/Info.plist').read_bytes())
assert info['CFBundleShortVersionString']==manifest['native_app_version']
for name in ['backend.py','generation.py','provenance.py','runtime.json']:
 assert (app/'Contents/Resources'/name).read_bytes()==(Path(sys.argv[1]).parent/name).read_bytes()
print('PASS: release bundle provenance, resources and code signature')
PY
