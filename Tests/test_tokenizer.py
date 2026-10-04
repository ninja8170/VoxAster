"""Official inference assets, fail-closed adapter and removed training surface."""
import copy
import hashlib
import importlib
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock, patch
import numpy as np
from fastapi.testclient import TestClient
import backend
import provenance


class OfficialTokenizerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='voxaster-tokenizer-test-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.manifest = copy.deepcopy(provenance.MANIFEST)
        self.official = self.root / self.manifest['audio_tokenizer']['revision']
        self.official.mkdir()
        for name in self.manifest['audio_tokenizer']['sha256']:
            data = ('test artifact ' + name).encode()
            (self.official / name).write_bytes(data)
            self.manifest['audio_tokenizer']['sha256'][name] = hashlib.sha256(data).hexdigest()
        self.source = self.root / 'saved-engine'
        self.source.mkdir()
        (self.source / 'config.json').write_text('{}')
        (self.source / 'model.safetensors').write_bytes(b'saved model')
        (self.source / 'audio_tokenizer').mkdir()
        (self.source / 'audio_tokenizer/untrusted').write_text('must not load')
        self.manifest_patch = patch.object(provenance, 'MANIFEST', self.manifest)
        self.manifest_patch.start()
        self.addCleanup(self.manifest_patch.stop)
        self.download_patch = patch('huggingface_hub.snapshot_download', return_value=str(self.official))
        self.download = self.download_patch.start()
        self.addCleanup(self.download_patch.stop)

    def test_resolution_is_official_pinned_and_local_only(self):
        self.assertEqual(provenance.resolve_audio_tokenizer(), self.official)
        self.download.assert_called_once_with('bosonai/higgs-audio-v2-tokenizer',
            revision=self.manifest['audio_tokenizer']['revision'], allow_patterns=list(self.manifest['audio_tokenizer']['sha256']), local_files_only=True)

    def test_missing_or_tampered_artifact_fails_before_upstream(self):
        for name in self.manifest['audio_tokenizer']['sha256']:
            original = (self.official / name).read_bytes()
            for tampered in (None, b'changed'):
                with self.subTest(name=name, tampered=tampered), patch.object(backend.OmniVoice, 'from_pretrained') as upstream:
                    if tampered is None:
                        (self.official / name).unlink()
                    else:
                        (self.official / name).write_bytes(tampered)
                    with self.assertRaisesRegex(RuntimeError, 'No mirror fallback'):
                        provenance.load_inference_model(self.source)
                    upstream.assert_not_called()
                    (self.official / name).write_bytes(original)

    def test_cache_absent_or_wrong_revision_is_actionable(self):
        from huggingface_hub.errors import LocalEntryNotFoundError
        with patch('huggingface_hub.snapshot_download', side_effect=LocalEntryNotFoundError('not cached')):
            with self.assertRaisesRegex(RuntimeError, 'prepare-models.command'):
                provenance.resolve_audio_tokenizer()
        with patch('huggingface_hub.snapshot_download', return_value=str(self.root)):
            with self.assertRaises(RuntimeError):
                provenance.resolve_audio_tokenizer()

    def test_view_preserves_model_overrides_embedded_tokenizer_and_cleans_up(self):
        viewed = []
        expected = object()
        def loader(path, **kwargs):
            view = Path(path); viewed.append(view)
            self.assertEqual((view/'config.json').resolve(), (self.source/'config.json').resolve())
            self.assertEqual((view/'model.safetensors').read_bytes(), b'saved model')
            self.assertEqual((view/'audio_tokenizer').resolve(), self.official)
            self.assertFalse((view/'audio_tokenizer/untrusted').exists())
            self.assertEqual(kwargs, {'local_files_only':True, 'device_map':'mps', 'dtype':'test'})
            return expected
        with patch.object(backend.OmniVoice, 'from_pretrained', side_effect=loader):
            self.assertIs(provenance.load_inference_model(self.source, device_map='mps', dtype='test'), expected)
        self.assertFalse(viewed[0].exists())
        self.assertTrue((self.source/'audio_tokenizer/untrusted').exists())

    def test_failed_load_removes_view_without_modifying_assets(self):
        paths = []
        def fail(path, **kwargs):
            paths.append(Path(path)); raise RuntimeError('load failure')
        with patch.object(backend.OmniVoice, 'from_pretrained', side_effect=fail):
            with self.assertRaisesRegex(RuntimeError, 'load failure'):
                provenance.load_inference_model(self.source)
        self.assertFalse(paths[0].exists())
        self.assertTrue((self.source/'model.safetensors').exists())
        self.assertTrue((self.official/'model.safetensors').exists())

    def test_adapter_rejects_training_before_loading(self):
        with patch.object(backend.OmniVoice, 'from_pretrained') as upstream:
            with self.assertRaisesRegex(ValueError, 'Training'):
                provenance.load_inference_model(self.source, train=True)
            upstream.assert_not_called()
        self.download.assert_not_called()

    def test_setup_downloads_only_pinned_sources_then_verifies(self):
        provenance.download_models()
        self.assertEqual(len(self.download.call_args_list), 3)
        base, audio, verified = self.download.call_args_list
        self.assertEqual(base.args, (self.manifest['model_id'],))
        self.assertEqual(base.kwargs, dict(revision=self.manifest['model_revision'], ignore_patterns=['audio_tokenizer/*']))
        self.assertEqual(audio.args, ('bosonai/higgs-audio-v2-tokenizer',))
        self.assertEqual(audio.kwargs, dict(revision=self.manifest['audio_tokenizer']['revision'], allow_patterns=list(self.manifest['audio_tokenizer']['sha256'])))
        self.assertTrue(verified.kwargs['local_files_only'])

    def test_real_upstream_branch_uses_official_local_directory(self):
        # Exercise the pinned upstream from_pretrained method itself, mocking heavy
        # tensor/tokenizer loaders only. Any remote/fallback resolution fails.
        module = importlib.import_module('omnivoice.models.omnivoice')
        resolved = []
        def local_only(path):
            self.assertTrue(Path(path).is_dir(), 'Upstream attempted nonlocal resolution')
            resolved.append(path); return path
        fake = Mock(); fake.device = 'mps'
        parent = backend.OmniVoice.__mro__[1]
        with patch.object(parent, 'from_pretrained', return_value=fake), \
             patch.object(module, '_resolve_model_path', side_effect=local_only), \
             patch.object(module.AutoTokenizer, 'from_pretrained'), \
             patch.object(module.AutoFeatureExtractor, 'from_pretrained'), \
             patch.object(module.HiggsAudioV2TokenizerModel, 'from_pretrained') as audio:
            def check_audio(path, **kwargs):
                self.assertEqual(Path(path).resolve(), self.official)
                return Mock()
            audio.side_effect = check_audio
            self.assertIs(provenance.load_inference_model(self.source), fake)
        self.assertEqual(len(resolved), 1)
        audio.assert_called_once()


class PublicInferenceSurfaceTests(unittest.TestCase):
    def test_training_mutations_gone_without_subprocess_or_data_changes(self):
        client = TestClient(backend.app, base_url='http://127.0.0.1:8011')
        with patch('subprocess.Popen') as spawn, patch('subprocess.run') as run:
            for route in ('prepare','train','merge','save-engine'):
                response = client.post('/personal/'+route, data={'name':'test','dataset':'/not-used'})
                self.assertEqual(response.status_code, 410)
                self.assertIn('not available', response.json()['detail'])
            self.assertEqual(client.get('/personal/train-status').status_code, 404)
            spawn.assert_not_called(); run.assert_not_called()
        self.assertFalse(hasattr(backend, 'personal_prepare'))
        self.assertFalse(hasattr(backend, 'personal_train'))

    def test_existing_personal_model_keeps_inference_through_adapter(self):
        with tempfile.TemporaryDirectory() as temporary:
            model_dir = Path(temporary); (model_dir/'config.json').write_text('{}')
            model = Mock(); model.generate.return_value = [np.zeros(240, dtype=np.float32)]
            with patch.object(backend, 'PERSONAL_MERGED', model_dir), patch.object(backend, 'load_inference_model', return_value=model) as load:
                client = TestClient(backend.app, base_url='http://127.0.0.1:8011')
                response = client.post('/personal/generate', data={'text':'Test.', 'ref_text':'Reference.'}, files={'audio':('ref.wav', b'reference', 'audio/wav')})
                self.assertEqual(response.status_code, 200, response.text)
                self.assertTrue(response.content.startswith(b'RIFF'))
                self.assertEqual(load.call_args.args[0], str(model_dir))
                model.generate.assert_called_once()
