"""24 kHz deterministic assembly. No TTS or silence trimming after assembly."""
import numpy as np

SAMPLE_RATE = 24000
EDGE_THRESHOLD = 1e-4  # -80 dBFS, deterministic sample-level padding removal
FADE_SAMPLES = 120    # 5 ms
MASTER_HEADROOM = 10 ** (-4 / 20)  # fixed headroom, preserves ±3 dB contrast
PEAK_CEILING = 10 ** (-1 / 20)


def prepare_audio(audio, gain_db=0):
    if gain_db not in (-3, 0, 3):
        raise ValueError('Only -3, 0 and +3 dB segment gain is supported.')
    data = np.asarray(audio, dtype=np.float64)
    if data.ndim != 1 or not len(data) or not np.isfinite(data).all():
        raise ValueError('Expected finite, nonempty mono audio at 24 kHz.')
    active = np.flatnonzero(np.abs(data) > EDGE_THRESHOLD)
    if not len(active):
        raise ValueError('Speech output is silent; retry this segment instead of adding unmeasured silence.')
    start, end = int(active[0]), int(active[-1]) + 1
    data = data[start:end].copy()
    if len(data) < 2 * FADE_SAMPLES:
        raise ValueError('Rendered speech is shorter than 10 ms after padding removal; retry this segment.')
    # Never amplify a loud render during input normalization. Common headroom
    # across segments means quieter actually remains quieter.
    input_scale = min(1.0, 1.0 / float(np.max(np.abs(data))))
    data *= input_scale * MASTER_HEADROOM * 10 ** (gain_db / 20)
    n = min(FADE_SAMPLES, len(data) // 2)
    if n:
        # Nonzero endpoints avoid adding exact-zero padding outside pause nodes.
        ramp = np.arange(1, n + 1, dtype=np.float64) / (n + 1)
        data[:n] *= ramp
        data[-n:] *= ramp[::-1]
    return data.astype(np.float32), dict(trimmed_start=start, trimmed_end=len(audio)-end,
        input_scale=input_scale, gain_db=gain_db, headroom_db=-4, fade_samples=n, samples=len(data))


def assemble(segments, load_speech):
    blocks, timeline = [], []
    length = 0
    for segment in segments:
        if segment['kind'] == 'pause':
            count = segment['milliseconds'] * 24
            if not 24 <= count <= 240000:
                raise ValueError('Invalid explicit pause duration.')
            audio = np.zeros(count, dtype=np.float32)
        else:
            audio = np.asarray(load_speech(segment), dtype=np.float32)
            if audio.ndim != 1 or not len(audio) or not np.isfinite(audio).all():
                raise ValueError('Invalid retained segment audio.')
            if np.max(np.abs(audio)) > PEAK_CEILING + 1e-6:
                raise ValueError('Retained audio exceeds the assembly headroom ceiling.')
        # Deliberately concatenate faded segments, not overlapping crossfades:
        # fixed sample positions and deliberate pauses must remain exact.
        timeline.append(dict(id=segment['id'], kind=segment['kind'], start=length, end=length+len(audio)))
        length += len(audio)
        blocks.append(audio)
    if not blocks:
        raise ValueError('No production segments.')
    return np.concatenate(blocks), timeline
