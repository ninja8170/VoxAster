"""Identify the exact cached artifacts loaded, without upgrading/downloading."""
import hashlib
import importlib.metadata
import json
from pathlib import Path

MANIFEST = json.loads((Path(__file__).parent / 'runtime.json').read_text())


def resolve_base_model():
    from huggingface_hub import snapshot_download
    return Path(snapshot_download(MANIFEST['model_id'], revision=MANIFEST['model_revision'],
                                  local_files_only=True))


def runtime_provenance(model_path):
    distribution = importlib.metadata.distribution('omnivoice')
    direct = json.loads(distribution.read_text('direct_url.json') or '{}')
    commit = direct.get('vcs_info', {}).get('commit_id', 'unknown')
    tokenizer = model_path / 'tokenizer.json'
    return {
        'native_app_version': MANIFEST['native_app_version'],
        'package_version': distribution.version,
        'package_commit': commit,
        'model_id': MANIFEST['model_id'],
        'model_revision': model_path.name,
        'tokenizer_revision': model_path.name,
        'audio_tokenizer_revision': model_path.name,
        'tokenizer_sha256': hashlib.sha256(tokenizer.read_bytes()).hexdigest(),
        'audio_tokenizer_sha256': hashlib.sha256((model_path / 'audio_tokenizer' / 'config.json').read_bytes()).hexdigest(),
    }
