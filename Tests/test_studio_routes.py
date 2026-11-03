import io
import json
import os
import tempfile
import unittest
from unittest.mock import Mock, patch

import numpy as np
import soundfile as sf

ROOT = tempfile.TemporaryDirectory(prefix='voxaster-studio-routes-')
os.environ.setdefault('OMNIVOICE_DATA_ROOT', ROOT.name)
from fastapi.testclient import TestClient
import backend


def wav_bytes(seconds, sr=24000, level=0.2):
    t = np.arange(int(seconds * sr)) / sr
    audio = (level * np.sin(2 * np.pi * 180 * t) * (np.sin(2 * np.pi * 1.5 * t) > -0.3)).astype(np.float32)
    buffer = io.BytesIO(); sf.write(buffer, audio, sr, format='WAV'); return buffer.getvalue()


def output(seconds, value=0.1):
    path = backend.OUTPUT_DIR / f"test-{os.urandom(3).hex()}.wav"
    sf.write(str(path), np.full(int(seconds * 24000), value, dtype=np.float32), 24000)
    return str(path)


class StudioRouteTests(unittest.TestCase):
    def setUp(self):
        backend.MODEL = Mock()
        backend.MODEL.generate.return_value = [np.full(12000, 0.3, dtype=np.float32)]
        self.client = TestClient(backend.app, base_url="http://127.0.0.1:8011")

    def test_cast_assemble_joins_lines_with_gaps(self):
        a, b = output(1.0), output(0.5)
        r = self.client.post('/cast/assemble', data=dict(paths=json.dumps([a, b]), gap_ms='500'))
        self.assertEqual(r.status_code, 200, r.text)
        audio, sr = sf.read(r.json()['output'])
        self.assertAlmostEqual(len(audio) / sr, 2.0, places=2)

    def test_routes_refuse_files_outside_outputs(self):
        outside = tempfile.NamedTemporaryFile(suffix='.wav', delete=False).name
        sf.write(outside, np.zeros(2400, dtype=np.float32), 24000)
        self.assertEqual(self.client.post('/cast/assemble', data=dict(paths=json.dumps([outside]))).status_code, 422)
        self.assertEqual(self.client.post('/takes/check', data=dict(script='Hi.', paths=json.dumps([outside]))).status_code, 422)
        self.assertEqual(self.client.post('/takes/check', data=dict(script='Hi.', paths='not json')).status_code, 422)

    def test_take_check_reports_wrong_words(self):
        take = output(1.0)
        heard = [(' Hello', 0.0, 0.4), (' word', 0.4, 0.8)]
        with patch.object(backend, 'asr_words', return_value=('Hello word', heard, np.full(16000, 0.1, np.float32))):
            r = self.client.post('/takes/check', data=dict(script='Hello world, friend.', paths=json.dumps([take])))
        self.assertEqual(r.status_code, 200, r.text)
        report = r.json()['reports'][take]
        statuses = {w['text']: w['status'] for w in report['words']}
        self.assertEqual(statuses['Hello'], 'ok')
        self.assertEqual(statuses['friend'], 'missing')
        self.assertLess(report['score'], 100)

    def test_reference_clean_trims_and_transcribes(self):
        with patch.object(backend, 'asr_words', return_value=('the cleaned words', [], np.zeros(10, np.float32))):
            r = self.client.post('/reference/clean', data=dict(target='12'),
                                 files={'ref_audio': ('Long Voice.wav', wav_bytes(40), 'audio/wav')})
        self.assertEqual(r.status_code, 200, r.text)
        body = r.json()
        self.assertTrue(body['trimmed'])
        self.assertEqual(body['transcript'], 'the cleaned words')
        self.assertTrue(os.path.basename(body['output']).startswith('Long Voice clean'))
        audio, sr = sf.read(body['output'])
        self.assertLessEqual(len(audio) / sr, 15.5)
        self.assertEqual(self.client.post('/reference/clean', data=dict(target='40'),
                         files={'ref_audio': ('x.wav', wav_bytes(2), 'audio/wav')}).status_code, 422)

    def test_repair_splices_new_sentence_into_take(self):
        take = output(3.0, value=0.1)
        r = self.client.post('/takes/repair', data=dict(text='Fixed sentence.', take_path=take, start='1.0', end='2.0'))
        self.assertEqual(r.status_code, 200, r.text)
        audio, sr = sf.read(r.json()['output'])
        self.assertAlmostEqual(len(audio) / sr, 2.5, delta=0.1)
        self.assertEqual(self.client.post('/takes/repair', data=dict(text='x', take_path=take, start='2', end='1')).status_code, 422)


if __name__ == '__main__':
    unittest.main()
