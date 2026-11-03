import unittest

import numpy as np

from studio_tools import best_reference_window, align, take_report, splice, parse_cast, sentence_times, utf16_offset

SR = 16000


def speechy(seconds, seed=0, level=0.2):
    """Bursts of tone with short pauses: a stand-in for speech."""
    rng = np.random.default_rng(seed)
    out = []
    while sum(len(x) for x in out) < seconds * SR:
        burst = int(rng.uniform(0.25, 0.6) * SR)
        t = np.arange(burst) / SR
        out.append((level * np.sin(2 * np.pi * rng.uniform(120, 220) * t)).astype(np.float32))
        out.append(np.zeros(int(rng.uniform(0.08, 0.25) * SR), dtype=np.float32))
    return np.concatenate(out)[: int(seconds * SR)]


class CleanerTests(unittest.TestCase):
    def test_prefers_speech_over_music_and_silence(self):
        silence = np.zeros(20 * SR, dtype=np.float32)
        t = np.arange(20 * SR) / SR
        music = (0.3 * np.sin(2 * np.pi * 440 * t)).astype(np.float32)  # continuous: no pauses
        speech = speechy(14, seed=1)
        audio = np.concatenate([silence, music, speech, silence])
        result = best_reference_window(audio, SR, target=12)
        self.assertTrue(result["trimmed"])
        self.assertGreaterEqual(result["start"], 39.0)
        self.assertLessEqual(result["end"], 55.0)
        self.assertGreater(result["end"] - result["start"], 6)

    def test_avoids_clipped_stretch(self):
        clean = speechy(14, seed=2)
        clipped = np.clip(speechy(14, seed=3, level=2.0), -1, 1)
        audio = np.concatenate([clipped, clean])
        result = best_reference_window(audio, SR, target=12)
        self.assertGreaterEqual(result["start"], 12.0)

    def test_short_clip_is_kept_whole(self):
        result = best_reference_window(speechy(9), SR)
        self.assertFalse(result["trimmed"])
        self.assertEqual(result["start"], 0.0)


class DoctorTests(unittest.TestCase):
    def heard(self, words):
        return [(" " + w, i * 0.4, i * 0.4 + 0.35) for i, w in enumerate(words)]

    def test_perfect_take_scores_full(self):
        script = "Welcome back. [laughter] Today we walk."
        report = take_report(script, self.heard(["Welcome", "back.", "Today", "we", "walk."]), speechy(3), SR)
        self.assertEqual(report["score"], 100)
        self.assertTrue(all(w["status"] == "ok" for w in report["words"]))
        self.assertEqual([w["text"] for w in report["words"]], ["Welcome", "back", "Today", "we", "walk"])  # tag skipped

    def test_wrong_and_missing_words_are_flagged_with_utf16_offsets(self):
        script = "Siobhan 😀 walked to the harbour."
        _, result, _ = align(script, self.heard(["Shivon", "walked", "the", "harbor"]))
        statuses = {r["word"]: r["status"] for r in result}
        self.assertEqual(statuses["Siobhan"], "wrong")
        self.assertEqual(statuses["to"], "missing")
        self.assertEqual(statuses["harbour"], "ok")  # spelling variant accepted
        report = take_report(script, self.heard(["Shivon", "walked", "the", "harbor"]), speechy(2), SR)
        walked = next(w for w in report["words"] if w["text"] == "walked")
        self.assertEqual(walked["location"], utf16_offset(script, script.index("walked")))
        self.assertEqual(walked["location"], 11)  # emoji is two UTF-16 units
        self.assertLess(report["score"], 100)

    def test_numbers_are_not_flagged(self):
        _, result, _ = align("Dark for 11 years.", self.heard(["Dark", "for", "eleven", "years"]))
        self.assertTrue(all(r["status"] == "ok" for r in result))

    def test_sentence_times(self):
        script = "One two. Three four."
        report = take_report(script, self.heard(["One", "two.", "Three", "four."]), speechy(2), SR)
        start, end = sentence_times(report, 1, 2.0)
        self.assertAlmostEqual(start, 0.74, places=2)
        self.assertAlmostEqual(end, 1.65, places=2)
        self.assertEqual([s["text"] for s in report["sentences"]], ["One two.", "Three four."])

    def test_splice_replaces_range_and_keeps_level(self):
        take = np.full(3 * SR, 0.1, dtype=np.float32)
        insert = np.concatenate([np.zeros(SR // 4), np.full(SR // 2, 0.4), np.zeros(SR // 4)]).astype(np.float32)
        out = splice(take, insert, SR, 1.0, 2.0)
        self.assertLess(abs(len(out) - (2 * SR + SR // 2)), SR // 5)  # silence trimmed from the insert
        middle = out[int(1.2 * SR):int(1.4 * SR)]
        self.assertAlmostEqual(float(np.sqrt(np.mean(middle ** 2))), 0.1, delta=0.03)


class CastTests(unittest.TestCase):
    def test_parse_speakers_continuations_and_default(self):
        script = "Opening line without a name.\nALICE: Hello there.\nBob: Hi!\nIt is late.\nalice:\nWhat now?\n\n"
        lines, speakers = parse_cast(script)
        self.assertEqual(speakers, ["NARRATOR", "ALICE", "BOB"])
        self.assertEqual(lines[2], dict(speaker="BOB", text="Hi! It is late."))
        self.assertEqual(lines[3], dict(speaker="ALICE", text="What now?"))
        self.assertEqual(len(lines), 4)


if __name__ == "__main__":
    unittest.main()


class WhisperMergeTests(unittest.TestCase):
    def test_words_only_in_plain_transcript_are_kept_untimed(self):
        from studio_tools import merge_untimed, align
        timed = [(" She", 0.0, 0.3), (" walked", 0.3, 0.6), (" home.", 0.6, 1.0)]
        merged = merge_untimed("She walked home. The lights were out.", timed)
        self.assertEqual([m[0].strip() for m in merged], ["She", "walked", "home.", "The", "lights", "were", "out"])
        self.assertEqual(merged[3][1], None)
        _, result, _ = align("She walked home. The lights were out.", merged)
        self.assertTrue(all(r["status"] == "ok" for r in result))

    def test_unheard_sentence_gets_an_insertion_point(self):
        script = "One two. Three four. Five six."
        heard = [(" One", 0.0, 0.3), (" two.", 0.3, 0.6), (" Five", 1.5, 1.8), (" six.", 1.8, 2.1)]
        report = take_report(script, heard, speechy(2.2), SR)
        start, end = sentence_times(report, 1, 2.2)
        self.assertAlmostEqual(start, 0.65, places=2)
        self.assertAlmostEqual(end, 1.45, places=2)
        start, end = sentence_times(take_report("One two. Three four.", heard[:2], speechy(2.2), SR), 1, 2.2)
        self.assertEqual(start, end)  # nothing after it: append at the end of the speech
