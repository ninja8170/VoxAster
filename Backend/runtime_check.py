"""Offline preflight; no model loading or synthesis, no resource writes."""
import argparse
import json
import platform
import sys
from pathlib import Path


def check(expected_python=None):
    if platform.machine() != 'arm64' or sys.version_info[:2] != (3, 12):
        raise RuntimeError('Apple Silicon Python 3.12 is required.')
    if expected_python and platform.python_version() != expected_python:
        raise RuntimeError('Unexpected managed Python version.')
    import fastapi, uvicorn, multipart, httpx, torch, torchaudio, soundfile, librosa
    import omnivoice
    from provenance import MANIFEST, resolve_base_model, runtime_provenance
    if not torch.backends.mps.is_available():
        raise RuntimeError('Apple Silicon MPS is unavailable.')
    p = runtime_provenance(resolve_base_model())
    for key, expected in [('package_version',MANIFEST['expected_package_version']),
                          ('package_commit',MANIFEST['expected_package_commit']),
                          ('model_revision',MANIFEST['model_revision']),
                          ('tokenizer_revision',MANIFEST['model_revision']),
                          ('audio_tokenizer_revision',MANIFEST['audio_tokenizer']['revision'])]:
        if p[key] != expected:
            raise RuntimeError('Runtime provenance mismatch: '+key)
    return p


if __name__ == '__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--python-version')
    print(json.dumps(check(parser.parse_args().python_version)))
