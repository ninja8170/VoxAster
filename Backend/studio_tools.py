"""Pure helpers for the Reference Cleaner, Take Doctor and Cast features.

Nothing here loads a model; everything is plain numpy/text so it can be unit tested.
Character offsets returned to the app are UTF-16 code units (NSRange in Swift).
"""
import difflib
import re

import numpy as np

HOP_SECONDS = 0.010
FRAME_SECONDS = 0.025


# ---------------------------------------------------------------------------
# Audio basics
# ---------------------------------------------------------------------------

def mono(audio):
    audio = np.asarray(audio, dtype=np.float32)
    if audio.ndim > 1:
        audio = audio.mean(axis=1 if audio.shape[0] > audio.shape[1] else 0)
    return audio


def frame_db(audio, sr):
    """Short-time level in dB (25 ms frames, 10 ms hop) and per-frame clipping flags."""
    frame = max(16, int(sr * FRAME_SECONDS))
    hop = max(8, int(sr * HOP_SECONDS))
    count = max(1, 1 + (len(audio) - frame) // hop) if len(audio) >= frame else 1
    db = np.full(count, -100.0)
    clipped = np.zeros(count, dtype=bool)
    for i in range(count):
        x = audio[i * hop:i * hop + frame]
        if x.size:
            db[i] = 20 * np.log10(np.sqrt(np.mean(x * x)) + 1e-9)
            clipped[i] = np.max(np.abs(x)) >= 0.995
    return db, clipped


def activity(db):
    noise = float(np.percentile(db, 15))
    threshold = max(noise + 12.0, -45.0)
    return db > threshold, threshold


def longest_run(mask):
    best = run = 0
    for value in mask:
        run = run + 1 if value else 0
        best = max(best, run)
    return best


def _window_score(active, db, clipped):
    speech = float(active.mean()) if active.size else 0.0
    longest_gap = longest_run(~active) * HOP_SECONDS
    longest_sound = longest_run(active) * HOP_SECONDS
    voiced = db[active]
    level = float(voiced.mean()) if voiced.size else -80.0
    spread = float(voiced.std()) if voiced.size > 10 else 30.0
    clip = float(clipped.mean()) if clipped.size else 0.0
    score = 100.0
    score -= abs(speech - 0.80) * 80           # natural speech has short pauses
    if speech > 0.97:
        score -= 15                             # wall-to-wall sound: music or noise
    score -= max(0.0, longest_sound - 1.5) * 12  # speech dips between words; music does not
    score -= max(0.0, longest_gap - 0.6) * 25  # long silences waste the prompt
    score -= max(0.0, spread - 7.0) * 2.5      # steady level suggests one speaker
    score -= clip * 2000                       # any clipping is bad
    score -= max(0.0, -32.0 - level) * 1.5     # too quiet
    return max(0.0, min(100.0, score)), speech


def best_reference_window(audio, sr, target=12.0, max_len=15.0, analyze_limit=600.0, candidates=3):
    """Pick the cleanest stretch of single-speaker speech, snapped to pauses."""
    audio = mono(audio)
    audio = audio[:int(sr * analyze_limit)]
    duration = len(audio) / sr if sr else 0.0
    if duration <= 0:
        raise ValueError("The reference audio is empty.")
    db, clipped = frame_db(audio, sr)
    active, _ = activity(db)
    if duration <= max_len:
        score, speech = _window_score(active, db, clipped)
        return dict(start=0.0, end=round(duration, 3), score=round(score), speech_ratio=round(speech, 3),
                    candidates=[dict(start=0.0, end=round(duration, 3), score=round(score))], trimmed=False)

    win = int(target / HOP_SECONDS)
    step = int(0.5 / HOP_SECONDS)
    scored = []
    for start in range(0, max(1, len(db) - win + 1), step):
        s, _ = _window_score(active[start:start + win], db[start:start + win], clipped[start:start + win])
        scored.append((s, start))
    scored.sort(reverse=True)

    chosen = []
    for s, start in scored:
        if all(abs(start - other) >= win for _, other in chosen):
            chosen.append((s, start))
        if len(chosen) == candidates:
            break

    def snap(index, inward):
        # Move an edge onto a pause within 0.6 s so no word is cut, looking
        # inside the window first; with no pause nearby, leave it alone.
        reach = int(0.6 / HOP_SECONDS)
        ranges = [(index, min(len(db) - 1, index + reach)), (max(0, index - reach), index)]
        if inward < 0:
            ranges.reverse()
        for lo, hi in ranges:
            quiet = np.where(~active[lo:hi + 1])[0]
            if quiet.size:
                return lo + int(quiet[np.argmin(np.abs(lo + quiet - index))])
        return index

    best_score, best_start = chosen[0]
    a = snap(best_start, +1)
    b = snap(min(len(db) - 1, best_start + win), -1)
    if b - a < int(4 / HOP_SECONDS):
        a, b = best_start, min(len(db) - 1, best_start + win)
    speech = float(active[a:b].mean()) if b > a else 0.0
    return dict(start=round(a * HOP_SECONDS, 3), end=round(min(duration, b * HOP_SECONDS + FRAME_SECONDS), 3),
                score=round(best_score), speech_ratio=round(speech, 3),
                candidates=[dict(start=round(st * HOP_SECONDS, 3), end=round((st + win) * HOP_SECONDS, 3), score=round(sc))
                            for sc, st in chosen],
                trimmed=True)


# ---------------------------------------------------------------------------
# Script ↔ transcript alignment (Take Doctor)
# ---------------------------------------------------------------------------

TAG = re.compile(r"\[[^\]]*\]")
WORD = re.compile(r"[\w'’]+", re.UNICODE)
SENTENCE_END = re.compile(r"(?<=[.!?…])\s+")


def utf16_offset(text, index):
    return len(text[:index].encode("utf-16-le")) // 2


def normalize(word):
    return re.sub(r"['’]", "", word.lower())


def script_tokens(script):
    """Words a listener should hear, with code-point spans; bracketed markup is skipped."""
    tags = [(m.start(), m.end()) for m in TAG.finditer(script)]
    tokens = []
    for m in WORD.finditer(script):
        if any(a <= m.start() < b for a, b in tags):
            continue
        tokens.append((m.group(), m.start(), m.end()))
    return tokens


def sentences(script):
    spans, start = [], 0
    for m in SENTENCE_END.finditer(script):
        if script[start:m.start()].strip():
            spans.append((start, m.start()))
        start = m.end()
    if script[start:].strip():
        spans.append((start, len(script.rstrip())))
    return spans


def _similar(a, b):
    if a == b:
        return True
    if any(ch.isdigit() for ch in a + b):
        return True  # "11" vs "eleven": the recogniser may write numbers either way
    return difflib.SequenceMatcher(None, a, b).ratio() >= 0.8  # harbour / harbor


def align(script, heard):
    """heard: list of (text, start_s, end_s). Returns per-script-word status."""
    tokens = script_tokens(script)
    want = [normalize(t[0]) for t in tokens]
    got = [normalize(h[0].strip(" ,.!?;:\"")) for h in heard]
    result = [dict(word=t[0], status="ok", heard=None, t0=None, t1=None) for t in tokens]
    extra = 0
    matcher = difflib.SequenceMatcher(None, want, got, autojunk=False)
    for op, a0, a1, b0, b1 in matcher.get_opcodes():
        if op == "equal":
            for k in range(a1 - a0):
                result[a0 + k].update(t0=heard[b0 + k][1], t1=heard[b0 + k][2])
        elif op == "replace":
            for k in range(a1 - a0):
                j = b0 + k
                if j < b1:
                    ok = _similar(want[a0 + k], got[j])
                    result[a0 + k].update(status="ok" if ok else "wrong", heard=None if ok else heard[j][0].strip(),
                                          t0=heard[j][1], t1=heard[j][2])
                else:
                    result[a0 + k].update(status="missing")
            extra += max(0, (b1 - b0) - (a1 - a0))
        elif op == "delete":
            for k in range(a0, a1):
                result[k].update(status="missing")
        elif op == "insert":
            extra += b1 - b0
    return tokens, result, extra


def merge_untimed(plain_text, timed):
    """Whisper's word-timestamp mode can stop after the first sentence while its
    plain transcript is complete. Keep the timed words and splice in any words
    only the plain transcript heard, untimed, so they are never reported missing."""
    plain = [w for w in WORD.findall(plain_text)]
    have = [normalize(t[0].strip(" ,.!?;:\"")) for t in timed]
    want = [normalize(w) for w in plain]
    merged = []
    matcher = difflib.SequenceMatcher(None, have, want, autojunk=False)
    for op, a0, a1, b0, b1 in matcher.get_opcodes():
        if op in ("equal", "replace", "delete"):
            merged.extend(timed[a0:a1])
        if op in ("insert",) or (op == "replace" and b1 - b0 > a1 - a0):
            start = b0 if op == "insert" else b0 + (a1 - a0)
            merged.extend((" " + w, None, None) for w in plain[start:b1])
    return merged


def take_report(script, heard, audio, sr):
    tokens, aligned, extra = align(script, heard)
    errors = sum(1 for r in aligned if r["status"] != "ok")
    wer = (errors + extra) / max(1, len(tokens))
    audio = mono(audio)
    db, clipped = frame_db(audio, sr)
    active, _ = activity(db)
    notes, penalty = [], 0
    if clipped.mean() > 0.001:
        notes.append("clipping"); penalty += 10
    voiced = np.where(active)[0]
    if voiced.size:
        lead = voiced[0] * HOP_SECONDS
        tail = (len(active) - voiced[-1]) * HOP_SECONDS
        if lead > 1.0:
            notes.append(f"{lead:.1f} s of silence at the start"); penalty += 5
        if tail > 1.5:
            notes.append(f"{tail:.1f} s of silence at the end"); penalty += 5
        gap = longest_run(~active[voiced[0]:voiced[-1]]) * HOP_SECONDS
        if gap > 1.3:
            notes.append(f"a {gap:.1f} s gap mid-sentence"); penalty += 8
    else:
        notes.append("no speech detected"); penalty += 100
    score = int(round(max(0.0, min(100.0, 100 * (1 - wer) - penalty))))

    spans = sentences(script)

    def sentence_of(pos):
        for i, (a, b) in enumerate(spans):
            if a <= pos < b + 1:
                return i
        return max(0, len(spans) - 1)

    words = []
    for (text, a, b), r in zip(tokens, aligned):
        words.append(dict(text=text, location=utf16_offset(script, a), length=utf16_offset(script, b) - utf16_offset(script, a),
                          status=r["status"], heard=r["heard"], t0=r["t0"], t1=r["t1"], sentence=sentence_of(a)))
    return dict(score=score, wer=round(wer, 3), transcript=" ".join(h[0].strip() for h in heard),
                notes=notes, words=words,
                sentences=[dict(text=script[a:b].strip(), location=utf16_offset(script, a),
                                length=utf16_offset(script, b) - utf16_offset(script, a)) for a, b in spans],
                duration=round(len(audio) / sr, 3) if sr else 0)


def sentence_times(report, index, duration):
    """Time range of a sentence in the take, padded, from aligned word timings."""
    times = [(w["t0"], w["t1"]) for w in report["words"] if w["sentence"] == index and w["t0"] is not None]
    if times:
        return max(0.0, min(t[0] for t in times) - 0.06), min(duration, max(t[1] for t in times) + 0.10)
    # Nothing of this sentence was heard: insert it between its neighbours.
    before = [w["t1"] for w in report["words"] if w["sentence"] < index and w["t1"] is not None]
    after = [w["t0"] for w in report["words"] if w["sentence"] > index and w["t0"] is not None]
    start = min(duration, max(before) + 0.05) if before else 0.0
    end = max(start, min(after) - 0.05) if after else (duration if not before else start)
    return start, end


def trim_silence(audio, sr):
    db, _ = frame_db(audio, sr)
    active, _ = activity(db)
    voiced = np.where(active)[0]
    if not voiced.size:
        return audio
    a = max(0, int((voiced[0] * HOP_SECONDS - 0.03) * sr))
    b = min(len(audio), int(((voiced[-1] + 1) * HOP_SECONDS + FRAME_SECONDS + 0.05) * sr))
    return audio[a:b]


def splice(take, insert, sr, start, end, fade=0.015):
    """Replace take[start:end] (seconds) with insert, level-matched with short crossfades."""
    take, insert = mono(take), trim_silence(mono(insert), sr)
    a, b = int(start * sr), int(end * sr)
    removed = take[a:b]
    ref = removed if removed.size and np.sqrt(np.mean(removed ** 2)) > 1e-4 else take
    gain = (np.sqrt(np.mean(ref ** 2)) + 1e-9) / (np.sqrt(np.mean(insert ** 2)) + 1e-9)
    insert = insert * float(np.clip(gain, 0.2, 5.0))
    n = max(1, int(fade * sr))
    head, tail = take[:a].copy(), take[b:].copy()
    if head.size >= n and insert.size >= n:
        head[-n:] *= np.linspace(1, 0, n)
        insert[:n] *= np.linspace(0, 1, n)
    if tail.size >= n and insert.size >= n:
        insert[-n:] *= np.linspace(1, 0, n)
        tail[:n] *= np.linspace(0, 1, n)
    return np.concatenate([head, insert, tail]).astype(np.float32)


# ---------------------------------------------------------------------------
# Cast scripts
# ---------------------------------------------------------------------------

SPEAKER_LINE = re.compile(r"^\s*([A-Za-z][A-Za-z0-9 .'’-]{0,30}?)\s*:\s*(.*)$")


def parse_cast(script, default="NARRATOR"):
    """`NAME: line` blocks; unlabelled lines continue the previous speaker."""
    lines, speakers = [], []
    for raw in script.splitlines():
        if not raw.strip():
            continue
        m = SPEAKER_LINE.match(raw)
        if m:
            name = " ".join(m.group(1).split()).upper()
            lines.append(dict(speaker=name, text=m.group(2).strip()))
        elif lines:
            lines[-1]["text"] = (lines[-1]["text"] + " " + raw.strip()).strip()
        else:
            lines.append(dict(speaker=default, text=raw.strip()))
    lines = [line for line in lines if line["text"]]
    for line in lines:
        if line["speaker"] not in speakers:
            speakers.append(line["speaker"])
    return lines, speakers


# ---------------------------------------------------------------------------
# Cast scene assembly: one level, one room
# ---------------------------------------------------------------------------

# Every line is rendered on its own, so each arrives dry, at its own level and
# with digital silence around it. A shared room puts all the voices in the same
# space: matched speech level, one reverb and a quiet room tone under the gaps.
# Room tone stays at -70 dBFS or below: louder tone under a reverb tail made
# Whisper (Take Doctor) hear phantom words in the gaps.
ROOMS = {
    "dry": None,
    "booth": dict(rt60=0.18, wet=0.10, predelay=0.004, damping=0.55, tone_db=-72.0),
    "room": dict(rt60=0.42, wet=0.16, predelay=0.010, damping=0.45, tone_db=-70.0),
    "large": dict(rt60=0.95, wet=0.21, predelay=0.022, damping=0.35, tone_db=-72.0),
}
SCENE_SPEECH_DB = -22.0
SCENE_CEILING = 10 ** (-1 / 20)


def speech_level_db(audio, sr):
    """RMS of the active (speaking) frames only, so pauses don't drag the level down."""
    db, _ = frame_db(audio, sr)
    if not db.size:
        return None
    active = db[db > max(float(db.max()) - 30.0, -60.0)]
    if not active.size:
        return None
    return float(10 * np.log10(np.mean(10 ** (active / 10)) + 1e-12))


def match_level(audio, sr, target_db=SCENE_SPEECH_DB, max_change_db=9.0):
    """Bring a line toward the scene's speech level; only gross differences are corrected."""
    audio = np.asarray(audio, dtype=np.float32)
    level = speech_level_db(audio, sr)
    if level is None:
        return audio
    change = float(np.clip(target_db - level, -max_change_db, max_change_db))
    return (audio * 10 ** (change / 20)).astype(np.float32)


def _one_pole(x, coeff):
    """Simple low-pass: y[n] = (1-c)·x[n] + c·y[n-1]."""
    try:
        from scipy.signal import lfilter
        return lfilter([1 - coeff], [1, -coeff], x).astype(np.float32)
    except ImportError:  # pragma: no cover - scipy ships with the runtime
        y = np.empty_like(x)
        acc = 0.0
        for i, v in enumerate(x):
            acc = (1 - coeff) * v + coeff * acc
            y[i] = acc
        return y


def room_impulse(sr, rt60, predelay, damping, seed=11):
    """Deterministic synthetic room: decaying, darkened noise after a short pre-delay."""
    rng = np.random.default_rng(seed)
    n = int(sr * rt60 * 1.3)
    t = np.arange(n) / sr
    tail = rng.standard_normal(n).astype(np.float32) * np.exp(-6.91 * t / rt60).astype(np.float32)
    tail = _one_pole(tail, damping)
    tail /= np.sqrt(np.sum(tail * tail)) + 1e-9
    return np.concatenate([np.zeros(int(sr * predelay), dtype=np.float32), tail])


def _convolve(a, b):
    try:
        from scipy.signal import oaconvolve
        return oaconvolve(a, b).astype(np.float32)
    except ImportError:  # pragma: no cover
        size = len(a) + len(b) - 1
        n = 1 << (size - 1).bit_length()
        return np.fft.irfft(np.fft.rfft(a, n) * np.fft.rfft(b, n), n)[:size].astype(np.float32)


def apply_room(audio, sr, room):
    audio = np.asarray(audio, dtype=np.float32)
    spec = ROOMS.get(room)
    if spec is None:
        return audio
    ir = room_impulse(sr, spec["rt60"], spec["predelay"], spec["damping"])
    wet = _convolve(audio, ir)
    out = np.concatenate([audio, np.zeros(len(wet) - len(audio), dtype=np.float32)])
    out += spec["wet"] * wet
    # Room tone: soft, darkened noise under the whole scene, so gaps aren't digital silence.
    tone = _one_pole(np.random.default_rng(23).standard_normal(len(out)).astype(np.float32), 0.92)
    tone *= 10 ** (spec["tone_db"] / 20) / (np.sqrt(np.mean(tone * tone)) + 1e-9)
    fade = min(len(tone) // 2, int(0.05 * sr))
    if fade:
        tone[:fade] *= np.linspace(0, 1, fade, dtype=np.float32)
        tone[-fade:] *= np.linspace(1, 0, fade, dtype=np.float32)
    out += tone
    peak = float(np.max(np.abs(out))) if out.size else 0.0
    if peak > SCENE_CEILING:
        out *= SCENE_CEILING / peak
    return out.astype(np.float32)


def assemble_scene(lines, sr, gap_ms, room="dry"):
    """Join rendered lines with a gap. Any room other than dry also matches levels."""
    if room not in ROOMS:
        raise ValueError(f"Unknown room {room!r}.")
    gap = np.zeros(int(sr * gap_ms / 1000), dtype=np.float32)
    joined = []
    for index, audio in enumerate(lines):
        audio = mono(audio)
        if ROOMS[room] is not None:
            audio = match_level(audio, sr)
        if index:
            joined.append(gap)
        joined.append(audio)
    return apply_room(np.concatenate(joined), sr, room)


# ---------------------------------------------------------------------------
# Cast "Together" engine (MOSS-TTSD): one passage of dialogue in one render
# ---------------------------------------------------------------------------

MOSS_MAX_SPEAKERS = 5


def moss_script(lines):
    """[{speaker, text}] → ("[S1] … [S2] …", [speaker names in S-number order])."""
    order, parts = [], []
    for line in lines:
        speaker, text = str(line.get("speaker", "")).strip(), " ".join(str(line.get("text", "")).split())
        if not speaker or not text:
            raise ValueError("Every line needs a speaker and text.")
        if speaker not in order:
            order.append(speaker)
        if len(order) > MOSS_MAX_SPEAKERS:
            raise ValueError(f"MOSS-TTSD takes at most {MOSS_MAX_SPEAKERS} speakers in one passage.")
        parts.append(f"[S{order.index(speaker) + 1}] {text}")
    if not parts:
        raise ValueError("The passage is empty.")
    return " ".join(parts), order


def moss_token_budget(text):
    """Generation rows to allow: MOSS emits ~12.5 rows per second of speech, speech runs ~15 chars/s."""
    return int(min(2400, max(320, len(text) * 2)))
