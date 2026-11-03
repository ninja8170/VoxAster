"""Cast's "Together" engine: MOSS-TTSD in a separate worker process.

MOSS-TTSD needs Python 3.13 and MLX, so it never loads into VoxAster's runtime.
setup-moss.command installs it under <data root>/engines/moss; this module starts
the worker on first use, keeps it loaded, and restarts it after a crash or timeout.
"""
import json
import os
import queue
import subprocess
import sys
import threading
import uuid
from pathlib import Path

HERE = Path(__file__).resolve().parent
MANIFEST = json.loads((HERE / "moss.json").read_text())
LOAD_TIMEOUT = 600
RENDER_TIMEOUT = 900


class MossUnavailable(RuntimeError):
    pass


class MossEngine:
    def __init__(self, data_root):
        self.home = Path(os.environ.get("OMNIVOICE_MOSS_HOME", str(Path(data_root) / "engines" / "moss")))
        self.process = None
        self.replies = queue.Queue()
        self.lock = threading.Lock()
        self.worker = HERE / "moss_worker.py"

    @property
    def python(self):
        return self.home / "venv" / "bin" / "python"

    @property
    def model_dir(self):
        return self.home / "models" / "ttsd" / MANIFEST["variant"]

    @property
    def codec_dir(self):
        return self.home / "models" / "codec" / MANIFEST["variant"]

    def status(self):
        missing = [label for label, path in (("Python 3.13 environment", self.python),
                                             ("MOSS-TTSD model", self.model_dir / "model.safetensors"),
                                             ("audio codec", self.codec_dir)) if not path.exists()]
        if missing:
            return dict(available=False, engine=MANIFEST["engine"],
                        reason=f"Not installed ({', '.join(missing)} missing). Run setup-moss.command in the VoxAster folder.")
        return dict(available=True, engine=MANIFEST["engine"], loaded=self.running(), reason="")

    def running(self):
        return self.process is not None and self.process.poll() is None

    def _reader(self, stream, sink):
        for line in stream:
            line = line.strip()
            if line:
                try:
                    sink.put(json.loads(line))
                except ValueError:
                    pass
        sink.put(None)  # worker exited

    def _start(self):
        status = self.status()
        if not status["available"]:
            raise MossUnavailable(status["reason"])
        self.home.mkdir(parents=True, exist_ok=True)
        log = open(self.home / "worker.log", "ab")
        self.replies = queue.Queue()
        self.process = subprocess.Popen(
            [str(self.python), "-I", str(self.worker), str(self.model_dir), str(self.codec_dir)],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=log, text=True, bufsize=1,
            env={**os.environ, "HF_HUB_OFFLINE": "1"})
        log.close()
        threading.Thread(target=self._reader, args=(self.process.stdout, self.replies), daemon=True).start()
        ready = self._next(LOAD_TIMEOUT, "loading MOSS-TTSD")
        if not ready.get("ready"):
            self.stop()
            raise RuntimeError("MOSS-TTSD worker did not start.")

    def _next(self, timeout, what):
        try:
            message = self.replies.get(timeout=timeout)
        except queue.Empty:
            self.stop()
            raise TimeoutError(f"MOSS-TTSD stopped responding while {what}; it will restart on the next render.")
        if message is None:
            self.stop()
            raise RuntimeError(f"MOSS-TTSD exited while {what}. See {self.home / 'worker.log'}.")
        return message

    def render(self, text, prompts, output, seed=0, max_new_tokens=1200):
        """prompts: {speaker number: reference wav path}. Writes `output`; returns the worker's reply."""
        return self._ask(dict(text=text, prompts={str(k): str(v) for k, v in prompts.items()},
                              output=str(output), seed=int(seed), max_new_tokens=int(max_new_tokens)))

    def _ask(self, request):
        with self.lock:
            if not self.running():
                self._start()
            request_id = uuid.uuid4().hex
            self.process.stdin.write(json.dumps(dict(request, id=request_id)) + "\n")
            self.process.stdin.flush()
            reply = self._next(RENDER_TIMEOUT, "rendering")
            if reply.get("id") != request_id:
                self.stop()
                raise RuntimeError("MOSS-TTSD replied out of order; it will restart on the next render.")
            if not reply.get("ok"):
                raise RuntimeError(reply.get("error") or "MOSS-TTSD failed.")
            return reply

    def stop(self):
        process, self.process = self.process, None
        if process is None:
            return
        try:
            process.stdin.close()  # end of input is the worker's signal to exit
            process.wait(timeout=5)
        except Exception:
            process.kill()
            process.wait()
        try:
            process.stdout.close()
        except Exception:
            pass
