"""Meeting transcription: voice-activity detection + timestamped ASR over a window.

The app sends each track's new audio every ~30 s. Speech that runs into the end
of a (non-final) window is held back: `consumed_s` tells the app where the next
window should start, so utterances are never cut mid-word.
"""

import time

import numpy as np

from .asr import SAMPLE_RATE
from .vocab import apply_vocab

VAD_REPO = "mlx-community/silero-vad"
MAX_REGION_S = 30.0  # longer speech regions are split at their quietest point
MERGE_GAP_S = 0.6  # regions closer than this are transcribed together
TAIL_GUARD_S = 0.4  # speech ending this close to the window end is held back
MIN_REGION_S = 0.3
SILENCE_RMS = 0.003

Region = tuple[float, float]


def plan_regions(speech: list[Region], window_s: float, final: bool) -> tuple[list[Region], float]:
    """Pure: turn VAD speech regions (seconds, sorted) into regions to transcribe.

    Returns (regions, consumed_s). Gaps under MERGE_GAP_S are merged. Unless
    `final`, a region touching the window end is held back and consumed_s is its
    start, so it's sent again (completed) with the next window."""
    merged: list[list[float]] = []
    for start, end in speech:
        start, end = max(0.0, start), min(window_s, end)
        if end <= start:
            continue
        if merged and start - merged[-1][1] < MERGE_GAP_S and end - merged[-1][0] <= MAX_REGION_S:
            merged[-1][1] = max(merged[-1][1], end)
        else:
            merged.append([start, end])

    consumed = window_s
    if not final and merged and window_s - merged[-1][1] < TAIL_GUARD_S:
        tail_start = merged.pop()[0]
        # A tail longer than a whole region can't wait forever: let its first part through.
        if window_s - tail_start > MAX_REGION_S:
            merged.append([tail_start, tail_start + MAX_REGION_S])
            consumed = tail_start + MAX_REGION_S
        else:
            consumed = tail_start
    regions = [(s, e) for s, e in merged if e - s >= MIN_REGION_S]
    return regions, consumed


def split_long(regions: list[Region], audio: np.ndarray) -> list[Region]:
    """Split regions longer than MAX_REGION_S at the quietest 100 ms frame."""
    out: list[Region] = []
    frame = int(0.1 * SAMPLE_RATE)
    pending = list(regions)
    while pending:
        start, end = pending.pop(0)
        if end - start <= MAX_REGION_S:
            out.append((start, end))
            continue
        # search the middle 50% of the first MAX_REGION_S for the quietest frame
        lo = int((start + MAX_REGION_S * 0.5) * SAMPLE_RATE)
        hi = int((start + MAX_REGION_S) * SAMPLE_RATE) - frame
        best, best_rms = hi, float("inf")
        for i in range(lo, max(lo + 1, hi), frame):
            rms = float(np.sqrt(np.mean(audio[i:i + frame] ** 2))) if i + frame <= len(audio) else 0.0
            if rms < best_rms:
                best, best_rms = i, rms
        cut = (best + frame // 2) / SAMPLE_RATE
        out.append((start, cut))
        pending.insert(0, (cut, end))
    return out


class MeetingTranscriber:
    """Owns the VAD model; uses the engine's loaded ASR. Runs on the MLX worker thread."""

    def __init__(self):
        self.vad = None

    def prepare(self) -> None:
        if self.vad is None:
            from mlx_audio.vad import load

            from .downloads import ensure_downloaded
            from .models import offline_if_cached

            ensure_downloaded(VAD_REPO, "Voice detector")
            with offline_if_cached(VAD_REPO):
                self.vad = load(VAD_REPO)

    def speech_regions(self, audio: np.ndarray) -> list[Region]:
        self.prepare()
        stamps = self.vad.get_speech_timestamps(audio, sample_rate=SAMPLE_RATE, min_silence_duration_ms=300,
                                                speech_pad_ms=100, return_seconds=True)
        return [(float(t["start"]), float(t["end"])) for t in stamps]

    def transcribe(self, asr, audio: np.ndarray, offset_s: float, vocab: list[str], final: bool) -> dict:
        t0 = time.perf_counter()
        window_s = len(audio) / SAMPLE_RATE
        if window_s == 0:
            return {"segments": [], "consumed_s": 0.0, "asr_ms": 0}
        regions, consumed = plan_regions(self.speech_regions(audio), window_s, final)
        segments = []
        for start, end in split_long(regions, audio):
            clip = audio[int(start * SAMPLE_RATE):int(end * SAMPLE_RATE)]
            if len(clip) < MIN_REGION_S * SAMPLE_RATE or float(np.sqrt(np.mean(clip ** 2))) < SILENCE_RMS:
                continue
            for s, e, text in asr.transcribe_aligned(clip, vocab):
                text = apply_vocab(text, vocab)
                if text:
                    segments.append({"start": round(offset_s + start + s, 2),
                                     "end": round(offset_s + start + min(e, end - start), 2), "text": text})
        return {"segments": segments, "consumed_s": round(consumed, 3),
                "asr_ms": round((time.perf_counter() - t0) * 1000)}
