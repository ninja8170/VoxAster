#!/usr/bin/env python3
"""Fail closed on additions to the audited native-only bundle; never notarizes."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
BACKEND = ('backend.py', 'generation.py', 'speech_text.py', 'performance.py',
           'performance_audio.py', 'performance_script.py', 'provenance.py', 'runtime.json',
           'bootstrap.py', 'runtime_check.py', 'bootstrap-lock.json')
NOTICES = ('LICENSE', 'THIRD_PARTY.md', 'PRIVACY.md', 'Notice',
           'Licenses/BOSON-HIGGS-AUDIO-2.txt', 'Licenses/META-LLAMA-3.txt')
ENTITLEMENTS = {'com.apple.security.device.audio-input': True}


def run(*args):
    return subprocess.check_output(args, stderr=subprocess.PIPE)


def audit(app, unsigned=False):
    expected = {'Contents/Info.plist', 'Contents/MacOS/VoxAster',
                'Contents/_CodeSignature/CodeResources', 'Contents/Resources/VoxAster.icns'}
    if unsigned:
        expected.remove('Contents/_CodeSignature/CodeResources')
    expected.update('Contents/Resources/' + name for name in BACKEND + NOTICES)
    allowed_dirs = {str(parent) for name in expected for parent in Path(name).parents if str(parent) != '.'}
    entries = sorted(app.rglob('*'))
    actual = set()
    for path in entries:
        relative = str(path.relative_to(app))
        assert not path.is_symlink(), f'Unexpected symlink: {relative}'
        if path.is_dir():
            assert relative in allowed_dirs, f'Unexpected directory: {relative}'
        else:
            assert path.is_file(), f'Unexpected special file: {relative}'
            actual.add(relative)
    assert actual == expected, f'Bundle file set differs: {sorted(actual ^ expected)}'
    for name in BACKEND + NOTICES:
        source = ROOT / ('Backend' if name in BACKEND else '') / name
        assert (app / 'Contents/Resources' / name).read_bytes() == source.read_bytes(), f'Resource mismatch: {name}'
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    manifest = json.loads((ROOT / 'Backend/runtime.json').read_text())
    assert info['CFBundleIdentifier'] == 'local.omnivoice.native'
    assert info['CFBundleExecutable'] == info['CFBundleName'] == info['CFBundleDisplayName'] == 'VoxAster'
    assert info['CFBundleShortVersionString'] == info['CFBundleVersion'] == manifest['native_app_version']
    assert info['LSMinimumSystemVersion'] == '14.0'
    for key in ('NSMicrophoneUsageDescription', 'NSDocumentsFolderUsageDescription'):
        assert info[key].startswith('VoxAster '), f'Missing branded purpose: {key}'
    assert 'LSEnvironment' not in info, 'Test launch environment must not be distributed'
    binary = app / 'Contents/MacOS/VoxAster'
    assert run('lipo', '-archs', str(binary)).decode().strip() == 'arm64'
    build = run('xcrun', 'vtool', '-show-build', str(binary)).decode()
    assert re.search(r'\bminos 14\.0\b', build), 'Mach-O deployment target differs from Info.plist'
    dependencies = run('otool', '-L', str(binary)).decode().splitlines()[1:]
    assert all(line.strip().startswith(('/System/Library/', '/usr/lib/')) for line in dependencies), 'Non-system dylib dependency'
    load_commands = run('otool', '-l', str(binary)).decode()
    for rpath in re.findall(r'cmd LC_RPATH\s+cmdsize \d+\s+path (.*?) \(offset', load_commands):
        assert rpath in ('/usr/lib/swift', '@executable_path/../Frameworks'), 'Developer-specific runtime search path'
    details = 'unsigned verification build'
    entitlements = ENTITLEMENTS
    if not unsigned:
        details = subprocess.run(['codesign', '-dvv', str(app)], capture_output=True, check=True).stderr.decode()
        assert re.search(r'flags=.*\bruntime\b', details), 'Hardened Runtime missing'
        entitlements = plistlib.loads(run('codesign', '-d', '--entitlements', '-', '--xml', str(app)))
        assert entitlements == ENTITLEMENTS, f'Unexpected entitlement set: {sorted(entitlements)}'
        run('codesign', '--verify', '--deep', '--strict', str(app))
    inventory = []
    for relative in sorted(actual):
        path = app / relative
        data = path.read_bytes()
        assert not re.search(rb'/' + rb'(Users|home)/[^/\s]+/', data), f'Personal absolute path: {relative}'
        if relative.endswith(('BOSON-HIGGS-AUDIO-2.txt', 'META-LLAMA-3.txt', '/Notice')):
            category = 'third-party licence/attribution text; no implementation or weights'
        elif relative.endswith('/CodeResources'):
            category = 'generated signing metadata'
        else:
            category = 'original VoxAster code/resource or generated app metadata'
        inventory.append(dict(path=relative, bytes=len(data), sha256=hashlib.sha256(data).hexdigest(), category=category))
    return dict(files=inventory, file_count=len(inventory), total_bytes=sum(x['bytes'] for x in inventory),
                architecture='arm64', minimum_macos='14.0', hardened_runtime=None if unsigned else True,
                signing='unsigned verification build' if unsigned else 'ad-hoc' if 'Signature=adhoc' in details else 'certificate (inspect authority separately)',
                entitlements=None if unsigned else entitlements, system_dependencies=[line.strip() for line in dependencies])


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path)
    parser.add_argument('--unsigned', action='store_true', help='Structure/resource checks only; never signing clearance')
    parser.add_argument('--inventory', type=Path, help='Write complete inventory outside the app')
    args = parser.parse_args()
    if args.inventory:
        assert not args.inventory.resolve().is_relative_to(args.app.resolve()), 'Do not mutate signed bundle'
    result = audit(args.app, args.unsigned)
    if args.inventory:
        args.inventory.write_text(json.dumps(result, indent=2) + '\n')
    print("UNSIGNED: signature and runtime-entitlement validation not performed" if args.unsigned else "Signature and entitlements verified")
    print(f"PASS: {result['file_count']} approved files; arm64/macOS 14; resource/architecture audit. Not a notarization clearance.")
