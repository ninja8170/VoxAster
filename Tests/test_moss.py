import io
import json
import os
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path
from unittest.mock import patch

import numpy as np
import soundfile as sf

ROOT = tempfile.TemporaryDirectory(prefix='voxaster-moss-')
os.environ.setdefault('OMNIVOICE_DATA_ROOT', ROOT.name)
from fastapi.testclient import TestClient
import backend
from moss_engine import MossEngine, MossUnavailable
from studio_tools import moss_script, moss_token_budget

FAKE_WORKER = textwrap.dedent('''
    import json, sys, wave
    print(json.dumps({"ready": True}), flush=True)
    for raw in sys.stdin:
        r = json.loads(raw)
        if "crash" in r["text"]:
            sys.exit(3)
        if "fail" in r["text"]:
            print(json.dumps({"id": r["id"], "ok": False, "error": "ValueError: bad passage"}), flush=True)
            continue
        with wave.open(r["output"], "wb") as w:
            w.setnchannels(1); w.setsampwidth(2); w.setframerate(24000); w.writeframes(bytes([0, 16]) * 24000)
        print(json.dumps({"id": r["id"], "ok": True, "duration": 1.0, "stop_reached": True,
                          "prompts": sorted(r["prompts"])}), flush=True)
''')


def wav_bytes(seconds=12.0, sr=44100):
    t = np.arange(int(seconds * sr)) / sr
    audio = (0.2 * np.sin(2 * np.pi * 180 * t) * (np.sin(2 * np.pi * 1.5 * t) > -0.3)).astype(np.float32)
    buffer = io.BytesIO(); sf.write(buffer, audio, sr, format='WAV'); return buffer.getvalue()


def fake_install(home):
    (home / 'venv/bin').mkdir(parents=True)
    os.symlink(sys.executable, home / 'venv/bin/python')
    (home / 'models/ttsd/mlx-int8').mkdir(parents=True)
    (home / 'models/ttsd/mlx-int8/model.safetensors').write_bytes(b'x')
    (home / 'models/codec/mlx-int8').mkdir(parents=True)
    worker = home / 'fake_worker.py'
    worker.write_text(FAKE_WORKER)
    return worker


class MossScriptTests(unittest.TestCase):
    def test_speakers_numbered_by_first_appearance(self):
        text, order = moss_script([dict(speaker='BEN', text='Hi.'), dict(speaker='ANNA', text=' Oh,\n hello. '),
                                   dict(speaker='BEN', text='Right.')])
        self.assertEqual(text, '[S1] Hi. [S2] Oh, hello. [S1] Right.')
        self.assertEqual(order, ['BEN', 'ANNA'])

    def test_limits(self):
        with self.assertRaises(ValueError):
            moss_script([dict(speaker=f'P{i}', text='Hi.') for i in range(6)])
        with self.assertRaises(ValueError):
            moss_script([dict(speaker='A', text='  ')])
        self.assertEqual(moss_token_budget('x'), 320)
        self.assertEqual(moss_token_budget('x' * 5000), 2400)


class MossEngineTests(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.home = Path(self.dir.name) / 'moss'

    def tearDown(self):
        self.dir.cleanup()

    def engine(self):
        with patch.dict(os.environ, OMNIVOICE_MOSS_HOME=str(self.home)):
            return MossEngine(self.dir.name)

    def test_not_installed_explains_setup(self):
        engine = self.engine()
        status = engine.status()
        self.assertFalse(status['available'])
        self.assertIn('setup-moss.command', status['reason'])
        with self.assertRaises(MossUnavailable):
            engine.render('[S1] Hi.', {1: 'a.wav'}, Path(self.dir.name) / 'o.wav')

    def test_worker_protocol_errors_and_restart(self):
        worker = fake_install(self.home)
        engine = self.engine()
        engine.worker = worker
        self.assertTrue(engine.status()['available'])
        out = Path(self.dir.name) / 'one.wav'
        reply = engine.render('[S1] Hi. [S2] Yo.', {1: 'a.wav', 2: 'b.wav'}, out, seed=4)
        self.assertTrue(out.exists() and reply['ok'] and reply['prompts'] == ['1', '2'])
        first = engine.process.pid
        with self.assertRaisesRegex(RuntimeError, 'bad passage'):
            engine.render('[S1] fail', {1: 'a.wav'}, out)
        self.assertEqual(engine.process.pid, first)  # a failed passage keeps the model loaded
        with self.assertRaisesRegex(RuntimeError, 'exited'):
            engine.render('[S1] crash', {1: 'a.wav'}, out)
        self.assertFalse(engine.running())
        engine.render('[S1] Again.', {1: 'a.wav'}, out)  # restarts on demand
        self.assertNotEqual(engine.process.pid, first)
        engine.stop()
        self.assertFalse(engine.running())


class MossRouteTests(unittest.TestCase):
    def setUp(self):
        self.client = TestClient(backend.app, base_url="http://127.0.0.1:8011")
        self.renders = []

        def render(text, prompts, output, seed=0, max_new_tokens=0):
            self.renders.append(dict(text=text, prompts=dict(prompts), seed=seed))
            for path in prompts.values():
                audio, sr = sf.read(path)
                assert sr == 24000 and len(audio) <= 12.5 * sr, 'references are trimmed to ~10 s at 24 kHz'
            sf.write(str(output), np.full(24000, 0.1, dtype=np.float32), 24000)
            return dict(ok=True, duration=1.0, stop_reached=True)

        self.patches = [patch.object(backend.MOSS, 'status', return_value=dict(available=True, reason='')),
                        patch.object(backend.MOSS, 'render', side_effect=render),
                        patch.object(backend, 'asr_words', return_value=('heard', [], np.zeros(16000, dtype=np.float32)))]
        for p in self.patches:
            p.start()

    def tearDown(self):
        for p in self.patches:
            p.stop()

    def post(self, lines, refs=2, **fields):
        files = {f'ref_{i}': (f'v{i}.wav', wav_bytes(), 'audio/wav') for i in range(1, refs + 1)}
        return self.client.post('/cast/moss', data=dict(lines=json.dumps(lines), **fields), files=files)

    LINES = [dict(speaker='ANNA', text='Hello there.'), dict(speaker='BEN', text='Oh, hi!')]

    def test_renders_passage_and_keeps_a_good_take(self):
        word = dict(text='Hello', status='wrong', heard='Yellow', t0=0.1, t1=0.4, location=0, length=5, sentence=0)
        with patch.object(backend, 'take_report', return_value=dict(score=96, words=[word])):
            r = self.post(self.LINES, seed=5)
        self.assertEqual(r.status_code, 200, r.text)
        body = r.json()
        self.assertEqual((body['score'], body['attempts'], body['speakers']), (96, 1, ['ANNA', 'BEN']))
        self.assertEqual(body['words'], [dict(text='Hello', status='wrong', heard='Yellow', t0=0.1, t1=0.4)])
        self.assertTrue(Path(body['output']).exists())
        self.assertEqual(self.renders[0]['text'], '[S1] Hello there. [S2] Oh, hi!')
        self.assertEqual(self.renders[0]['seed'], 5)

    def test_misheard_take_is_rendered_again_and_best_kept(self):
        with patch.object(backend, 'take_report', side_effect=[dict(score=70, words=[]), dict(score=85, words=[])]):
            body = self.post(self.LINES).json()
        self.assertEqual((body['score'], body['attempts'], len(self.renders)), (85, 2, 2))
        self.assertNotEqual(self.renders[0]['seed'], self.renders[1]['seed'])
        kept = [p for p in backend.OUTPUT_DIR.iterdir() if p.name == Path(body['output']).name]
        self.assertEqual(len(kept), 1)

    def test_refusals(self):
        self.assertEqual(self.post(self.LINES, refs=1).status_code, 422)  # BEN has no voice
        self.assertEqual(self.post([dict(speaker=f'P{i}', text='Hi.') for i in range(6)], refs=5).status_code, 422)
        self.assertEqual(self.client.post('/cast/moss', data=dict(lines='nope')).status_code, 422)
        with patch.object(backend.MOSS, 'status', return_value=dict(available=False, reason='Run setup-moss.command')):
            r = self.post(self.LINES)
        self.assertEqual(r.status_code, 422)
        self.assertIn('setup-moss', r.text)
        self.assertEqual(self.renders, [])


if __name__ == '__main__':
    unittest.main()
