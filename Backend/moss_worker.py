"""MOSS-TTSD worker for Cast's "Together" engine.

Runs in its own Python 3.13 / MLX environment (see setup-moss.command), never in
VoxAster's runtime. The model stays loaded; requests arrive one JSON object per
stdin line and each gets one JSON reply line on stdout. Closing stdin (the
backend exiting) ends the worker.
"""
import json
import sys
import time
import traceback
from pathlib import Path


def main():
    model_dir, codec_dir = sys.argv[1], sys.argv[2]
    protocol = sys.stdout
    sys.stdout = sys.stderr  # library prints must never corrupt the reply stream

    def reply(message):
        protocol.write(json.dumps(message) + "\n")
        protocol.flush()

    import mlx.core as mx
    from mlx_speech.audio import write_wav
    from mlx_speech.generation import MossTTSDelayGenerationConfig, synthesize_moss_tts_delay_conversations
    from mlx_speech.models.moss_audio_tokenizer import load_moss_audio_tokenizer_model
    from mlx_speech.models.moss_delay import (MossTTSDelayProcessor, build_ttsd_conversation,
                                              load_moss_tts_delay_model, resolve_ttsd_processor_mode)

    mx.set_default_device(mx.gpu)
    loaded = load_moss_tts_delay_model(model_dir)
    codec = load_moss_audio_tokenizer_model(codec_dir)
    processor = MossTTSDelayProcessor.from_path(loaded.model_dir, audio_tokenizer=codec.model)
    mode = resolve_ttsd_processor_mode("voice_clone")
    reply({"ready": True})

    for raw in sys.stdin:
        if not raw.strip():
            continue
        request = {}
        try:
            request = json.loads(raw)
            started = time.perf_counter()
            mx.random.seed(int(request.get("seed", 0)))
            conversation = list(build_ttsd_conversation(
                processor=processor, mode="voice_clone", text=request["text"],
                audio_map={int(k): v for k, v in request["prompts"].items()}, text_map={},
                text_normalize_enabled=False, sample_rate_normalize_enabled=False,
                n_vq=loaded.config.n_vq))
            config = MossTTSDelayGenerationConfig(
                use_kv_cache=True, max_new_tokens=int(request.get("max_new_tokens", 1200)),
                audio_temperature=1.1, audio_top_p=0.9, audio_top_k=50,
                audio_repetition_penalty=1.1, do_sample=True)
            result = synthesize_moss_tts_delay_conversations(
                loaded.model, processor, conversations=[conversation], mode=mode, config=config)
            output = result.outputs[0]
            samples = int(output.waveform.shape[0])
            if samples == 0:
                raise ValueError("MOSS-TTSD returned no audio.")
            write_wav(Path(request["output"]), output.waveform, sample_rate=output.sample_rate)
            reply({"id": request.get("id"), "ok": True, "sample_rate": int(output.sample_rate),
                   "duration": samples / output.sample_rate,
                   "stop_reached": bool(result.generation.stop_reached),
                   "elapsed": time.perf_counter() - started})
        except Exception as exc:  # report and keep serving
            traceback.print_exc()
            reply({"id": request.get("id"), "ok": False, "error": f"{type(exc).__name__}: {exc}"})


if __name__ == "__main__":
    main()
