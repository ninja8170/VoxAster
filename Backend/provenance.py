"""Pinned local inference assets; never use an upstream tokenizer fallback."""
import hashlib
import importlib.metadata
import json
import os
from pathlib import Path
import tempfile

MANIFEST = json.loads((Path(__file__).parent / 'runtime.json').read_text())


# Audio artifacts embedded in the pre-migration pinned OmniVoice snapshot.
# Only this verified byte-identical migration may retain old production retries.
LEGACY_AUDIO_HASHES = {
    'model.safetensors': 'fe7c5e8785e0a05833e1bfc3e002ec7f55af21e306b2e7154a448c1f54ccfb0d',
    'config.json': 'eefb20806f7104e77c9a5277c9df0f9bb8826b08eb1d4e8ab2b9829b6ef9fac1',
    'preprocessor_config.json': 'ae61eea88558608ee2fa86d2aec9fce8d99a5ff75d09cb7651ccce21ae1d9084',
}


def compatible_production_runtime(recorded):
    if recorded == MANIFEST:
        return True
    core = {key: value for key, value in MANIFEST.items() if key != 'audio_tokenizer'}
    return (recorded == core
            and core['model_revision'] == 'c5fdb5ccb189668d56333f77ba2629f4cd7535f4'
            and all(MANIFEST['audio_tokenizer']['sha256'].get(name) == digest
                    for name, digest in LEGACY_AUDIO_HASHES.items()))


def file_sha256(path):
    digest = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for block in iter(lambda: stream.read(8 * 1024 * 1024), b''):
            digest.update(block)
    return digest.hexdigest()


def managed_asset(kind):
    root = os.environ.get('OMNIVOICE_MANAGED_ROOT')
    if not root:
        return None
    base = Path(root)
    lock = json.loads((Path(__file__).parent / 'bootstrap-lock.json').read_text())
    if lock['pins'] != MANIFEST:
        raise RuntimeError('Managed runtime pins differ from this app.')
    selected = [a for a in lock['artifacts'] if a['kind'] == kind]
    if not selected:
        raise RuntimeError('Managed asset manifest is incomplete.')
    for item in selected:
        path = base / item['destination']
        if file_sha256(path) != item['sha256']:
            raise RuntimeError('Managed model files are missing or changed. Repair VoxAster Runtime.')
    return (base / selected[0]['destination']).parent


def resolve_base_model():
    managed = managed_asset('model')
    if managed is not None:
        return managed
    from huggingface_hub import snapshot_download
    return Path(snapshot_download(MANIFEST['model_id'], revision=MANIFEST['model_revision'],
                                  ignore_patterns=['audio_tokenizer/*'], local_files_only=True))


def resolve_audio_tokenizer():
    from huggingface_hub import snapshot_download
    spec = MANIFEST['audio_tokenizer']
    managed = managed_asset('tokenizer')
    if managed is not None:
        return managed
    try:
        folder = Path(snapshot_download(spec['repo_id'], revision=spec['revision'], allow_patterns=list(spec['sha256']), local_files_only=True))
        if folder.name != spec['revision']:
            raise ValueError('Unexpected tokenizer snapshot revision.')
        for name, expected in spec['sha256'].items():
            if file_sha256(folder / name) != expected:
                raise ValueError(f'Official tokenizer hash mismatch: {name}.')
        return folder
    except (OSError, ValueError) as exc:
        raise RuntimeError('The verified Boson audio tokenizer is missing or invalid. Run prepare-models.command from this source checkout, then reopen VoxAster. No mirror fallback is allowed.') from exc


def download_models():
    from huggingface_hub import snapshot_download
    # Do not request the model repository's repackaged audio tokenizer.
    snapshot_download(MANIFEST['model_id'], revision=MANIFEST['model_revision'],
                      ignore_patterns=['audio_tokenizer/*'])
    spec = MANIFEST['audio_tokenizer']
    snapshot_download(spec['repo_id'], revision=spec['revision'], allow_patterns=list(spec['sha256']))
    resolve_audio_tokenizer()


def load_inference_model(model_path, **kwargs):
    """Point pinned upstream inference at official assets without changing it.

    Upstream loads audio_tokenizer/ when present. A verified local view always
    supplies it, including for existing saved engines. Missing/changed Boson
    artifacts fail before the upstream loader, never invoking its fallback.
    This view lives outside the signed bundle and is removed after eager load.
    """
    if kwargs.get('train'):
        raise ValueError('Training is not available in this release.')
    from omnivoice import OmniVoice
    source = Path(model_path).resolve(strict=True)
    if not source.is_dir():
        raise ValueError('Inference requires a local model directory.')
    official = resolve_audio_tokenizer()
    with tempfile.TemporaryDirectory(prefix='voxaster-inference-') as temporary:
        view = Path(temporary)
        for entry in source.iterdir():
            if entry.name != 'audio_tokenizer':
                (view / entry.name).symlink_to(entry.resolve(), target_is_directory=entry.is_dir())
        (view / 'audio_tokenizer').symlink_to(official, target_is_directory=True)
        # Fail closed if the verified directory disappeared before model loading.
        if not (view / 'audio_tokenizer/model.safetensors').is_file():
            raise RuntimeError('Official tokenizer became unavailable before inference loading.')
        return OmniVoice.from_pretrained(str(view), local_files_only=True, **kwargs)


def runtime_provenance(model_path):
    distribution = importlib.metadata.distribution('omnivoice')
    direct = json.loads(distribution.read_text('direct_url.json') or '{}')
    commit = direct.get('vcs_info', {}).get('commit_id', 'unknown')
    if os.environ.get('OMNIVOICE_MANAGED_ROOT'):
        lock = json.loads((Path(__file__).parent / 'bootstrap-lock.json').read_text())
        source = next(a for a in lock['artifacts'] if a['kind'] == 'source')
        archive_hash = direct.get('archive_info', {}).get('hashes', {}).get('sha256')
        if archive_hash != source['sha256']:
            raise RuntimeError('Installed OmniVoice archive differs from the pinned commit.')
        commit = source['revision']
    official = resolve_audio_tokenizer()
    return {
        'native_app_version': MANIFEST['native_app_version'],
        'package_version': distribution.version,
        'package_commit': commit,
        'model_id': MANIFEST['model_id'],
        'model_revision': model_path.name,
        'tokenizer_revision': model_path.name,
        'tokenizer_sha256': file_sha256(model_path / 'tokenizer.json'),
        'audio_tokenizer_source': MANIFEST['audio_tokenizer']['repo_id'],
        'audio_tokenizer_revision': MANIFEST['audio_tokenizer']['revision'],
        'audio_tokenizer_sha256': file_sha256(official / 'config.json'),
        'audio_tokenizer_weights_sha256': MANIFEST['audio_tokenizer']['sha256']['model.safetensors'],
    }
