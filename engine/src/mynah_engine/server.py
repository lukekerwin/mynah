"""Local HTTP API used by the Mynah menu-bar app.

Binds to 127.0.0.1 only and requires the bearer token passed via
MYNAH_ENGINE_TOKEN, so web pages and other users can't drive it.

    POST /dictate  {"audio": <base64 int16 PCM, 16 kHz mono>, "context": {...}}
        -> {"raw", "text", "asr_ms", "llm_ms"}
    POST /command  {"audio": ..., "selection": "...", "context": {...}}
        -> {"instruction", "text", "asr_ms", "llm_ms"}
    POST /config   {"asr": key, "llm": key | null, "command_llm": key | null}
    GET  /health   -> {"ready", "loading", "error", "asr", "llm", "command_llm"}
    GET  /models   -> available models, which are downloaded, defaults

context = {"app": "Slack", "title": "<window title>", "vocab": [...],
           "snippets": [{"trigger", "text"}], "cleanup": true}
"""

import base64
import json
import logging
import os
import re
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import numpy as np

from .asr import SAMPLE_RATE, Asr
from . import downloads
from .cleanup import Llm
from .downloads import ensure_downloaded
from .models import ASR_MODELS, DEFAULT_ASR, DEFAULT_COMMAND_LLM, DEFAULT_LLM, LLM_MODELS
from .prompts import basic_cleanup, is_filler_only
from .vocab import apply_vocab

log = logging.getLogger("mynah_engine")

MIN_SPEECH_S = 0.25
SILENCE_RMS = 0.003


class Engine:
    """Owns the loaded models.

    MLX binds GPU streams to the thread that created them, so every model load
    and inference call runs on one dedicated worker thread (which also
    serializes requests).
    """

    def __init__(self):
        self.worker = ThreadPoolExecutor(max_workers=1, thread_name_prefix="mlx")
        self.asr: Asr | None = None
        self.llm: Llm | None = None
        self.command_llm: Llm | None = None
        self.loading = False
        self.error: str | None = None

    def run(self, fn, *args):
        return self.worker.submit(fn, *args).result()

    # -- model management -------------------------------------------------
    def configure(self, asr: str, llm: str | None, command_llm: str | None) -> None:
        """Validate, then (re)load models in the background."""
        for key, table, kind in ((asr, ASR_MODELS, "asr"), (llm, LLM_MODELS, "llm"),
                                 (command_llm, LLM_MODELS, "command_llm")):
            if key is not None and key not in table:
                raise ValueError(f"unknown {kind} model: {key}")
        self.loading, self.error = True, None
        self.worker.submit(self._load, asr, llm, command_llm)

    def _load(self, asr: str, llm: str | None, command_llm: str | None) -> None:
        try:
            # Fetch everything first so the app can show one download phase.
            ensure_downloaded(ASR_MODELS[asr].repo, "Speech model")
            if llm:
                ensure_downloaded(LLM_MODELS[llm].repo, "Cleanup model")
            if command_llm and command_llm != llm:
                ensure_downloaded(LLM_MODELS[command_llm].repo, "Command model")

            if not self.asr or self.asr.spec.key != asr:
                self.asr = None
                log.info("loading ASR %s", asr)
                self.asr = Asr(asr)
            if not llm:
                self.llm = None
            elif not self.llm or self.llm.spec.key != llm:
                self.llm = None
                log.info("loading LLM %s", llm)
                self.llm = Llm(llm)
            if not command_llm:
                self.command_llm = None
            elif command_llm == llm:
                self.command_llm = self.llm
            elif not self.command_llm or self.command_llm.spec.key != command_llm:
                self.command_llm = None
                log.info("loading command LLM %s", command_llm)
                self.command_llm = Llm(command_llm)
            import mlx.core as mx
            mx.clear_cache()
        except Exception as e:  # surfaced via /health
            log.exception("model load failed")
            self.error = repr(e)
        finally:
            self.loading = False
        log.info("models ready: %s", self.health())

    def health(self) -> dict:
        return {"ready": self.asr is not None and not self.loading, "loading": self.loading,
                "error": self.error, "download": downloads.current(),
                "asr": self.asr.spec.key if self.asr else None,
                "llm": self.llm.spec.key if self.llm else None,
                "command_llm": self.command_llm.spec.key if self.command_llm else None}

    # -- inference (always on the worker thread, via Engine.run) -------------
    def _transcribe(self, audio: np.ndarray, vocab: list[str]) -> tuple[str, float]:
        if not self.asr:
            raise RuntimeError("models not loaded yet")
        if len(audio) < MIN_SPEECH_S * SAMPLE_RATE or float(np.sqrt(np.mean(audio ** 2))) < SILENCE_RMS:
            return "", 0.0
        t0 = time.perf_counter()
        raw = self.asr.transcribe(audio, vocab)
        return raw, (time.perf_counter() - t0) * 1000

    def dictate(self, audio: np.ndarray, ctx: dict) -> dict:
        vocab = [v for v in ctx.get("vocab", []) if v.strip()]
        app = describe_app(ctx)
        raw, asr_ms = self._transcribe(audio, vocab)
        llm_ms = 0.0
        # Fix dictionary terms before the LLM sees them, so it doesn't "correct"
        # them into something else; apply again after, for anything it introduced.
        fixed = apply_vocab(raw, vocab)
        if not raw or is_filler_only(raw):
            text = ""
        elif ctx.get("cleanup", True) and self.llm:
            t0 = time.perf_counter()
            text = self.llm.clean(fixed, app, vocab)
            llm_ms = (time.perf_counter() - t0) * 1000
        else:
            text = basic_cleanup(fixed)
        text = apply_snippets(apply_vocab(text, vocab), ctx.get("snippets", []))
        log.info("dictate app=%s asr=%.0fms llm=%.0fms raw=%r -> %r", app, asr_ms, llm_ms, raw, text)
        return {"raw": raw, "text": text, "asr_ms": round(asr_ms), "llm_ms": round(llm_ms)}

    def command(self, audio: np.ndarray, selection: str, ctx: dict) -> dict:
        if not self.command_llm:
            raise RuntimeError("command mode needs a general-purpose LLM; pick one in Settings")
        vocab = [v for v in ctx.get("vocab", []) if v.strip()]
        app = describe_app(ctx)
        instruction, asr_ms = self._transcribe(audio, vocab)
        if not instruction:
            return {"instruction": "", "text": "", "asr_ms": round(asr_ms), "llm_ms": 0}
        t0 = time.perf_counter()
        text = self.command_llm.command(instruction, selection, app)
        llm_ms = (time.perf_counter() - t0) * 1000
        log.info("command app=%s instruction=%r -> %d chars", app, instruction, len(text))
        return {"instruction": instruction, "text": text, "asr_ms": round(asr_ms), "llm_ms": round(llm_ms)}


def describe_app(ctx: dict) -> str:
    app = ctx.get("app") or "Unknown"
    title = (ctx.get("title") or "").strip()
    return f"{app} — {title[:80]}" if title else app


def list_models(engine: Engine) -> dict:
    from pathlib import Path

    hub = Path(os.environ.get("HF_HUB_CACHE", Path.home() / ".cache/huggingface/hub"))

    def downloaded(repo: str) -> bool:
        snaps = hub / f"models--{repo.replace('/', '--')}" / "snapshots"
        return snaps.is_dir() and any(snaps.iterdir())

    return {
        "asr": [{"key": m.key, "params": m.params, "notes": m.notes, "downloaded": downloaded(m.repo),
                 "hotwords": m.hotwords} for m in ASR_MODELS.values() if not m.gated],
        "llm": [{"key": m.key, "params": m.params, "style": m.style, "downloaded": downloaded(m.repo),
                 "can_command": m.can_command} for m in LLM_MODELS.values()],
        "defaults": {"asr": DEFAULT_ASR, "llm": DEFAULT_LLM, "command_llm": DEFAULT_COMMAND_LLM},
        "current": engine.health(),
    }


def apply_snippets(text: str, snippets: list[dict]) -> str:
    """Replace spoken trigger phrases ("my calendar link") with their expansion."""
    for s in snippets:
        trigger, expansion = s.get("trigger", "").strip(), s.get("text", "")
        if not trigger:
            continue
        words = [re.escape(w) for w in re.findall(r"\w+", trigger)]
        pattern = r"\b" + r"[\s,.\-]*".join(words) + r"\b[.!?]?"
        text = re.sub(pattern, lambda _: expansion, text, flags=re.I)
    return text


def decode_audio(b64: str) -> np.ndarray:
    pcm = np.frombuffer(base64.b64decode(b64), dtype="<i2")
    return pcm.astype(np.float32) / 32768.0


def make_handler(engine: Engine, token: str):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, fmt, *args):  # route through logging, quietly
            log.debug(fmt, *args)

        def _send(self, status: int, body: dict) -> None:
            data = json.dumps(body).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def _authorized(self) -> bool:
            if self.headers.get("Authorization") == f"Bearer {token}":
                return True
            self._send(401, {"error": "unauthorized"})
            return False

        def do_GET(self):
            if not self._authorized():
                return
            if self.path == "/health":
                self._send(200, engine.health())
            elif self.path == "/models":
                self._send(200, list_models(engine))
            else:
                self._send(404, {"error": "not found"})

        def do_POST(self):
            if not self._authorized():
                return
            try:
                body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"{}")
                if self.path == "/dictate":
                    self._send(200, engine.run(engine.dictate, decode_audio(body["audio"]),
                                               body.get("context", {})))
                elif self.path == "/command":
                    self._send(200, engine.run(engine.command, decode_audio(body["audio"]),
                                               body.get("selection", ""), body.get("context", {})))
                elif self.path == "/config":
                    engine.configure(body["asr"], body.get("llm"), body.get("command_llm"))
                    self._send(202, {"ok": True})
                else:
                    self._send(404, {"error": "not found"})
            except Exception as e:
                log.exception("request failed")
                self._send(500, {"error": str(e)})

    return Handler


def watch_parent(pid: int) -> None:
    """Exit as soon as the app that launched us is gone (quit, crash or kill -9),
    so an orphaned engine never holds the port or GPU memory."""
    def loop():
        while True:
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                log.info("parent %d exited; shutting down", pid)
                os._exit(0)
            time.sleep(1)
    threading.Thread(target=loop, daemon=True, name="parent-watch").start()


def serve(port: int, asr: str, llm: str | None, command_llm: str | None, parent_pid: int | None = None) -> None:
    token = os.environ.get("MYNAH_ENGINE_TOKEN")
    if not token:
        raise SystemExit("MYNAH_ENGINE_TOKEN must be set")
    if parent_pid:
        watch_parent(parent_pid)
    engine = Engine()
    # Bind before loading models: if the port is taken, fail fast.
    try:
        server = ThreadingHTTPServer(("127.0.0.1", port), make_handler(engine, token))
    except OSError as e:
        log.error("can't listen on 127.0.0.1:%d: %s", port, e)
        os._exit(2)
    engine.configure(asr, llm, command_llm)
    log.info("mynah engine listening on 127.0.0.1:%d", port)
    server.serve_forever()
