import os
import tempfile
import uuid
import traceback
from pathlib import Path

from fastapi import FastAPI, UploadFile, File, Form
from fastapi.responses import JSONResponse
import uvicorn
import torch
import soundfile as sf

from omnivoice import OmniVoice, OmniVoiceGenerationConfig

app = FastAPI()
MODEL = None

OUTPUT_DIR = Path.home() / "Documents" / "OmniVoice-Mac" / "outputs"
OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

@app.on_event("startup")
def startup():
    global MODEL
    MODEL = OmniVoice.from_pretrained(
        "k2-fsa/OmniVoice",
        device_map="mps",
        dtype=torch.float16,
    )

@app.get("/health")
def health():
    return {"ok": MODEL is not None, "device": "mps"}

def generation_config(steps, guidance):
    return OmniVoiceGenerationConfig(
        num_step=int(steps),
        guidance_scale=float(guidance),
        denoise=True,
        preprocess_prompt=True,
        postprocess_output=True,
    )

def save_audio(audio):
    output = OUTPUT_DIR / f"omnivoice-{uuid.uuid4().hex[:8]}.wav"
    sf.write(str(output), audio[0], 24000)
    return str(output)

def apply_pronunciations(text, rules):
    for line in rules.splitlines():
        if "=" in line:
            a, b = line.split("=", 1)
            if a.strip() and b.strip():
                text = text.replace(a.strip(), b.strip())
    return text

@app.post("/generate-clone")
async def generate_clone(
    text: str = Form(...),
    ref_text: str = Form(""),
    pronunciations: str = Form(""),
    language: str = Form("Auto detect"),
    speed: float = Form(1.0),
    steps: int = Form(32),
    guidance: float = Form(2.0),
    ref_audio: UploadFile = File(...),
):
    ref_path = None
    try:
        suffix = Path(ref_audio.filename or "reference.wav").suffix or ".wav"
        with tempfile.NamedTemporaryFile(delete=False, suffix=suffix) as tmp:
            tmp.write(await ref_audio.read())
            ref_path = tmp.name

        prompt = MODEL.create_voice_clone_prompt(
            ref_audio=ref_path,
            ref_text=(ref_text.strip() or None),
        )

        audio = MODEL.generate(
            text=apply_pronunciations(text.strip(), pronunciations),
            voice_clone_prompt=prompt,
            generation_config=generation_config(steps, guidance),
            speed=float(speed),
        )

        return {"output": save_audio(audio)}
    except Exception as e:
        traceback.print_exc()
        return JSONResponse(status_code=500, content={"error": f"{type(e).__name__}: {e}"})
    finally:
        if ref_path:
            try:
                os.unlink(ref_path)
            except Exception:
                pass

@app.post("/generate-design")
async def generate_design(
    text: str = Form(...),
    instruct: str = Form(""),
    speed: float = Form(1.0),
    steps: int = Form(32),
    guidance: float = Form(2.0),
):
    try:
        kwargs = dict(
            text=text.strip(),
            generation_config=generation_config(steps, guidance),
            speed=float(speed),
        )
        if instruct.strip():
            kwargs["instruct"] = instruct.strip()

        audio = MODEL.generate(**kwargs)
        return {"output": save_audio(audio)}
    except Exception as e:
        traceback.print_exc()
        return JSONResponse(status_code=500, content={"error": f"{type(e).__name__}: {e}"})


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
async def generate_long(
    text: str = Form(...), ref_text: str = Form(""),
    speed: float = Form(1.0), steps: int = Form(32), guidance: float = Form(2.0),
    pronunciations: str = Form(""), ref_audio: UploadFile = File(...)
):
    import numpy as np
    ref_path = None
    try:
        suffix = Path(ref_audio.filename or "reference.wav").suffix or ".wav"
        with tempfile.NamedTemporaryFile(delete=False, suffix=suffix) as tmp:
            tmp.write(await ref_audio.read()); ref_path = tmp.name
        prompt = MODEL.create_voice_clone_prompt(ref_audio=ref_path, ref_text=(ref_text.strip() or None))
        chunks = split_script(apply_pronunciations(text, pronunciations))
        if not chunks: raise ValueError("The script is empty.")
        pieces, sr = [], 24000
        silence = np.zeros(int(sr * 0.18), dtype=np.float32)
        for i, chunk in enumerate(chunks):
            audio = MODEL.generate(text=chunk, voice_clone_prompt=prompt,
                generation_config=generation_config(steps, guidance), speed=float(speed))
            pieces.append(np.asarray(audio[0], dtype=np.float32))
            if i < len(chunks)-1: pieces.append(silence)
        master = np.concatenate(pieces)
        output = OUTPUT_DIR / f"omnivoice-long-{uuid.uuid4().hex[:8]}.wav"
        sf.write(str(output), master, sr)
        return {"output": str(output), "chunks": len(chunks)}
    except Exception as e:
        traceback.print_exc()
        return JSONResponse(status_code=500, content={"error": f"{type(e).__name__}: {e}"})
    finally:
        if ref_path:
            try: os.unlink(ref_path)
            except Exception: pass


@app.post("/generate-variants")
async def generate_variants(
    text: str = Form(...), count: int = Form(2), ref_text: str = Form(""),
    speed: float = Form(1.0), steps: int = Form(32), guidance: float = Form(2.0),
    ref_audio: UploadFile = File(...)
):
    ref_path=None
    try:
        count=max(2,min(4,int(count)))
        suffix=Path(ref_audio.filename or "reference.wav").suffix or ".wav"
        with tempfile.NamedTemporaryFile(delete=False,suffix=suffix) as tmp:
            tmp.write(await ref_audio.read());ref_path=tmp.name
        prompt=MODEL.create_voice_clone_prompt(ref_audio=ref_path,ref_text=(ref_text.strip() or None))
        outputs=[]
        for _ in range(count):
            audio=MODEL.generate(text=text.strip(),voice_clone_prompt=prompt,
                generation_config=generation_config(steps,guidance),speed=float(speed))
            out=OUTPUT_DIR/f"omnivoice-variant-{uuid.uuid4().hex[:8]}.wav"
            sf.write(str(out),audio[0],24000);outputs.append(str(out))
        return {"outputs":outputs}
    except Exception as e:
        traceback.print_exc()
        return JSONResponse(status_code=500,content={"error":f"{type(e).__name__}: {e}"})
    finally:
        if ref_path:
            try: os.unlink(ref_path)
            except Exception: pass


# ---------------------------------------------------------------------------
# Engine Lab: OmniVoice vs isolated F5-TTS
# ---------------------------------------------------------------------------
import random
import subprocess

F5_CLI = Path.home() / "Documents" / "OmniVoice-Mac" / "f5-venv" / "bin" / "f5-tts_infer-cli"

PERSONAL_ROOT_EARLY = Path.home() / "Documents" / "OmniVoice-Mac" / "personal-voice"
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

def _save_trained_engines(items):
    TRAINED_ENGINES_REGISTRY.write_text(
        json.dumps(items, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )

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
    text: str = Form(...),
    ref_text: str = Form(""),
    speed: float = Form(1.0),
    steps: int = Form(32),
    guidance: float = Form(2.0),
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

        suffix = Path(ref_audio.filename or "reference.wav").suffix or ".wav"
        with tempfile.NamedTemporaryFile(delete=False, suffix=suffix) as tmp:
            tmp.write(await ref_audio.read())
            ref_path = tmp.name

        def generate_engine(name):
            output = OUTPUT_DIR / f"engine-lab-{uuid.uuid4().hex[:8]}.wav"

            if name == "OmniVoice Zero-Shot":
                prompt = MODEL.create_voice_clone_prompt(
                    ref_audio=ref_path,
                    ref_text=(ref_text.strip() or None),
                )
                audio = MODEL.generate(
                    text=text.strip(),
                    voice_clone_prompt=prompt,
                    generation_config=generation_config(steps, guidance),
                    speed=float(speed),
                )
                sf.write(str(output), audio[0], 24000)
                return str(output)

            if name in trained_engines:
                import torch
                from omnivoice import OmniVoice

                trained_model = OmniVoice.from_pretrained(
                    str(trained_engines[name]),
                    device_map="mps" if torch.backends.mps.is_available() else "cpu",
                    dtype=torch.float32,
                )
                prompt = trained_model.create_voice_clone_prompt(
                    ref_audio=ref_path,
                    ref_text=(ref_text.strip() or None),
                )
                audio = trained_model.generate(
                    text=text.strip(),
                    voice_clone_prompt=prompt,
                    generation_config=generation_config(steps, guidance),
                    speed=float(speed),
                )
                sf.write(str(output), audio[0], 24000)
                return str(output)

            if name == "F5-TTS":
                run_f5(
                    ref_path=ref_path,
                    ref_text=ref_text.strip(),
                    text=text.strip(),
                    output_path=output,
                    speed=float(speed),
                )
                return str(output)

            raise RuntimeError(f"Unsupported engine: {name}")

        first = generate_engine(engine_a)
        second = generate_engine(engine_b)

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



# ---------------------------------------------------------------------------
# Personal Voice Lab
# ---------------------------------------------------------------------------
import json
import subprocess
import threading
import math

PERSONAL_ROOT = Path.home() / "Documents" / "OmniVoice-Mac" / "personal-voice"
PERSONAL_DATA = PERSONAL_ROOT / "dataset"
PERSONAL_AUDIO = PERSONAL_DATA / "audio"
PERSONAL_TRAIN = PERSONAL_DATA / "train.jsonl"
PERSONAL_DEV = PERSONAL_DATA / "dev.jsonl"
PERSONAL_LOG = PERSONAL_ROOT / "training.log"
PERSONAL_OUT = PERSONAL_ROOT / "exp"
TRAIN_SRC = PERSONAL_ROOT / "training-src"
TRAIN_VENV = PERSONAL_ROOT / "training-venv"

for d in [PERSONAL_ROOT, PERSONAL_DATA, PERSONAL_AUDIO]:
    d.mkdir(parents=True, exist_ok=True)

TRAIN_PROC = None
TRAIN_EXIT = None
TRAIN_LOG_HANDLE = None

def _transcribe_local(path):
    from transformers import pipeline
    import torch
    device = "mps" if torch.backends.mps.is_available() else "cpu"
    pipe = pipeline(
        "automatic-speech-recognition",
        model="openai/whisper-large-v3-turbo",
        device=device,
    )
    result = pipe(str(path))
    return result["text"].strip()

def _read_audio(path):
    import librosa
    import numpy as np
    y, sr = librosa.load(str(path), sr=24000, mono=True)
    return y.astype(np.float32), 24000

def _quality(y, sr):
    import numpy as np
    duration = len(y) / sr
    if duration < 1.0:
        return False, "too_short", duration
    if duration > 30.0:
        return False, "too_long", duration

    peak = float(np.max(np.abs(y))) if len(y) else 0.0
    rms = float(np.sqrt(np.mean(y * y))) if len(y) else 0.0
    clipping = float(np.mean(np.abs(y) >= 0.995)) if len(y) else 1.0

    # Reject only effectively silent audio. Quiet-but-real speech can be normalized safely.
    if peak < 0.01 or rms < 0.0008:
        return False, "near_silence", duration

    if clipping > 0.005:
        return False, "clipping", duration

    return True, "ok", duration

@app.post("/personal/prepare")
async def personal_prepare(request: dict):
    try:
        import random
        import soundfile as sf

        folder = Path(request.get("folder", "")).expanduser()
        language = request.get("language_id", "en")
        auto_transcribe = bool(request.get("auto_transcribe", False))

        if not folder.exists() or not folder.is_dir():
            raise ValueError("Choose a valid recording folder.")

        # Clean only the generated prepared dataset, not source recordings.
        if PERSONAL_AUDIO.exists():
            for p in PERSONAL_AUDIO.glob("*.wav"):
                p.unlink()
        PERSONAL_AUDIO.mkdir(parents=True, exist_ok=True)

        files = []
        for ext in ("*.wav", "*.flac", "*.mp3", "*.m4a", "*.aiff", "*.aif"):
            files.extend(folder.rglob(ext))
        files = sorted(set(files))

        if not files:
            raise ValueError("No supported audio files were found.")

        accepted, rejected = [], []
        total_duration = 0.0

        for i, path in enumerate(files):
            try:
                y, sr = _read_audio(path)
                ok, reason, duration = _quality(y, sr)
                if not ok:
                    rejected.append({"file": str(path), "reason": reason})
                    continue

                txt_path = path.with_suffix(".txt")
                text = txt_path.read_text(encoding="utf-8").strip() if txt_path.exists() else ""
                if not text and auto_transcribe:
                    text = _transcribe_local(path)
                if not text:
                    rejected.append({"file": str(path), "reason": "missing_transcript"})
                    continue

                out = PERSONAL_AUDIO / f"clip_{len(accepted):05d}.wav"
                # Peak-normalize accepted clips conservatively.
                import numpy as np
                peak = float(np.max(np.abs(y))) if len(y) else 1.0
                if peak > 0:
                    target_peak = 0.90
                    gain = target_peak / peak
                    # Avoid extreme amplification of very low-level noise.
                    gain = min(gain, 12.0)
                    y = y * gain
                sf.write(str(out), y, sr, subtype="PCM_16")

                accepted.append({
                    "id": out.stem,
                    "audio_path": str(out),
                    "text": text,
                    "language_id": language,
                })
                total_duration += duration
            except Exception as e:
                rejected.append({"file": str(path), "reason": f"{type(e).__name__}: {e}"})

        rejection_details = [
            f"{Path(item['file']).name}: {item['reason']}"
            for item in rejected
        ]

        # Always persist diagnostics, even when preparation cannot continue.
        (PERSONAL_DATA / "rejected.json").write_text(
            json.dumps(rejected, ensure_ascii=False, indent=2),
            encoding="utf-8",
        )

        if len(accepted) < 2:
            return JSONResponse(
                status_code=400,
                content={
                    "error": "Need at least 2 accepted clips after quality/transcript checks.",
                    "accepted": len(accepted),
                    "rejected": len(rejected),
                    "minutes": total_duration / 60.0,
                    "rejection_details": rejection_details,
                },
            )

        rng = random.Random(42)
        rng.shuffle(accepted)
        dev_n = max(1, round(len(accepted) * 0.1))
        dev = accepted[:dev_n]
        train = accepted[dev_n:]
        if not train:
            train, dev = accepted[:-1], accepted[-1:]

        with PERSONAL_TRAIN.open("w", encoding="utf-8") as f:
            for row in train:
                f.write(json.dumps(row, ensure_ascii=False) + "\n")
        with PERSONAL_DEV.open("w", encoding="utf-8") as f:
            for row in dev:
                f.write(json.dumps(row, ensure_ascii=False) + "\n")

        return {
            "accepted": len(accepted),
            "rejected": len(rejected),
            "minutes": total_duration / 60.0,
            "train_manifest": str(PERSONAL_TRAIN),
            "dev_manifest": str(PERSONAL_DEV),
            "rejection_details": rejection_details,
        }
    except Exception as e:
        traceback.print_exc()
        return JSONResponse(status_code=500, content={"error": f"{type(e).__name__}: {e}"})

def _launch_training_script(script):
    global TRAIN_PROC, TRAIN_EXIT, TRAIN_LOG_HANDLE

    TRAIN_EXIT = None
    if TRAIN_LOG_HANDLE:
        try:
            TRAIN_LOG_HANDLE.close()
        except Exception:
            pass

    TRAIN_LOG_HANDLE = PERSONAL_LOG.open("w")
    env = os.environ.copy()
    env["PATH"] = "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:" + env.get("PATH", "")
    env["PYTORCH_ENABLE_MPS_FALLBACK"] = "1"

    TRAIN_PROC = subprocess.Popen(
        ["/bin/zsh", str(script)],
        stdout=TRAIN_LOG_HANDLE,
        stderr=subprocess.STDOUT,
        text=True,
        env=env,
    )
    return TRAIN_PROC

@app.post("/personal/train")
def personal_train():
    global TRAIN_PROC
    try:
        if TRAIN_PROC is not None and TRAIN_PROC.poll() is None:
            return {"running": True}

        script = PERSONAL_ROOT / "run-lora.command"
        if not script.exists():
            raise RuntimeError(
                "Personal Voice training environment is not installed. "
                "Run setup-personal-training.command from the 2.7 package."
            )
        if not PERSONAL_TRAIN.exists():
            raise RuntimeError("Prepare the dataset first.")

        proc = _launch_training_script(script)
        return {"running": True, "pid": proc.pid}
    except Exception as e:
        return JSONResponse(status_code=500, content={"error": f"{type(e).__name__}: {e}"})


PERSONAL_MERGED = PERSONAL_ROOT / "merged-model"

@app.post("/personal/merge")
def personal_merge():
    try:
        if not PERSONAL_OUT.exists():
            raise RuntimeError("No Personal Voice training output exists.")

        checkpoints = sorted(
            PERSONAL_OUT.glob("checkpoint-*"),
            key=lambda p: p.stat().st_mtime,
            reverse=True,
        )
        checkpoints = [p for p in checkpoints if (p / "adapter_config.json").exists()]
        if not checkpoints:
            raise RuntimeError("No completed LoRA checkpoint was found.")

        checkpoint = checkpoints[0]
        if PERSONAL_MERGED.exists():
            shutil.rmtree(PERSONAL_MERGED)

        cmd = [
            str(TRAIN_VENV / "bin" / "omnivoice-merge-lora"),
            "--base_model", "k2-fsa/OmniVoice",
            "--lora_adapter", str(checkpoint),
            "--output_dir", str(PERSONAL_MERGED),
        ]
        env = os.environ.copy()
        env["PATH"] = "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:" + env.get("PATH", "")
        proc = subprocess.run(cmd, capture_output=True, text=True, env=env, timeout=1800)
        if proc.returncode != 0:
            raise RuntimeError((proc.stderr or proc.stdout)[-5000:])

        return {
            "ok": True,
            "checkpoint": str(checkpoint),
            "merged_model": str(PERSONAL_MERGED),
        }
    except Exception as e:
        traceback.print_exc()
        return JSONResponse(status_code=500, content={"error": f"{type(e).__name__}: {e}"})

@app.post("/personal/save-engine")
def personal_save_engine(request: dict):
    try:
        import re as _re
        from datetime import datetime, timezone

        name = str(request.get("name", "")).strip()
        if not name:
            raise ValueError("Enter a name for the trained voice.")

        if not PERSONAL_OUT.exists():
            raise RuntimeError("No completed training output exists.")

        checkpoints = sorted(
            PERSONAL_OUT.glob("checkpoint-*"),
            key=lambda p: p.stat().st_mtime,
            reverse=True,
        )
        checkpoints = [p for p in checkpoints if (p / "adapter_config.json").exists()]
        if not checkpoints:
            raise RuntimeError("No completed LoRA checkpoint was found.")

        checkpoint = checkpoints[0]

        safe = _re.sub(r"[^A-Za-z0-9._-]+", "-", name).strip("-._") or "trained-voice"
        destination = TRAINED_ENGINES_DIR / safe

        # Keep names unique and deterministic.
        existing = _load_trained_engines()
        existing_same_name = next((x for x in existing if x.get("name") == name), None)
        if existing_same_name:
            destination = Path(existing_same_name["path"])

        if destination.exists():
            shutil.rmtree(destination)

        cmd = [
            str(TRAIN_VENV / "bin" / "omnivoice-merge-lora"),
            "--base_model", "k2-fsa/OmniVoice",
            "--lora_adapter", str(checkpoint),
            "--output_dir", str(destination),
        ]
        env = os.environ.copy()
        env["PATH"] = "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:" + env.get("PATH", "")
        proc = subprocess.run(cmd, capture_output=True, text=True, env=env, timeout=1800)
        if proc.returncode != 0:
            raise RuntimeError((proc.stderr or proc.stdout)[-5000:])

        entry = {
            "name": name,
            "path": str(destination),
            "checkpoint": str(checkpoint),
            "created_at": datetime.now(timezone.utc).isoformat(),
        }

        existing = [x for x in existing if x.get("name") != name]
        existing.append(entry)
        _save_trained_engines(existing)

        return {
            "ok": True,
            "name": name,
            "path": str(destination),
            "checkpoint": str(checkpoint),
        }

    except Exception as e:
        traceback.print_exc()
        return JSONResponse(
            status_code=500,
            content={"error": f"{type(e).__name__}: {e}"},
        )

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
            import torch
            from omnivoice import OmniVoice
            device = "mps" if torch.backends.mps.is_available() else "cpu"
            dtype = torch.float32
            personal_model = OmniVoice.from_pretrained(
                str(PERSONAL_MERGED),
                device_map=device,
                dtype=dtype,
            )
            result = personal_model.generate(
                text=text.strip(),
                ref_audio=ref_path,
                ref_text=(ref_text.strip() or None),
            )
            out = tempfile.NamedTemporaryFile(delete=False, suffix=".wav")
            out.close()
            _save_audio_result(result, out.name)
            return FileResponse(out.name, media_type="audio/wav", filename="personal-voice.wav")
        finally:
            try:
                os.unlink(ref_path)
            except Exception:
                pass
    except Exception as e:
        traceback.print_exc()
        return JSONResponse(status_code=500, content={"error": f"{type(e).__name__}: {e}"})

def _current_dataset_metrics():
    accepted = 0
    rejected = 0
    minutes = 0.0
    try:
        if PERSONAL_TRAIN.exists():
            lines = [x for x in PERSONAL_TRAIN.read_text(encoding="utf-8").splitlines() if x.strip()]
            accepted += len(lines)
            for line in lines:
                try:
                    item = json.loads(line)
                    audio_path = item.get("audio_path") or item.get("audio")
                    if audio_path and Path(audio_path).exists():
                        import soundfile as sf
                        info = sf.info(str(audio_path))
                        minutes += float(info.frames) / float(info.samplerate) / 60.0
                except Exception:
                    pass
        if PERSONAL_DEV.exists():
            lines = [x for x in PERSONAL_DEV.read_text(encoding="utf-8").splitlines() if x.strip()]
            accepted += len(lines)
            for line in lines:
                try:
                    item = json.loads(line)
                    audio_path = item.get("audio_path") or item.get("audio")
                    if audio_path and Path(audio_path).exists():
                        import soundfile as sf
                        info = sf.info(str(audio_path))
                        minutes += float(info.frames) / float(info.samplerate) / 60.0
                except Exception:
                    pass
    except Exception:
        pass
    return accepted, rejected, minutes

@app.get("/personal/training-status")
def personal_training_status():
    global TRAIN_EXIT, TRAIN_LOG_HANDLE

    running = TRAIN_PROC is not None and TRAIN_PROC.poll() is None

    if TRAIN_PROC is not None and not running and TRAIN_EXIT is None:
        TRAIN_EXIT = TRAIN_PROC.poll()
        if TRAIN_LOG_HANDLE:
            try:
                TRAIN_LOG_HANDLE.flush()
                TRAIN_LOG_HANDLE.close()
            except Exception:
                pass
            TRAIN_LOG_HANDLE = None

    tail = ""
    all_text = ""
    if PERSONAL_LOG.exists():
        try:
            all_text = PERSONAL_LOG.read_text(errors="replace")
            lines = all_text.splitlines()
            tail = "\n".join(lines[-80:])
        except Exception:
            pass

    phase = "Idle"
    if "=== Personal Voice: tokenization ===" in all_text:
        phase = "Preparing audio tokens"
    if "=== Personal Voice: LoRA training ===" in all_text:
        phase = "Loading training model"
    if "Starting Training Loop" in all_text:
        phase = "Optimizing personal voice"
    if TRAIN_EXIT == 0 and not running:
        phase = "Complete"
    elif TRAIN_EXIT not in (None, 0) and not running:
        phase = "Failed"

    step = 0
    total_steps = 1000

    # tqdm commonly emits "123/1000". Use the latest occurrence.
    import re
    matches = list(re.finditer(r"(\d+)\s*/\s*(\d+)", all_text))
    if matches:
        step = int(matches[-1].group(1))
        total_steps = int(matches[-1].group(2))

    adapter = ""
    if PERSONAL_OUT.exists():
        checkpoints = sorted(
            PERSONAL_OUT.glob("checkpoint-*"),
            key=lambda p: p.stat().st_mtime,
            reverse=True,
        )
        if checkpoints:
            adapter_files = [
                checkpoints[0] / "adapter_config.json",
                checkpoints[0] / "adapter_model.safetensors",
            ]
            if any(p.exists() for p in adapter_files):
                adapter = str(checkpoints[0])

    # Preserve a completed state across native-app/backend restarts.
    effective_exit = TRAIN_EXIT
    if not running and adapter and step >= total_steps:
        effective_exit = 0
        phase = "Complete"

    accepted, rejected, minutes = _current_dataset_metrics()
    return {
        "running": running,
        "exit_code": None if running else effective_exit,
        "tail": tail,
        "adapter_path": adapter,
        "phase": phase,
        "step": step,
        "total_steps": total_steps,
        "accepted": accepted,
        "rejected": rejected,
        "minutes": minutes,
    }


if __name__ == "__main__":
    uvicorn.run(app, host="127.0.0.1", port=8011, log_level="warning")