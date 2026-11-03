import os
import re
import json
import hashlib
import tempfile
from collections import OrderedDict
import uuid
import threading
import traceback
from pathlib import Path

from typing import Optional
from fastapi import FastAPI, UploadFile, File, Form, Depends, HTTPException
from fastapi.responses import JSONResponse, FileResponse
from fastapi.exceptions import RequestValidationError
from starlette.concurrency import run_in_threadpool
import uvicorn
import torch
import soundfile as sf

from omnivoice import OmniVoice, OmniVoiceGenerationConfig

from generation import inspect_speech, GenerationRequest, generation_form, apply_pronunciations, clone_reference_text, OMNI_CAPABILITIES, F5_CAPABILITIES
from provenance import MANIFEST, resolve_base_model, runtime_provenance, load_inference_model

app = FastAPI(docs_url=None, redoc_url=None)

@app.middleware("http")
async def local_native_requests(request, call_next):
    # CORS alone does not stop cross-origin HTML form posts. This is a native
    # loopback API, so reject browser origins/fetch contexts before any work.
    if request.headers.get("host", "").split(":")[0] not in {"127.0.0.1", "localhost"}:
        return JSONResponse(status_code=400, content={"error": "Invalid local API host."})
    if "origin" in request.headers or request.headers.get("sec-fetch-site", "none") != "none":
        return JSONResponse(status_code=403, content={"error": "This API accepts local native clients, not browser pages."})
    return await call_next(request)

@app.exception_handler(RequestValidationError)
async def invalid_request(_request, exc):
    return JSONResponse(status_code=422, content={"error": str(exc)})

@app.exception_handler(Exception)
async def inference_error(_request, exc):
    traceback.print_exception(exc)
    return JSONResponse(status_code=500, content={"error": f"{type(exc).__name__}: {exc}"})

PROVENANCE = {}
DATA_ROOT = Path(os.environ.get("OMNIVOICE_DATA_ROOT", str(Path.home() / "Documents" / "OmniVoice-Mac")))
MODEL = None

OUTPUT_DIR = DATA_ROOT / "outputs"
OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

@app.on_event("startup")
def startup():
    global MODEL, PROVENANCE
    model_path = resolve_base_model()
    PROVENANCE = runtime_provenance(model_path)
    if (PROVENANCE['package_version'] != MANIFEST['expected_package_version'] or
        PROVENANCE['package_commit'] != MANIFEST['expected_package_commit']):
        raise RuntimeError("OmniVoice runtime differs from the verified package. Review provenance before using this build.")
    MODEL = load_inference_model(
        str(model_path),
        device_map="mps",
        dtype=torch.float16,
    )

@app.get("/health")
def health():
    return {"ok": MODEL is not None, "device": "mps", "provenance": PROVENANCE, "generation_contract": 3}


def apply_seed(seed):
    if seed <= 0:
        return
    import random
    import numpy as np
    random.seed(seed)
    np.random.seed(seed % (2**32 - 1))
    torch.manual_seed(seed)
    if torch.backends.mps.is_available():
        torch.mps.manual_seed(seed)

def save_audio(audio):
    output = OUTPUT_DIR / f"voxaster-{uuid.uuid4().hex[:8]}.wav"
    sf.write(str(output), audio[0], 24000)
    return str(output)

def generate_omni(model, request, prompt=None, text=None, index=0):
    apply_seed(request.seed_for(index))
    kwargs = request.omni_kwargs(OmniVoiceGenerationConfig, text)
    if prompt is not None:
        kwargs['voice_clone_prompt'] = prompt
    if request.instruct.strip():
        kwargs['instruct'] = request.instruct.strip()
    return model.generate(**kwargs)


# Model inference must never run on the asyncio event loop: doing so blocks
# every other request (including /health) until synthesis finishes. Run it in a
# worker thread, one job at a time, because the MPS model is not re-entrant.
GPU_LOCK = threading.Lock()

async def on_gpu(work):
    def locked():
        with GPU_LOCK:
            return work()
    return await run_in_threadpool(locked)


async def saved_reference(upload):
    suffix = Path(upload.filename or "reference.wav").suffix or ".wav"
    data = await upload.read()
    with tempfile.NamedTemporaryFile(delete=False, suffix=suffix) as tmp:
        tmp.write(data)
        return tmp.name


def discard(path):
    try:
        os.unlink(path)
    except Exception:
        pass


# Preparing a voice prompt (and auto-transcribing it) is the slow part of a
# clone; Cast and repeat takes reuse the same few voices, so keep a small cache
# for the resident model only.
PROMPT_CACHE = OrderedDict()
PROMPT_CACHE_SIZE = 6

def clone_prompt(model, request, ref_path):
    ref_text = clone_reference_text(ref_path, request.ref_text)
    cacheable = model is MODEL and isinstance(model, OmniVoice)
    if cacheable:
        key = (hashlib.sha256(Path(ref_path).read_bytes()).hexdigest(), ref_text)
        if key in PROMPT_CACHE:
            PROMPT_CACHE.move_to_end(key)
            return PROMPT_CACHE[key]
    prompt = model.create_voice_clone_prompt(ref_audio=ref_path, ref_text=ref_text)
    if cacheable:
        PROMPT_CACHE[key] = prompt
        while len(PROMPT_CACHE) > PROMPT_CACHE_SIZE:
            PROMPT_CACHE.popitem(last=False)
    return prompt


@app.post("/analyze-reference")
async def analyze_reference(
    ref_text: str = Form(""),
    ref_audio: UploadFile = File(...),
):
    import numpy as np

    ref_path = None
    try:
        suffix = Path(ref_audio.filename or "reference.wav").suffix or ".wav"
        with tempfile.NamedTemporaryFile(delete=False, suffix=suffix) as tmp:
            tmp.write(await ref_audio.read())
            ref_path = tmp.name

        audio, sr = sf.read(ref_path, always_2d=False)
        audio = np.asarray(audio, dtype=np.float32)
        if audio.ndim > 1:
            audio = np.mean(audio, axis=1)

        if audio.size == 0 or sr <= 0:
            raise ValueError("Reference audio is empty.")

        # Keep analysis bounded and fast.
        max_samples = int(sr * 60)
        audio = audio[:max_samples]

        duration = float(len(audio) / sr)
        peak = float(np.max(np.abs(audio)) + 1e-12)
        rms = float(np.sqrt(np.mean(audio ** 2)) + 1e-12)
        peak_db = float(20 * np.log10(peak))
        rms_db = float(20 * np.log10(rms))
        clipping_ratio = float(np.mean(np.abs(audio) >= 0.995))

        # 25 ms RMS frames, 10 ms hop.
        frame = max(64, int(sr * 0.025))
        hop = max(32, int(sr * 0.010))
        frame_rms = []
        frames = []
        for i in range(0, max(1, len(audio) - frame + 1), hop):
            x = audio[i:i+frame]
            if len(x) < frame:
                break
            frames.append(x)
            frame_rms.append(float(np.sqrt(np.mean(x*x)) + 1e-12))

        if frame_rms:
            dbs = 20 * np.log10(np.asarray(frame_rms) + 1e-12)
            noise_floor = float(np.percentile(dbs, 20))
            threshold = max(-42.0, noise_floor + 10.0)
            active = dbs > threshold
            speech_ratio = float(np.mean(active))
        else:
            dbs = np.asarray([])
            active = np.asarray([], dtype=bool)
            noise_floor = -60.0
            speech_ratio = 0.0

        pause_ratio = float(max(0.0, min(1.0, 1.0 - speech_ratio)))

        # Lightweight autocorrelation pitch estimate on active frames.
        pitches = []
        min_f, max_f = 65.0, 350.0
        min_lag = max(1, int(sr / max_f))
        max_lag = max(min_lag + 1, int(sr / min_f))

        for idx, x in enumerate(frames[::4]):
            source_idx = idx * 4
            if len(active) > source_idx and not active[source_idx]:
                continue

            x = x - np.mean(x)
            energy = np.sqrt(np.mean(x*x))
            if energy < 1e-4:
                continue

            corr = np.correlate(x, x, mode="full")[len(x)-1:]
            upper = min(max_lag, len(corr)-1)
            if upper <= min_lag:
                continue

            segment = corr[min_lag:upper+1]
            lag = int(np.argmax(segment)) + min_lag
            if corr[0] > 0 and corr[lag] / corr[0] >= 0.25:
                hz = sr / lag
                if min_f <= hz <= max_f:
                    pitches.append(float(hz))

        if pitches:
            pitch_hz = float(np.median(pitches))
            pitch_range_hz = float(np.percentile(pitches, 90) - np.percentile(pitches, 10))
        else:
            pitch_hz = 0.0
            pitch_range_hz = 0.0

        words = len([w for w in ref_text.strip().split() if w])
        wpm = float(words / duration * 60.0) if words > 0 and duration > 0 else 0.0

        if wpm > 0:
            if wpm < 115: pace_label = "Slow"
            elif wpm < 165: pace_label = "Natural"
            elif wpm < 205: pace_label = "Fast"
            else: pace_label = "Very fast"
            recommended_speed = max(0.82, min(1.18, wpm / 155.0))
        else:
            # Without a transcript this is intentionally a rough speech-density estimate.
            if speech_ratio < 0.48:
                pace_label = "Measured"
                recommended_speed = 0.92
            elif speech_ratio < 0.68:
                pace_label = "Natural"
                recommended_speed = 1.00
            else:
                pace_label = "Continuous"
                recommended_speed = 1.06

        # Reference quality score: signal level, clipping, usable duration and silence.
        quality = 100
        if duration < 3: quality -= 25
        elif duration < 5: quality -= 8
        if duration > 30: quality -= 4
        if rms_db < -38: quality -= 24
        elif rms_db < -30: quality -= 10
        if peak_db > -0.15 or clipping_ratio > 0.002: quality -= 25
        elif clipping_ratio > 0.0002: quality -= 10
        if speech_ratio < 0.35: quality -= 18
        if noise_floor > -35: quality -= 15
        quality = int(max(0, min(100, quality)))

        if quality >= 85: quality_label = "Excellent"
        elif quality >= 70: quality_label = "Good"
        elif quality >= 50: quality_label = "Fair"
        else: quality_label = "Poor"

        # Heuristic recommendations, deliberately kept within conservative ranges.
        if quality >= 80:
            recommended_steps = 40
            recommended_guidance = 2.2
        elif quality >= 60:
            recommended_steps = 36
            recommended_guidance = 2.0
        else:
            recommended_steps = 32
            recommended_guidance = 1.8

        recommended_denoise = bool(noise_floor > -48 or rms_db < -32)

        return {
            "duration": round(duration, 3),
            "pitch_hz": round(pitch_hz, 1),
            "pitch_range_hz": round(pitch_range_hz, 1),
            "rms_db": round(rms_db, 2),
            "peak_db": round(peak_db, 2),
            "speech_ratio": round(speech_ratio, 3),
            "pause_ratio": round(pause_ratio, 3),
            "noise_floor_db": round(noise_floor, 2),
            "clipping_ratio": round(clipping_ratio, 6),
            "wpm": round(wpm, 1),
            "pace_label": pace_label,
            "quality_score": quality,
            "quality_label": quality_label,
            "recommended": {
                "speed": round(recommended_speed, 2),
                "steps": float(recommended_steps),
                "guidance": round(recommended_guidance, 1),
                "denoise": recommended_denoise,
            },
            "note": "Recommendations are heuristic starting points; Engine Lab remains the final quality test.",
        }

    except Exception as e:
        traceback.print_exc()
        return JSONResponse(
            status_code=500,
            content={"error": f"{type(e).__name__}: {e}"},
        )
    finally:
        if ref_path:
            try:
                os.unlink(ref_path)
            except Exception:
                pass

@app.post("/preview-speech")
async def preview_speech(text: str = Form(''), pronunciations: str = Form(''),
                         pronunciation_mode: str = Form('words')):
    if pronunciation_mode not in ('words', 'substring'):
        raise HTTPException(422, "Unknown pronunciation match mode.")
    return inspect_speech(text, pronunciations, pronunciation_mode)


@app.post("/generate-clone")
async def generate_clone(request: GenerationRequest = Depends(generation_form),
                         ref_audio: UploadFile = File(...)):
    ref_path = await saved_reference(ref_audio)
    try:
        return await on_gpu(lambda: {"output": save_audio(
            generate_omni(MODEL, request, clone_prompt(MODEL, request, ref_path)))})
    finally:
        discard(ref_path)


@app.post("/generate-design")
async def generate_design(request: GenerationRequest = Depends(generation_form)):
    return await on_gpu(lambda: {"output": save_audio(generate_omni(MODEL, request))})


def split_script(text, max_chars=420):
    import re
    text = re.sub(r"\s+", " ", text).strip()
    sentences = re.split(r"(?<=[.!?])\s+", text)
    chunks, current = [], ""
    for sentence in sentences:
        candidate = (current + " " + sentence).strip()
        if current and len(candidate) > max_chars:
            chunks.append(current); current = sentence
        else:
            current = candidate
    if current: chunks.append(current)
    return chunks

@app.post("/generate-long")
async def generate_long(request: GenerationRequest = Depends(generation_form),
                        ref_audio: UploadFile = File(...)):
    import numpy as np
    if request.duration is not None:
        raise HTTPException(422, "Fixed duration is supported for single passages and Variants, not Long Form masters or retries.")
    # Explicit segments are authoritative: do not re-split edited text.
    chunks = request.segments if request.segments is not None else split_script(request.text)
    if request.retry_index is not None and request.retry_index >= len(chunks):
        raise HTTPException(422, "Retry segment index is out of range.")
    indices = [request.retry_index] if request.retry_index is not None else list(range(len(chunks)))
    ref_path = await saved_reference(ref_audio)
    try:
        def work():
            prompt = clone_prompt(MODEL, request, ref_path)
            pieces, outputs = [], []
            for index in indices:
                audio = generate_omni(MODEL, request, prompt, text=chunks[index], index=index)
                outputs.append(save_audio(audio))
                pieces.append(np.asarray(audio[0], dtype=np.float32))
            return pieces, outputs
        pieces, outputs = await on_gpu(work)
    finally:
        discard(ref_path)
    if request.retry_index is not None:
        return {"output": outputs[0], "retry_index": request.retry_index, "segment_outputs": outputs}
    # Preserve the existing Long Form master join; no new assembly system.
    silence = np.zeros(int(24000 * 0.18), dtype=np.float32)
    joined = []
    for index, piece in enumerate(pieces):
        if index:
            joined.append(silence)
        joined.append(piece)
    output = save_audio([np.concatenate(joined)])
    return {"output": output, "chunks": len(chunks), "segment_outputs": outputs}


@app.post("/generate-variants")
async def generate_variants(request: GenerationRequest = Depends(generation_form),
                            ref_audio: UploadFile = File(...)):
    ref_path = await saved_reference(ref_audio)
    try:
        def work():
            prompt = clone_prompt(MODEL, request, ref_path)
            return {"outputs": [save_audio(generate_omni(MODEL, request, prompt, index=i))
                                for i in range(request.count)]}
        return await on_gpu(work)
    finally:
        discard(ref_path)


# ---------------------------------------------------------------------------
# Studio tools: Reference Cleaner, Take Doctor, Cast assembly
# ---------------------------------------------------------------------------
import numpy as np
from studio_tools import (best_reference_window, take_report, splice,
                          mono as to_mono)

def read_audio(path, fallback_sr=24000):
    try:
        audio, sr = sf.read(str(path), always_2d=False, dtype="float32")
        return to_mono(audio), sr
    except Exception:
        from omnivoice.utils.audio import load_audio
        return np.squeeze(load_audio(str(path), fallback_sr)).astype(np.float32), fallback_sr

def output_file(path):
    """Only VoxAster's own outputs may be read or spliced by these routes."""
    resolved = Path(path).resolve()
    if OUTPUT_DIR.resolve() not in resolved.parents or not resolved.is_file():
        raise HTTPException(422, "Takes must be VoxAster output files.")
    return resolved

def asr_words(path):
    """Complete transcript plus word timings (runs inside the GPU lock).

    Whisper's word-timestamp decoding can stop after the first sentence, so the
    text comes from a plain pass; timings are re-requested from where decoding
    stopped, and any still-untimed words are merged in without times."""
    if getattr(MODEL, "_asr_pipe", None) is None:
        MODEL.load_asr_model()
    from omnivoice.utils.audio import load_audio
    from studio_tools import merge_untimed, WORD
    pipe = MODEL._asr_pipe
    wav = np.squeeze(load_audio(str(path), 16000)).astype(np.float32)
    duration = len(wav) / 16000
    long_audio = dict(chunk_length_s=30) if duration > 30 else {}
    plain = pipe({"array": wav, "sampling_rate": 16000}, **long_audio).get("text", "").strip()
    target = len(WORD.findall(plain))
    timed, offset = [], 0.0
    for _ in range(4):
        segment = wav[int(offset * 16000):]
        if len(segment) < int(0.3 * 16000):
            break
        result = pipe({"array": segment, "sampling_rate": 16000}, return_timestamps="word", **long_audio)
        chunks = result.get("chunks", [])
        if not chunks:
            break
        for chunk in chunks:
            t0, t1 = chunk.get("timestamp") or (None, None)
            t0 = float(t0 or 0.0); t1 = float(t1 if t1 is not None else t0)
            timed.append((chunk.get("text", ""), offset + t0, offset + t1))
        last = timed[-1][2]
        if len(timed) >= target or last >= duration - 0.4 or last <= offset + 0.05:
            break
        offset = last
    return plain, merge_untimed(plain, timed), wav

@app.post("/reference/clean")
async def reference_clean(ref_audio: UploadFile = File(...), target: float = Form(12.0)):
    if not 6.0 <= target <= 15.0:
        raise HTTPException(422, "Target length must be 6–15 seconds.")
    ref_path = await saved_reference(ref_audio)
    stem = re.sub(r"[^\w -]", "", Path(ref_audio.filename or "voice").stem).strip()[:40] or "voice"
    try:
        def work():
            audio, sr = read_audio(ref_path)
            window = best_reference_window(audio, sr, target=target)
            clip = audio[int(window["start"] * sr):int(window["end"] * sr)]
            folder = DATA_ROOT / "voices" / "cleaned"
            folder.mkdir(parents=True, exist_ok=True)
            out = folder / f"{stem} clean {uuid.uuid4().hex[:6]}.wav"
            sf.write(str(out), clip, sr)
            transcript, _, _ = asr_words(out)
            return dict(window, output=str(out), transcript=transcript,
                        source_duration=round(len(audio) / sr, 3))
        return await on_gpu(work)
    finally:
        discard(ref_path)

@app.post("/takes/check")
async def takes_check(script: str = Form(...), paths: str = Form(...)):
    try:
        items = json.loads(paths)
    except ValueError as exc:
        raise HTTPException(422, "paths must be a JSON list.") from exc
    if not isinstance(items, list) or not 1 <= len(items) <= 8 or not all(isinstance(i, str) for i in items):
        raise HTTPException(422, "Send one to eight take paths.")
    if not script.strip():
        raise HTTPException(422, "The script is empty.")
    files = [(item, output_file(item)) for item in items]

    def work():
        reports = {}
        for key, path in files:
            transcript, words, wav = asr_words(path)
            report = take_report(script, words, wav, 16000)
            report["transcript"] = transcript
            reports[key] = report
        return {"reports": reports}
    return await on_gpu(work)

@app.post("/takes/repair")
async def takes_repair(request: GenerationRequest = Depends(generation_form),
                       take_path: str = Form(...), start: float = Form(...), end: float = Form(...),
                       ref_audio: Optional[UploadFile] = File(None)):
    take = output_file(take_path)
    if not (0 <= start <= end) or end - start > 120:  # start == end inserts a missing sentence
        raise HTTPException(422, "Invalid repair range.")
    ref_path = await saved_reference(ref_audio) if ref_audio is not None else None
    try:
        def work():
            prompt = clone_prompt(MODEL, request, ref_path) if ref_path else None
            fresh = np.asarray(generate_omni(MODEL, request, prompt)[0], dtype=np.float32)
            audio, sr = read_audio(take)
            if sr != 24000:
                raise ValueError("Only VoxAster 24 kHz takes can be repaired.")
            joined = splice(audio, fresh, sr, start, min(end, len(audio) / sr))
            return {"output": save_audio([joined])}
        return await on_gpu(work)
    finally:
        if ref_path:
            discard(ref_path)

@app.post("/cast/assemble")
async def cast_assemble(paths: str = Form(...), gap_ms: int = Form(350)):
    try:
        items = json.loads(paths)
    except ValueError as exc:
        raise HTTPException(422, "paths must be a JSON list.") from exc
    if not isinstance(items, list) or not 1 <= len(items) <= 400:
        raise HTTPException(422, "Send 1–400 line files.")
    if not 0 <= gap_ms <= 3000:
        raise HTTPException(422, "Gap must be 0–3000 ms.")
    files = [output_file(item) for item in items]

    def work():
        gap = np.zeros(int(24000 * gap_ms / 1000), dtype=np.float32)
        joined = []
        for index, path in enumerate(files):
            audio, sr = read_audio(path)
            if sr != 24000:
                raise ValueError("Cast lines must be VoxAster 24 kHz takes.")
            if index:
                joined.append(gap)
            joined.append(audio)
        return {"output": save_audio([np.concatenate(joined)])}
    return await run_in_threadpool(work)


# Performance productions use a distinct, strict app-level route. No raw
# performance script is accepted by the ordinary generation request adapter.
from performance import ProductionStore, PERFORMANCE_CAPABILITIES
from performance_script import compile_script
import json

PERFORMANCE = ProductionStore(DATA_ROOT / 'performance')

@app.post("/performance/preview")
async def performance_preview(text: str = Form(''), pronunciations: str = Form(''),
                              pronunciation_mode: str = Form('words')):
    try:
        plan = compile_script(text, pronunciations, pronunciation_mode)
        issues = [i for s in plan['segments'] for i in s.get('issues',[])]
        return dict(text='\n'.join(s['text'] if s['kind']=='speech' else f"Silence: {s['milliseconds']} ms ({s['samples']} samples)" for s in plan['segments']),
                    issues=issues, can_generate=True, **plan)
    except ValueError as exc:
        return dict(text='', issues=[dict(level='error',message=str(exc))], can_generate=False)

@app.post("/performance/prepare")
async def performance_prepare(script: str = Form(...), settings: str = Form(...),
                              engine: str = Form('OmniVoice Zero-Shot'), ref_audio: UploadFile = File(...)):
    try:
        configuration = json.loads(settings)
        if not isinstance(configuration, dict):
            raise ValueError('Settings must be a generation-request object.')
        return PERFORMANCE.create(script, configuration, await ref_audio.read(), ref_audio.filename, engine)
    except (ValueError, TypeError) as exc:
        raise HTTPException(422, str(exc)) from exc

@app.get("/performance/capabilities")
async def performance_capabilities():
    return PERFORMANCE_CAPABILITIES

@app.get("/performance")
async def performance_list():
    return PERFORMANCE.list()

@app.get("/performance/{production_id}")
async def performance_get(production_id: str):
    try:
        return PERFORMANCE.read(production_id)
    except (ValueError, OSError) as exc:
        raise HTTPException(404, str(exc)) from exc

@app.post("/performance/{production_id}/render/{segment_id}")
async def performance_render(production_id: str, segment_id: str):
    try:
        return await on_gpu(lambda: PERFORMANCE.render(production_id, segment_id, MODEL, generate_omni))
    except (ValueError, OSError) as exc:
        raise HTTPException(422, str(exc)) from exc

@app.post("/performance/{production_id}/rebuild")
async def performance_rebuild(production_id: str):
    try:
        return PERFORMANCE.rebuild(production_id)
    except (ValueError, OSError) as exc:
        raise HTTPException(422, str(exc)) from exc


# ---------------------------------------------------------------------------
# Engine Lab: OmniVoice vs isolated F5-TTS
# ---------------------------------------------------------------------------
import random
import subprocess

F5_CLI = Path.home() / "Documents" / "OmniVoice-Mac" / "f5-venv" / "bin" / "f5-tts_infer-cli"

PERSONAL_ROOT_EARLY = DATA_ROOT / "personal-voice"
PERSONAL_MERGED_EARLY = PERSONAL_ROOT_EARLY / "merged-model"

TRAINED_ENGINES_DIR = PERSONAL_ROOT_EARLY / "engines"
TRAINED_ENGINES_REGISTRY = PERSONAL_ROOT_EARLY / "trained-engines.json"
TRAINED_ENGINES_DIR.mkdir(parents=True, exist_ok=True)

def _load_trained_engines():
    if not TRAINED_ENGINES_REGISTRY.exists():
        return []
    try:
        data = json.loads(TRAINED_ENGINES_REGISTRY.read_text(encoding="utf-8"))
        if not isinstance(data, list):
            return []
        cleaned = []
        for item in data:
            if not isinstance(item, dict):
                continue
            name = str(item.get("name", "")).strip()
            path = str(item.get("path", "")).strip()
            if name and path and Path(path).exists():
                cleaned.append(item)
        return cleaned
    except Exception:
        return []

def _trained_engine_map():
    return {item["name"]: item["path"] for item in _load_trained_engines()}


def personal_model_is_ready():
    return (
        PERSONAL_MERGED_EARLY.exists()
        and (PERSONAL_MERGED_EARLY / "config.json").exists()
        and (PERSONAL_MERGED_EARLY / "model.safetensors").exists()
    )

@app.get("/engine-lab/status")
def engine_lab_status():
    engines = ["OmniVoice Zero-Shot"]
    engines.extend(_trained_engine_map().keys())
    if F5_CLI.exists():
        engines.append("F5-TTS")

    return {
        "omnivoice": MODEL is not None,
        "personal_available": personal_model_is_ready(),
        "personal_path": str(PERSONAL_MERGED_EARLY) if personal_model_is_ready() else "",
        "f5_available": F5_CLI.exists(),
        "f5_cli": str(F5_CLI),
        "engines": engines,
        "capabilities": {name: F5_CAPABILITIES if name == "F5-TTS" else OMNI_CAPABILITIES for name in engines},
    }

def run_f5(ref_path, ref_text, text, output_path, speed):
    if not F5_CLI.exists():
        raise RuntimeError(f"F5-TTS CLI not found at {F5_CLI}")

    cmd = [
        str(F5_CLI),
        "--model", "F5TTS_v1_Base",
        "--ref_audio", str(ref_path),
        "--ref_text", ref_text or "",
        "--gen_text", text,
        "--output_dir", str(Path(output_path).parent),
        "--output_file", Path(output_path).name,
        "--device", "cpu",
        "--speed", str(speed),
    ]

    env = os.environ.copy()
    env["PYTHONDONTWRITEBYTECODE"] = "1"
    env["PYTORCH_ENABLE_MPS_FALLBACK"] = "1"

    result = subprocess.run(
        cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        env=env,
        timeout=1800,
    )

    if result.returncode != 0:
        detail = (result.stderr or result.stdout or "Unknown F5 error")[-1800:]
        raise RuntimeError("F5-TTS failed: " + detail)

    if not Path(output_path).exists():
        raise RuntimeError("F5-TTS finished but the expected WAV file was not created.")

@app.post("/engine-lab/compare")
async def engine_lab_compare(
    request: GenerationRequest = Depends(generation_form),
    engine_a: str = Form("OmniVoice Zero-Shot"),
    engine_b: str = Form("OmniVoice Trained"),
    ref_audio: UploadFile = File(...),
):
    ref_path = None

    try:
        if engine_a == engine_b:
            raise RuntimeError("Choose two different engines.")

        trained_engines = _trained_engine_map()
        available = ["OmniVoice Zero-Shot"]
        available.extend(trained_engines.keys())
        if F5_CLI.exists():
            available.append("F5-TTS")

        for selected in (engine_a, engine_b):
            if selected not in available:
                raise RuntimeError(f"Engine is not available: {selected}")

        # Validate both engines before either generates audio.
        for selected in (engine_a, engine_b):
            request.validate_engine(selected)

        suffix = Path(ref_audio.filename or "reference.wav").suffix or ".wav"
        with tempfile.NamedTemporaryFile(delete=False, suffix=suffix) as tmp:
            tmp.write(await ref_audio.read())
            ref_path = tmp.name

        def generate_engine(name):
            output = OUTPUT_DIR / f"engine-lab-{uuid.uuid4().hex[:8]}.wav"

            if name == "OmniVoice Zero-Shot":
                prompt = clone_prompt(MODEL, request, ref_path)
                audio = generate_omni(MODEL, request, prompt)
                sf.write(str(output), audio[0], 24000)
                return str(output)

            if name in trained_engines:
                import torch
                from omnivoice import OmniVoice

                trained_model = load_inference_model(
                    str(trained_engines[name]),
                    device_map="mps" if torch.backends.mps.is_available() else "cpu",
                    dtype=torch.float32,
                )
                prompt = clone_prompt(trained_model, request, ref_path)
                audio = generate_omni(trained_model, request, prompt)
                sf.write(str(output), audio[0], 24000)
                return str(output)

            if name == "F5-TTS":
                run_f5(**request.f5_arguments(ref_path, output))
                return str(output)

            raise RuntimeError(f"Unsupported engine: {name}")

        first = await on_gpu(lambda: generate_engine(engine_a))
        second = await on_gpu(lambda: generate_engine(engine_b))

        pair = [(engine_a, first), (engine_b, second)]
        random.SystemRandom().shuffle(pair)

        return {
            "A": pair[0][1],
            "B": pair[1][1],
            "map": {
                "A": pair[0][0],
                "B": pair[1][0],
            },
        }

    except ValueError as e:
        raise HTTPException(422, str(e)) from e
    except Exception as e:
        traceback.print_exc()
        return JSONResponse(
            status_code=500,
            content={"error": f"{type(e).__name__}: {e}"},
        )
    finally:
        if ref_path:
            try:
                os.unlink(ref_path)
            except Exception:
                pass



# Existing saved-engine inference only. No training, token extraction or model publication.
PERSONAL_MERGED = PERSONAL_MERGED_EARLY

@app.post("/personal/prepare")
@app.post("/personal/train")
@app.post("/personal/merge")
@app.post("/personal/save-engine")
def training_removed():
    raise HTTPException(410, "Training, dataset preparation and model improvement are not available in VoxAster 3.8.0. Existing data was preserved.")

@app.get("/personal/model-status")
def personal_model_status():
    ready = (
        PERSONAL_MERGED.exists()
        and (PERSONAL_MERGED / "config.json").exists()
        and (PERSONAL_MERGED / "model.safetensors").exists()
    )
    saved = _load_trained_engines()
    return {
        "ready": ready or bool(saved),
        "path": str(PERSONAL_MERGED) if ready else (saved[-1]["path"] if saved else ""),
        "saved_engines": saved,
    }

@app.post("/personal/generate")
async def personal_generate(
    text: str = Form(...),
    ref_text: str = Form(""),
    audio: UploadFile = File(...),
):
    try:
        if not (PERSONAL_MERGED / "config.json").exists():
            raise RuntimeError("Personal Voice model has not been prepared yet.")

        suffix = Path(audio.filename or "reference.wav").suffix or ".wav"
        with tempfile.NamedTemporaryFile(delete=False, suffix=suffix) as f:
            f.write(await audio.read())
            ref_path = f.name

        try:
            # Load the merged model for this benchmark request. This is slower
            # than a persistent cache but isolates it from the zero-shot engine.
            def work():
                device = "mps" if torch.backends.mps.is_available() else "cpu"
                personal_model = load_inference_model(
                    str(PERSONAL_MERGED),
                    device_map=device,
                    dtype=torch.float32,
                )
                return personal_model.generate(
                    text=text.strip(),
                    ref_audio=ref_path,
                    ref_text=clone_reference_text(ref_path, ref_text),
                )
            result = await on_gpu(work)
            out = tempfile.NamedTemporaryFile(delete=False, suffix=".wav")
            out.close()
            sf.write(out.name, result[0], 24000)
            return FileResponse(out.name, media_type="audio/wav", filename="personal-voice.wav")
        finally:
            try:
                os.unlink(ref_path)
            except Exception:
                pass
    except Exception as e:
        traceback.print_exc()
        return JSONResponse(status_code=500, content={"error": f"{type(e).__name__}: {e}"})


def exit_with_parent(interval=2.0):
    """If the app that launched this engine crashes or is force-quit, stop too,
    so the next launch does not find port 8011 held by an orphaned engine."""
    import time
    parent = os.getppid()

    def watch():
        while True:
            time.sleep(interval)
            if os.getppid() != parent:
                os._exit(0)
    threading.Thread(target=watch, name="parent-watch", daemon=True).start()


if __name__ == "__main__":
    exit_with_parent()
    uvicorn.run(app, host="127.0.0.1", port=8011, log_level="warning")
