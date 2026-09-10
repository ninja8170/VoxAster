"""Bounded filesystem transactions. No model imports or synthesis.

Publication uses a same-volume atomic directory exchange on macOS (Linux
renameat2 in tests/other hosts). Unsupported filesystems fail closed. The old
asset remains untouched until staging passes validation. Not a backup service.
"""
import ctypes
import errno
import fcntl
import json
import os
from pathlib import Path
import shutil
import sys
import tempfile
from contextlib import contextmanager
from subprocess import run as read_process_table


def reject_overlap(a, b):
    a, b = Path(a).resolve(), Path(b).resolve()
    if a == b or a in b.parents or b in a.parents:
        raise ValueError(f'Unsafe overlapping paths: {a} and {b}. Choose a separate source/destination.')


def managed_destination(path, root):
    path, root = Path(path), Path(root)
    if path.is_symlink() or root.resolve() not in path.resolve().parents:
        raise ValueError('Destination must be an ordinary managed child directory, not a symlink or external path.')
    return path


class OperationLock:
    """Inherited by app-launched training; survives loss of the backend parent.

    Close, never explicitly unlock: the training shell retains the same open
    file description through pass_fds until it and its children exit.
    """
    def __init__(self, root):
        self.path = Path(root) / '.publication.lock'
        self.fd = None

    def __enter__(self):
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.fd = os.open(self.path, os.O_CREAT | os.O_RDWR, 0o600)
        try:
            fcntl.flock(self.fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError as exc:
            os.close(self.fd); self.fd = None
            if exc.errno in (errno.EACCES, errno.EAGAIN):
                raise RuntimeError('Training or another dataset/model operation is active. Wait for it to finish before preparing or publishing.') from exc
            raise
        return self

    def __exit__(self, *_):
        if self.fd is not None:
            os.close(self.fd); self.fd = None


@contextmanager
def staging_directory(destination):
    destination = Path(destination)
    destination.parent.mkdir(parents=True, exist_ok=True)
    stage = Path(tempfile.mkdtemp(prefix='.' + destination.name + '-staging-', dir=destination.parent))
    try:
        yield stage
    finally:
        # After exchange, this path contains the old asset. Publication is complete.
        # Cleanup failure must not misreport a successful commit as a failed one.
        if stage.exists():
            shutil.rmtree(stage, ignore_errors=True)


def publish_directory(stage, destination):
    stage, destination = Path(stage), Path(destination)
    if stage.is_symlink() or destination.is_symlink():
        raise ValueError('Refusing to publish through a directory symlink.')
    reject_overlap(stage, destination)
    if stage.parent.resolve() != destination.parent.resolve():
        raise ValueError('Publication staging must be a sibling on the destination filesystem.')
    if not destination.exists():
        os.rename(stage, destination)
        return
    if not destination.is_dir():
        raise ValueError('Existing destination is not a directory; it was preserved.')
    libc = ctypes.CDLL(None, use_errno=True)
    if sys.platform == 'darwin':
        exchange = libc.renamex_np
        exchange.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
        result = exchange(os.fsencode(stage), os.fsencode(destination), 2)  # RENAME_SWAP
    elif hasattr(libc, 'renameat2'):
        exchange = libc.renameat2
        exchange.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
        result = exchange(-100, os.fsencode(stage), -100, os.fsencode(destination), 2)
    else:
        raise RuntimeError('Atomic directory replacement is unavailable here. Existing asset preserved; publication disabled on this filesystem.')
    if result:
        code = ctypes.get_errno()
        raise OSError(code, 'Atomic publication failed; previous asset preserved: ' + os.strerror(code))


def atomic_json(path, value):
    path = Path(path)
    fd, temporary = tempfile.mkstemp(prefix='.' + path.name + '-', dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as stream:
            json.dump(value, stream, ensure_ascii=False, indent=2)
            stream.flush(); os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def validate_model(folder):
    folder = Path(folder)
    required = ('config.json', 'model.safetensors', 'tokenizer.json', 'tokenizer_config.json',
                'audio_tokenizer/config.json', 'audio_tokenizer/model.safetensors',
                'audio_tokenizer/preprocessor_config.json')
    for name in required:
        p = folder / name
        if folder.resolve() not in p.resolve().parents or p.is_symlink() or not p.is_file() or not p.stat().st_size:
            raise ValueError(f'Merge is incomplete: missing/empty {name}. Previous model preserved.')
        if name.endswith('.json') and not isinstance(json.loads(p.read_text()), dict):
            raise ValueError(f'Merged configuration is invalid: {name}.')
    from tokenizers import Tokenizer
    Tokenizer.from_file(str(folder / 'tokenizer.json'))
    # Check readable tensor headers without loading model weights or inference.
    from safetensors import safe_open
    for name in ('model.safetensors', 'audio_tokenizer/model.safetensors'):
        with safe_open(str(folder / name), framework='numpy') as weights:
            if not list(weights.keys()):
                raise ValueError(f'Merged model contains no tensors: {name}.')


def validate_dataset(stage, destination):
    import numpy as np
    import soundfile as sf
    stage, destination = Path(stage), Path(destination)
    count = 0
    for name in ('train.jsonl', 'dev.jsonl'):
        rows = [json.loads(line) for line in (stage / name).read_text().splitlines() if line.strip()]
        if not rows:
            raise ValueError('Prepared dataset has an empty split; previous dataset preserved.')
        for row in rows:
            relative = Path(row['audio_path']).relative_to(destination)
            target = stage / relative
            if stage.resolve() not in target.resolve().parents or target.is_symlink() or not row['text'].strip():
                raise ValueError('Invalid staged dataset entry.')
            audio, rate = sf.read(target)
            if rate != 24000 or audio.ndim != 1 or not len(audio) or not np.isfinite(audio).all():
                raise ValueError('Invalid staged dataset audio.')
            count += 1
    if count < 2:
        raise ValueError('At least two valid clips are required.')


def reject_legacy_training(root):
    # Older app versions/manual launchers do not inherit our lock. Fail closed
    # if the process table is unavailable or a known training command is active.
    try:
        result = read_process_table(['/bin/ps', '-axww', '-o', 'command='], capture_output=True, text=True, timeout=5)
    except Exception as exc:
        raise RuntimeError("Cannot inspect active training processes; preparation/publishing are temporarily unavailable. Check process-inspection permissions, then retry.") from exc
    if result.returncode != 0:
        raise RuntimeError('Cannot verify active training processes. Dataset/model publication is unavailable until that check succeeds.')
    roots = {str(Path(root).absolute()), str(Path(root).resolve())}
    for command in result.stdout.splitlines():
        if any(root in command for root in roots) and any(marker in command for marker in ('run-lora.command', 'extract_audio_tokens', 'train-lora', 'omnivoice.cli.train', 'omnivoice-merge-lora')):
            raise RuntimeError('An existing training/merge process is active for this data directory. Finish it before preparing or publishing.')
