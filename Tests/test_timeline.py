import json
import os
import tempfile
import unittest
from pathlib import Path

import numpy as np
import soundfile as sf

ROOT = tempfile.TemporaryDirectory(prefix='voxaster-timeline-')
os.environ.setdefault('OMNIVOICE_DATA_ROOT', ROOT.name)
from fastapi.testclient import TestClient
import backend
from studio_tools import line_slices, shape_clip, mix_timeline, DUCK_DB

SR = 24000


def tone(seconds, level=0.3, f=200):
    t = np.arange(int(seconds * SR)) / SR
    return (level * np.sin(2 * np.pi * f * t)).astype(np.float32)


class LineSliceTests(unittest.TestCase):
    def test_cuts_fall_between_lines(self):
        texts = ['Did you hear that?', 'Hear what?']
        heard = [('Did', 0.2, 0.4), ('you', 0.4, 0.5), ('hear', 0.5, 0.7), ('that?', 0.7, 1.0),
                 ('Hear', 1.6, 1.8), ('what?', 1.8, 2.1)]
        self.assertEqual(line_slices(texts, heard, 2.5), [(0.0, 1.3), (1.3, 2.5)])

    def test_untimed_line_is_spread_between_neighbours(self):
        texts = ['One two.', 'Three four five six.', 'Seven.']
        heard = [('One', 0.0, 0.3), ('two', 0.3, 0.6), ('Seven', 3.0, 3.4)]
        slices = line_slices(texts, heard, 4.0)
        self.assertEqual(len(slices), 3)
        self.assertTrue(0.6 <= slices[1][0] < slices[1][1] <= 3.0)
        self.assertEqual((slices[0][0], slices[-1][1]), (0.0, 4.0))

    def test_overlapping_speech_cuts_at_the_next_line(self):
        heard = [('Wait', 0.0, 0.5), ('no', 0.4, 0.8)]
        self.assertEqual(line_slices(['Wait', 'No'], heard, 1.0), [(0.0, 0.4), (0.4, 1.0)])


class ShapeAndMixTests(unittest.TestCase):
    def test_cut_off_silences_after_cut_and_duck_lowers(self):
        a = shape_clip(tone(2.0), SR, at=1.0, cut_at=2.0)
        self.assertTrue(np.all(a[SR:] == 0))
        self.assertGreater(np.abs(a[int(0.5 * SR):int(0.8 * SR)]).max(), 0.25)
        d = shape_clip(tone(2.0), SR, at=0.0, duck_from=1.0)
        ratio = np.abs(d[int(1.5 * SR):]).max() / np.abs(d[:int(0.9 * SR)]).max()
        self.assertAlmostEqual(20 * np.log10(ratio), DUCK_DB, delta=0.5)

    def test_overlapping_clips_sum_and_stems_line_up(self):
        clips = [dict(audio=tone(1.0, f=200), at=0.0, lane='ANNA'),
                 dict(audio=tone(1.0, f=300), at=0.5, lane='BEN')]
        master, stems = mix_timeline(clips, SR, 'dry', stems=True)
        self.assertEqual(len(master), int(1.5 * SR))
        self.assertEqual(set(stems), {'ANNA', 'BEN'})
        self.assertTrue(all(len(s) == len(master) for s in stems.values()))
        self.assertTrue(np.all(stems['BEN'][:int(0.5 * SR)] == 0))
        self.assertGreater(np.abs(stems['ANNA'][int(0.6 * SR):int(0.9 * SR)]).max(), 0)
        self.assertGreater(np.abs(stems['BEN'][int(0.6 * SR):int(0.9 * SR)]).max(), 0)  # both heard in the overlap

    def test_rejects_bad_input(self):
        bed = [dict(audio=tone(1.0, 0.1), at=0.0, lane='ANNA')]
        with self.assertRaises(ValueError):
            mix_timeline([], SR)
        with self.assertRaises(ValueError):
            mix_timeline(bed, SR, 'cathedral')


class MixRouteTests(unittest.TestCase):
    def setUp(self):
        self.client = TestClient(backend.app, base_url="http://127.0.0.1:8011")
        self.take = backend.OUTPUT_DIR / 'test-take.wav'
        sf.write(str(self.take), np.concatenate([tone(1.0), tone(1.0, f=300)]), SR)

    def test_mix_slices_places_and_writes_stems(self):
        clips = [dict(path=str(self.take), src_in=0.0, src_out=1.0, at=0.0, lane='ANNA', cut_at=0.8),
                 dict(path=str(self.take), src_in=1.0, src_out=2.0, at=0.7, lane='BEN')]
        r = self.client.post('/cast/mix', data=dict(clips=json.dumps(clips), room='dry', stems='true'))
        self.assertEqual(r.status_code, 200, r.text)
        body = r.json()
        master, sr = sf.read(body['output'])
        self.assertAlmostEqual(len(master) / sr, 1.7, places=2)
        self.assertEqual(set(body['stems']), {'ANNA', 'BEN'})
        anna, _ = sf.read(body['stems']['ANNA'])
        self.assertTrue(np.all(anna[int(0.81 * SR):] == 0))  # cut off at 0.8 s
        self.assertTrue(Path(body['stems_folder']).is_dir())

    def test_mix_refusals(self):
        bad = [dict(path=str(self.take), src_in=1.0, src_out=0.5, at=0.0)]
        self.assertEqual(self.client.post('/cast/mix', data=dict(clips=json.dumps(bad))).status_code, 422)
        outside = tempfile.NamedTemporaryFile(suffix='.wav', delete=False).name
        sf.write(outside, tone(0.2), SR)
        clip = [dict(path=outside, src_in=0, src_out=0.1, at=0)]
        self.assertEqual(self.client.post('/cast/mix', data=dict(clips=json.dumps(clip))).status_code, 422)
        self.assertEqual(self.client.post('/cast/mix', data=dict(clips='[]')).status_code, 422)


if __name__ == '__main__':
    unittest.main()
