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
