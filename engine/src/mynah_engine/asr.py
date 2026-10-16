"""Speech-to-text wrapper around mlx-audio."""

import time
from pathlib import Path

import mlx.core as mx
import numpy as np

from .models import ASR_MODELS, AsrModel, offline_if_cached

SAMPLE_RATE = 16_000


class Asr:
    def __init__(self, key: str):
        from mlx_audio.stt.utils import load_model

        self.spec: AsrModel = ASR_MODELS[key]
        source = self.spec.repo
        if self.spec.subfolder:
            from huggingface_hub import snapshot_download
            source = str(Path(snapshot_download(self.spec.repo)) / self.spec.subfolder)
        t0 = time.perf_counter()
        with offline_if_cached(self.spec.repo):
            self.model = load_model(source)
        # Warm up Metal kernels so the first real dictation isn't slow.
        self.transcribe(np.zeros(SAMPLE_RATE, dtype=np.float32))
        self.load_s = time.perf_counter() - t0

    def transcribe(self, audio: np.ndarray, vocab: list[str] | None = None) -> str:
        kwargs = dict(self.spec.generate_kwargs)
        if vocab and self.spec.hotwords:
            kwargs["hotwords"] = vocab
        out = self.model.generate(mx.array(audio, dtype=mx.float32), **kwargs)
        return out.text.strip()

    def transcribe_aligned(self, audio: np.ndarray, vocab: list[str] | None = None) -> list[tuple[float, float, str]]:
        """Like `transcribe`, but split into timed pieces: (start_s, end_s, text),
        relative to the start of `audio`. Parakeet gives sentences, Whisper-style
        models give segments; anything else comes back as one piece."""
        kwargs = dict(self.spec.generate_kwargs)
        if vocab and self.spec.hotwords:
            kwargs["hotwords"] = vocab
        out = self.model.generate(mx.array(audio, dtype=mx.float32), **kwargs)
        pieces: list[tuple[float, float, str]] = []
        for s in getattr(out, "sentences", None) or []:
            pieces.append((float(s.start), float(s.end), s.text.strip()))
        if not pieces:
            for s in getattr(out, "segments", None) or []:
                if isinstance(s, dict) and "start" in s and "end" in s:
                    pieces.append((float(s["start"]), float(s["end"]), str(s.get("text", "")).strip()))
        if not pieces:
            pieces.append((0.0, len(audio) / SAMPLE_RATE, out.text.strip()))
        return [p for p in pieces if p[2]]
