"""Inference-only managed runtime installer. Standard library only until validation.

Network inputs come exclusively from the bundled, versioned lock. No shell, index
resolution, VCS client, source compiler, or writes to application resources.
"""
import argparse
import contextlib
import datetime
import fcntl
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import signal
import ssl
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

HOSTS = {'github.com', 'release-assets.githubusercontent.com', 'codeload.github.com',
         'files.pythonhosted.org', 'huggingface.co', 'us.aws.cdn.hf.co', 'cdn-lfs.huggingface.co',
         'cdn-lfs-us-1.huggingface.co', 'cas-bridge.xethub.hf.co'}
CHILD = None


def digest(path):
    h = hashlib.sha256()
    with Path(path).open('rb') as f:
        for block in iter(lambda: f.read(8 * 1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()


def atomic_json(path, value):
    temporary = path.with_name(path.name + '.' + uuid.uuid4().hex + '.tmp')
    with temporary.open('w') as f:
        json.dump(value, f, sort_keys=True)
        f.flush()
        os.fsync(f.fileno())
    os.replace(temporary, path)


def safe_child(root, relative):
    p = Path(relative)
    if p.is_absolute() or '..' in p.parts or not p.parts:
        raise ValueError('Unsafe managed path')
    result = root / p
    if not result.resolve().is_relative_to(root.resolve()):
        raise ValueError('Managed path escapes runtime directory')
    return result


def storage_path(root, relative='.'):
    """Mutable managed paths may not traverse symlinks (runtime-internal links are separate)."""
    root = Path(root).absolute()
    if root.is_symlink() or any(p.suffix.lower() == '.app' for p in [root.resolve(), *root.resolve().parents]):
        raise ValueError('Managed storage cannot be a symlink or inside an application bundle')
    result = root if relative == '.' else safe_child(root, relative)
    current = root
    for part in result.relative_to(root).parts:
        current = current / part
        if current.is_symlink():
            raise ValueError('Unexpected managed storage symlink')
    if result.exists() and not (result.is_dir() or result.is_file()):
        raise ValueError('Unexpected managed storage special file')
    if result.is_file() and result.stat().st_nlink != 1:
        raise ValueError('Unexpected managed storage hard link')
    return result


def prepare_storage(root):
    storage_path(root).mkdir(parents=True, exist_ok=True, mode=0o700)
    for name in ('downloads', 'staging', 'installations', 'logs', 'temporary', 'cache',
                 'cache/pip', 'cache/huggingface', 'cache/numba'):
        storage_path(root, name).mkdir(parents=True, exist_ok=True, mode=0o700)
    for name in ('logs/setup.log', 'installation.lock', 'active.json', 'state.json'):
        storage_path(root, name)


def check_url(url):
    p = urllib.parse.urlsplit(url)
    if p.scheme != 'https' or p.hostname not in HOSTS or p.username or p.password or p.port not in (None, 443):
        raise ValueError('Download source is not approved')


class Redirects(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        check_url(newurl)
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def fetch(url, destination, progress):
    check_url(url)
    # PBS ships a CA bundle with pip; do not depend on Homebrew's OpenSSL paths.
    import pip._vendor.certifi
    opener = urllib.request.build_opener(Redirects(), urllib.request.HTTPSHandler(
        context=ssl.create_default_context(cafile=pip._vendor.certifi.where())))
    try:
        with opener.open(url, timeout=60) as response, destination.open('wb') as f:
            while block := response.read(1024 * 1024):
                f.write(block)
                progress(len(block))
    except (urllib.error.URLError, TimeoutError, OSError) as exc:
        raise RuntimeError('Internet access is required to finish setup. Check your connection and retry; verified downloads are retained.') from exc


def emit(stage, **fields):
    print(json.dumps(dict(stage=stage, **fields)), flush=True)


def validate_lock(lock):
    if lock['schema'] != 1 or lock['architecture'] != 'arm64':
        raise ValueError('Unsupported runtime manifest')
    seen = set()
    for a in lock['artifacts']:
        check_url(a['url'])
        if urllib.parse.urlsplit(a['url']).query or urllib.parse.urlsplit(a['url']).fragment:
            raise ValueError('Locked URLs must not contain temporary query strings')
        if a['filename'] in ('', '.', '..') or Path(a['filename']).name != a['filename'] or a['filename'] in seen:
            raise ValueError('Invalid artifact filename')
        seen.add(a['filename'])
        if len(a['sha256']) != 64 or any(c not in '0123456789abcdef' for c in a['sha256']) or a['size'] <= 0:
            raise ValueError('Missing artifact integrity information')
        if not a['license']:
            raise ValueError('Artifact licence review missing')
        if a['kind'] in ('model', 'tokenizer'):
            safe_child(Path('/managed'), a['destination'])
    if sum(a['size'] for a in lock['artifacts']) != lock['download_bytes']:
        raise ValueError('Download size mismatch')


def cached_artifact(root, a, downloader=fetch, report=lambda *_: None):
    cache = storage_path(root, 'downloads')
    cache.mkdir(parents=True, exist_ok=True)
    target = storage_path(root, 'downloads/' + a['filename'])
    if target.is_file() and not target.is_symlink() and target.stat().st_size == a['size'] and digest(target) == a['sha256']:
        report(a['size'])
        return target
    part = storage_path(root, 'downloads/' + a['filename'] + '.partial')
    if part.is_symlink() or target.is_symlink():
        raise ValueError('Unexpected download symlink')
    # Interrupted partial files are safely restarted; complete verified files reused.
    received = 0
    def bounded_report(n):
        nonlocal received
        received += n
        if received > a['size']:
            raise ValueError('Download exceeded its pinned size')
        report(n)
    downloader(a['url'], part, bounded_report)
    if part.stat().st_size != a['size'] or digest(part) != a['sha256']:
        part.unlink(missing_ok=True)
        raise ValueError('Download verification failed for ' + a['name'] + '. Retry to download a clean copy.')
    os.replace(part, target)
    return target


def environment(root, installation):
    prepare_storage(root)
    env = {k: v for k, v in os.environ.items() if k not in ('VIRTUAL_ENV', '__PYVENV_LAUNCHER__', 'TAR_OPTIONS') and not k.startswith(('PYTHON', 'PIP_', 'DYLD_', 'HF_', 'HUGGINGFACE_', 'TRANSFORMERS_', 'XDG_', 'NUMBA_'))}
    env.update(PYTHONUNBUFFERED='1', PYTHONDONTWRITEBYTECODE='1', PYTHONNOUSERSITE='1', PIP_CONFIG_FILE=os.devnull,
               PIP_NO_INDEX='1', PIP_DISABLE_PIP_VERSION_CHECK='1', PIP_NO_COMPILE='1',
               PIP_NO_CACHE_DIR='1', PIP_CACHE_DIR=str(root/'cache/pip'), XDG_CACHE_HOME=str(root/'cache'),
               HF_HUB_DISABLE_TELEMETRY='1', DO_NOT_TRACK='1',
               HF_HOME=str(root/'cache/huggingface'), NUMBA_CACHE_DIR=str(root/'cache/numba'),
               TMPDIR=str(root/'temporary'), OMNIVOICE_MANAGED_ROOT=str(installation),
               PATH=str(installation/'python/bin') + ':/usr/bin:/bin:/usr/sbin:/sbin')
    return env


def run(args, env, log, timeout=600):
    global CHILD
    CHILD = subprocess.Popen([str(a) for a in args], env=env, cwd=env['TMPDIR'], stdout=log, stderr=log)
    try:
        code = CHILD.wait(timeout=timeout)
        if code:
            raise RuntimeError('Runtime installation or validation failed. See the setup log, then retry or repair.')
    finally:
        if CHILD.poll() is None:
            CHILD.terminate()
            try: CHILD.wait(timeout=10)
            except subprocess.TimeoutExpired:
                CHILD.kill(); CHILD.wait()
        CHILD = None


def cancel(_sig, _frame):
    if CHILD and CHILD.poll() is None:
        CHILD.terminate()
    raise InterruptedError('Setup cancelled. Verified downloads are retained; retry when ready.')


def inventory(folder):
    entries = {}
    for p in sorted(folder.rglob('*')):
        rel = str(p.relative_to(folder))
        if p.is_symlink():
            if not p.resolve().is_relative_to(folder.resolve()):
                raise ValueError('Runtime contains an external symlink: ' + rel)
            entries[rel] = {'link': os.readlink(p)}
        elif p.is_file() and rel != 'installation.json':
            entries[rel] = {'sha256': digest(p), 'size': p.stat().st_size}
    return entries


def verify_installation(folder, lock_hash, lock):
    receipt = json.loads((folder/'installation.json').read_text())
    if receipt['state'] != 'READY' or receipt['lock_sha256'] != lock_hash or receipt['architecture'] != 'arm64':
        raise ValueError('Runtime version differs from this app. Repair the managed runtime.')
    if receipt['files'] != inventory(folder):
        raise ValueError('Managed runtime files are missing or changed. Repair VoxAster Runtime.')
    for a in lock['artifacts']:
        if a['kind'] in ('model','tokenizer'):
            p = safe_child(folder, a['destination'])
            if p.stat().st_size != a['size'] or digest(p) != a['sha256']:
                raise ValueError('Model verification failed. Repair VoxAster Runtime.')
    return receipt


def active_installation(root):
    active = json.loads((root/'active.json').read_text())
    name = active['installation']
    if not name.startswith('installations/') or len(Path(name).parts) != 2:
        raise ValueError('Invalid active runtime record')
    return safe_child(root, name)


def install(root, stage, lock, lock_hash, resources, downloader=fetch, installer=None, validator=None):
    """Caller holds flock. Injectable artifact/install/validation seams for fixtures."""
    validate_lock(lock)
    prepare_storage(root)
    storage_path(root, str(stage.relative_to(root)))
    if stage.parent != root/'staging' or stage.is_symlink():
        raise ValueError('Installation must use private staging')
    atomic_json(root/'state.json', dict(state='INSTALLING', stage=stage.name, lock_sha256=lock_hash))
    completed = 0
    def report(n):
        nonlocal completed
        completed += n
        emit('Downloading models' if a['kind'] in ('model', 'tokenizer') else 'Preparing runtime', completed=completed, total=lock['download_bytes'])
    downloads = {}
    for a in lock['artifacts']:
        emit('Downloading models' if a['kind'] in ('model', 'tokenizer') else 'Preparing runtime')
        downloads[a['filename']] = cached_artifact(root, a, downloader, report)
    if installer:
        installer(stage, downloads)
    else:
        env = environment(root, stage)
        python = stage/'python/bin/python3'
        with (root/'logs/setup.log').open('ab', buffering=0) as log:
            emit('Installing voice engine')
            wheels = [downloads[a['filename']] for a in lock['artifacts'] if a['kind']=='wheel']
            run([python, '-B', '-m', 'pip', 'install', '--no-index', '--no-deps', '--no-compile', *wheels], env, log)
            run([python, '-B', '-m', 'pip', 'check'], env, log)
            source = next(a for a in lock['artifacts'] if a['kind']=='source')
            run([python, '-B', '-m', 'pip', 'install', '--no-index', '--no-deps', '--no-build-isolation', '--no-compile', downloads[source['filename']]], env, log)
            run([python, '-B', '-m', 'pip', 'check'], env, log)
        ffmpeg = next((stage/'python/lib/python3.12/site-packages/imageio_ffmpeg/binaries').glob('ffmpeg-*'))
        ffmpeg.chmod(0o755)
        (stage/'python/bin/ffmpeg').symlink_to(os.path.relpath(ffmpeg, stage/'python/bin'))
        for a in lock['artifacts']:
            if a['kind'] in ('model','tokenizer'):
                target = safe_child(stage, a['destination'])
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(downloads[a['filename']], target)
        # Source origin attestation supplements pip's archive hash, never invents VCS metadata.
        atomic_json(stage/'source.json', dict(commit=source['revision'], sha256=source['sha256']))
    emit('Verifying files')
    if validator:
        validator(stage)
    else:
        validate_runtime(root, stage, resources, lock)
    receipt = dict(schema=1, state='READY', architecture='arm64', lock_sha256=lock_hash,
                   runtime_id=lock['runtime_id'], app_version=lock['app_version'], pins=lock['pins'],
                   packages={a['name']: a['version'] for a in lock['artifacts'] if a['kind'] in ('wheel','source','python')},
                   installed_at=datetime.datetime.now(datetime.timezone.utc).isoformat(), files=inventory(stage))
    atomic_json(stage/'installation.json', receipt)
    verify_installation(stage, lock_hash, lock)
    final = root/'installations'/stage.name
    final.parent.mkdir(exist_ok=True)
    os.replace(stage, final)
    # This tiny atomic pointer is the only activation step. Previous installations stay intact.
    atomic_json(root/'active.json', dict(installation=str(final.relative_to(root)), lock_sha256=lock_hash))
    atomic_json(root/'state.json', dict(state='READY', installation=str(final.relative_to(root)), lock_sha256=lock_hash))
    emit('Runtime verified', installation=str(final))
    return final


def validate_runtime(root, folder, resources, lock):
    env = environment(root, folder)
    env['HF_HUB_OFFLINE'] = '1'
    env['TRANSFORMERS_OFFLINE'] = '1'
    with (root/'logs/setup.log').open('ab', buffering=0) as log:
        run([folder/'python/bin/python3', '-B', resources/'runtime_check.py', '--python-version', lock['python_version']], env, log)
        run([folder/'python/bin/ffmpeg','-version'], env, log)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--stage', type=Path)
    parser.add_argument('--resources', type=Path, required=True)
    parser.add_argument('--verify', action='store_true')
    args = parser.parse_args()
    root = args.root.absolute()
    if root.resolve().is_relative_to(args.resources.resolve()):
        raise ValueError('Runtime cannot live in application resources')
    prepare_storage(root)
    lock_path = args.resources/'bootstrap-lock.json'
    lock = json.loads(lock_path.read_text()); lock_hash = digest(lock_path)
    if platform.system() != 'Darwin' or platform.machine() != 'arm64':
        raise ValueError('VoxAster runtime requires Apple Silicon macOS.')
    if root.is_relative_to(args.resources.resolve()):
        raise ValueError('Runtime cannot live in the application bundle')
    signal.signal(signal.SIGTERM, cancel)
    signal.signal(signal.SIGINT, cancel)
    with (root/'installation.lock').open('a') as handle:
        try: fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError: raise RuntimeError('Another VoxAster setup is running. Wait for it to finish.')
        if args.verify:
            folder = active_installation(root)
            validate_lock(lock)
            verify_installation(folder, lock_hash, lock)
            validate_runtime(root, folder, args.resources, lock)
            emit('Runtime verified', installation=str(folder))
        else:
            try:
                install(root, args.stage.absolute(), lock, lock_hash, args.resources)
            except Exception:
                atomic_json(root/'state.json', dict(state='NEEDS_REPAIR' if (root/'active.json').exists() else 'INCOMPLETE', lock_sha256=lock_hash))
                raise


if __name__ == '__main__':
    try:
        main()
    except Exception as exc:
        import traceback
        traceback.print_exc(file=sys.stderr)
        emit('Setup needs attention', error=str(exc))
        sys.exit(1)
