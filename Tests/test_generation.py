import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock, patch
import numpy as np

ROOT = tempfile.TemporaryDirectory(prefix='voxaster-phase1-tests-')
os.environ['OMNIVOICE_DATA_ROOT'] = ROOT.name
from fastapi.testclient import TestClient
import backend
from generation import GenerationRequest, apply_pronunciations, F5_CAPABILITIES
from provenance import runtime_provenance, resolve_base_model, MANIFEST


class GenerationTests(unittest.TestCase):
    def setUp(self):
        self.model = Mock()
        self.model.generate.return_value = [np.zeros(24, dtype=np.float32)]
        self.model.create_voice_clone_prompt.return_value = 'prompt'
        backend.MODEL = self.model
        self.client = TestClient(backend.app, base_url="http://127.0.0.1:8011")
        self.seed_patch = patch.object(backend, 'apply_seed')
        self.seed = self.seed_patch.start()
        self.addCleanup(self.seed_patch.stop)
        self.data = dict(text='The bass [laughter] [B EY1 S].', ref_text='bass reference',
            pronunciations='bass=[B EY1 S]\nS=ess\nlaughter=ha ha', language='English',
            speed='1.23', steps='43', guidance='3.1', seed='123', denoise='false')

    def post(self, route, data=None):
        return self.client.post(route, data=data or self.data,
            files={'ref_audio': ('ref.wav', b'test', 'audio/wav')})

    def assert_settings(self, call, text='The [B EY1 S] [laughter] [B EY1 S].'):
        args = call.kwargs
        self.assertEqual(args['text'], text)
        self.assertEqual(args['language'], 'en')
        self.assertEqual(args['speed'], 1.23)
        config = args['generation_config']
        self.assertEqual(config.num_step, 43)
        self.assertEqual(config.guidance_scale, 3.1)
        self.assertIs(config.denoise, False)

    def test_clone_controls_and_reference_not_rewritten(self):
        self.assertEqual(self.post('/generate-clone').status_code, 200)
        self.assert_settings(self.model.generate.call_args)
        self.assertEqual(self.model.create_voice_clone_prompt.call_args.kwargs['ref_text'], 'bass reference')
        self.seed.assert_called_once_with(123)

    def test_design_controls(self):
        data = dict(self.data, instruct='male, whisper')
        self.assertEqual(self.post('/generate-design', data).status_code, 200)
        self.assert_settings(self.model.generate.call_args)
        self.assertEqual(self.model.generate.call_args.kwargs['instruct'], 'male, whisper')
        self.assertNotIn('voice_clone_prompt', self.model.generate.call_args.kwargs)

    def test_variants_all_controls_and_distinct_seeds(self):
        self.assertEqual(self.post('/generate-variants', dict(self.data, count='3')).status_code, 200)
        self.assertEqual(self.model.generate.call_count, 3)
        for call in self.model.generate.call_args_list:
            self.assert_settings(call)
        self.assertEqual([c.args[0] for c in self.seed.call_args_list], [123,124,125])

    def test_long_segments_override_stale_master_and_keep_boundaries(self):
        segments = ['Edited bass.', 'Next segment. ' + 'word ' * 150]
        response = self.post('/generate-long', dict(self.data, text='STALE', segments=json.dumps(segments)))
        self.assertEqual(response.status_code, 200, response.text)
        self.assertEqual(response.json()['chunks'], 2)
        self.assertEqual(self.model.generate.call_count, 2)
        self.assert_settings(self.model.generate.call_args_list[0], 'Edited [B EY1 S].')
        self.assert_settings(self.model.generate.call_args_list[1], segments[1])
        self.assertEqual([c.args[0] for c in self.seed.call_args_list], [123,124])

    def test_retry_generates_only_selected_edited_segment(self):
        response = self.post('/generate-long', dict(self.data, segments=json.dumps(['First', 'Edited bass.']), retry_index='1'))
        self.assertEqual(response.status_code, 200, response.text)
        self.model.generate.assert_called_once()
        self.assert_settings(self.model.generate.call_args, 'Edited [B EY1 S].')
        self.seed.assert_called_once_with(124)
        self.assertEqual(response.json()['retry_index'], 1)
        self.assertNotIn('chunks', response.json())

    def test_engine_lab_trained_and_base_share_controls(self):
        trained = Mock()
        trained.create_voice_clone_prompt.return_value = 'trained prompt'
        trained.generate.return_value = [np.zeros(24, dtype=np.float32)]
        with patch.object(backend, '_trained_engine_map', return_value={'My Voice': ROOT.name}), patch.object(backend.OmniVoice, 'from_pretrained', return_value=trained):
            response = self.post('/engine-lab/compare', dict(self.data, engine_a='OmniVoice Zero-Shot', engine_b='My Voice'))
        self.assertEqual(response.status_code, 200, response.text)
        self.assert_settings(self.model.generate.call_args)
        self.assert_settings(trained.generate.call_args)
        self.assertEqual([c.args[0] for c in self.seed.call_args_list], [123,123])

    def test_f5_markup_rejected_before_any_generation(self):
        for text in ['[laughter]', '[sigh]', '[question-oh]', '[B EY1 S]', 'ZHE2', '打ZHE2出售', '<|text_start|>', '[sniff]']:
            with self.subTest(text=text), patch.object(backend, 'run_f5') as f5:
                response = self.post('/engine-lab/compare', dict(self.data, text=text, engine_a='OmniVoice Zero-Shot', engine_b='F5-TTS'))
                self.assertEqual(response.status_code, 422, response.text)
                f5.assert_not_called()
                self.model.generate.assert_not_called()

    def test_f5_pronunciation_and_language_rejected(self):
        for extra in [dict(pronunciations='bass=[B EY1 S]'), dict(language='English'), dict(instruct='whisper')]:
            with self.subTest(extra=extra):
                request = GenerationRequest(text='Plain text', **extra)
                with self.assertRaises(ValueError):
                    request.f5_arguments('ref', 'out')

    def test_f5_adapter_forwards_only_speed_and_plain_reference(self):
        data = dict(text='Plain text.', ref_text='Reference.', speed='1.23', steps='43', guidance='3.1',
                    seed='123', denoise='false', engine_a='OmniVoice Zero-Shot', engine_b='F5-TTS')
        with patch.object(backend, 'run_f5') as f5:
            response = self.post('/engine-lab/compare', data)
        self.assertEqual(response.status_code, 200, response.text)
        self.assertEqual(set(f5.call_args.kwargs), {'ref_path','ref_text','text','output_path','speed'})
        self.assertEqual(f5.call_args.kwargs['speed'], 1.23)
        self.assertEqual(F5_CAPABILITIES['controls'], ['speed'])

    def test_invalid_inputs_never_generate(self):
        for values in [dict(speed='nan'), dict(speed='0'), dict(steps='7'), dict(guidance='5'),
                       dict(seed='-1'), dict(denoise='maybe'), dict(language='not-a-language'),
                       dict(segments='['), dict(segments='[]'), dict(segments='[""]'),
                       dict(segments='["one"]',retry_index='2'), dict(count='5')]:
            with self.subTest(values=values):
                response = self.post('/generate-long', dict(self.data, **values))
                self.assertEqual(response.status_code, 422, response.text)
                self.model.generate.assert_not_called()

    def test_denoise_true_and_auto_language(self):
        self.assertEqual(self.post('/generate-clone', dict(self.data, denoise='true', language='Auto detect')).status_code,200)
        self.assertIsNone(self.model.generate.call_args.kwargs['language'])
        self.assertIs(self.model.generate.call_args.kwargs['generation_config'].denoise,True)

    def test_seed_zero_never_becomes_sequential(self):
        self.assertEqual(self.post('/generate-variants', dict(self.data, seed='0')).status_code,200)
        self.assertEqual([c.args[0] for c in self.seed.call_args_list], [0,0])

    def test_seed_implementation(self):
        self.seed_patch.stop()
        with patch('random.seed') as rand, patch('numpy.random.seed') as numpy_seed, patch.object(backend.torch,'manual_seed') as torch_seed, patch.object(backend.torch.backends.mps,'is_available',return_value=True), patch.object(backend.torch.mps,'manual_seed') as mps:
            backend.apply_seed(0)
            rand.assert_not_called()
            torch_seed.assert_not_called()
            backend.apply_seed(123)
            rand.assert_called_once_with(123)
            numpy_seed.assert_called_once_with(123)
            torch_seed.assert_called_once_with(123)
            mps.assert_called_once_with(123)

    def test_native_markup_and_asterisks_preserved_without_rules(self):
        text='[laughter] [B EY1 S] ZHE2 *words* **bold**'
        self.assertEqual(apply_pronunciations(text,''),text)
        self.assertEqual(apply_pronunciations(text,'laughter=ha\nS=ess\nZHE=bad'),text)
        self.assertEqual(apply_pronunciations('bass','bass=[B EY1 S]\nS=ess'),'[B EY1 S]')

    def test_provenance_identifies_existing_artifacts(self):
        provenance = runtime_provenance(resolve_base_model())
        self.assertEqual(provenance['package_commit'],MANIFEST['expected_package_commit'])
        self.assertEqual(provenance['model_revision'],MANIFEST['model_revision'])
        self.assertEqual(provenance['tokenizer_revision'],MANIFEST['model_revision'])
        self.assertEqual(len(provenance['tokenizer_sha256']),64)
        self.assertEqual(provenance['audio_tokenizer_source'], MANIFEST['audio_tokenizer']['repo_id'])
        self.assertEqual(provenance['audio_tokenizer_revision'], MANIFEST['audio_tokenizer']['revision'])
        self.assertEqual(provenance['audio_tokenizer_weights_sha256'], MANIFEST['audio_tokenizer']['sha256']['model.safetensors'])

    def test_startup_loads_only_verified_local_snapshot(self):
        def verify_view(path, **kwargs):
            loaded = Path(path)
            self.assertEqual((loaded / 'config.json').resolve(), (resolve_base_model() / 'config.json').resolve())
            self.assertEqual((loaded / 'audio_tokenizer').resolve().name, MANIFEST['audio_tokenizer']['revision'])
            self.assertTrue(kwargs['local_files_only'])
            return self.model
        with patch.object(backend.OmniVoice, 'from_pretrained', side_effect=verify_view) as load:
            backend.startup()
        self.assertFalse(Path(load.call_args.args[0]).exists())
        response = self.client.get('/health').json()
        self.assertEqual(response['generation_contract'], 3)
        self.assertEqual(response['provenance']['package_version'], '0.2.1')
        self.assertEqual(response['provenance']['native_app_version'], MANIFEST['native_app_version'])

    def test_unverified_runtime_fails_before_loading(self):
        with patch.object(backend, 'runtime_provenance', return_value={'package_version':'old','package_commit':'unknown'}), patch.object(backend.OmniVoice,'from_pretrained') as load:
            with self.assertRaises(RuntimeError):
                backend.startup()
            load.assert_not_called()

    def test_invalid_design_instruction_rejected(self):
        response = self.post('/generate-design', dict(self.data, instruct='sarcastic'))
        self.assertEqual(response.status_code,422)
        self.model.generate.assert_not_called()

    def test_capabilities_exposed(self):
        response=self.client.get('/engine-lab/status')
        self.assertTrue(response.json()['capabilities']['OmniVoice Zero-Shot']['native_markup'])
        self.assertFalse(response.json()['capabilities']['F5-TTS']['native_markup'])

if __name__ == '__main__':
    unittest.main()
