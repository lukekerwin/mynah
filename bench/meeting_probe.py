"""Analyze a meeting probe recording (Phase 0 of docs/plans/meeting-capture.md).

Replays others.wav and you.wav through the same windowed VAD + ASR path the app
will use (30 s windows, held-back tails), prints the merged transcript, per-window
latency, and how many "You" lines the echo filter would hide.

    uv run python meeting_probe.py ~/Desktop/mynah-probe-2026-10-16T13-00-00Z
    uv run python meeting_probe.py <folder> --window 60 --asr parakeet-v3
"""

import argparse
import re
import statistics
import time
from pathlib import Path

import soundfile as sf

from mynah_engine.asr import SAMPLE_RATE, Asr
from mynah_engine.meeting import MeetingTranscriber

ECHO_MIN_WORDS, ECHO_RATIO, ECHO_SLACK = 3, 0.6, 1.5  # same as app EchoFilter


def words(text: str) -> list[str]:
    return [w for w in re.split(r"[^0-9a-z]+", text.lower()) if w]


def echo_flags(you: list[dict], others: list[dict]) -> list[bool]:
    flags = []
    for seg in you:
        mine = words(seg["text"])
        pool = set()
        for o in others:
            if o["end"] >= seg["start"] - ECHO_SLACK and o["start"] <= seg["end"] + ECHO_SLACK:
                pool.update(words(o["text"]))
        shared = sum(w in pool for w in mine)
        flags.append(len(mine) >= ECHO_MIN_WORDS and bool(pool) and shared / len(mine) >= ECHO_RATIO)
    return flags


def run_track(asr, tx, audio, window_s: float, vocab: list[str]) -> tuple[list[dict], list[float]]:
    segments, latencies, cursor = [], [], 0.0
    total = len(audio) / SAMPLE_RATE
    while cursor < total - 0.05:
        end = min(total, cursor + window_s)
        final = end >= total
        clip = audio[int(cursor * SAMPLE_RATE):int(end * SAMPLE_RATE)]
        t0 = time.perf_counter()
        out = tx.transcribe(asr, clip, cursor, vocab, final)
        latencies.append(time.perf_counter() - t0)
        segments += out["segments"]
        advance = out["consumed_s"]
        if advance <= 0.05 and not final:  # nothing consumed: take the whole window next time
            advance = end - cursor
        cursor += advance
    return segments, latencies


def stamp(s: float) -> str:
    s = int(s)
    return f"{s // 3600}:{s % 3600 // 60:02d}:{s % 60:02d}" if s >= 3600 else f"{s // 60:02d}:{s % 60:02d}"


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("folder", type=Path)
    ap.add_argument("--window", type=float, default=30.0)
    ap.add_argument("--asr", default="parakeet-v3")
    ap.add_argument("--vocab", type=Path, help="dictionary file, one term per line")
    args = ap.parse_args()
    vocab = [v.strip() for v in args.vocab.read_text().splitlines() if v.strip()] if args.vocab else []

    print(f"loading {args.asr} + VAD…")
    asr, tx = Asr(args.asr), MeetingTranscriber()
    tx.prepare()

    tracks = {}
    for name in ("others", "you"):
        path = args.folder / f"{name}.wav"
        if not path.exists():
            print(f"(no {path.name})")
            continue
        audio, sr = sf.read(path, dtype="float32")
        assert sr == SAMPLE_RATE, f"{path} is {sr} Hz"
        segs, lat = run_track(asr, tx, audio, args.window, vocab)
        dur = len(audio) / SAMPLE_RATE
        print(f"{name}: {dur:.0f} s audio, {len(segs)} segments, {len(lat)} windows, "
              f"latency median {statistics.median(lat):.2f} s / max {max(lat):.2f} s, "
              f"real-time factor {sum(lat) / dur:.3f}")
        tracks[name] = segs

    you, others = tracks.get("you", []), tracks.get("others", [])
    flags = echo_flags(you, others)
    print(f"\necho filter: {sum(flags)} of {len(you)} 'You' segments hidden\n")
    lines = [(s["start"], "Others", s["text"], False) for s in others]
    lines += [(s["start"], "You", s["text"], f) for s, f in zip(you, flags)]
    for start, who, text, hidden in sorted(lines):
        print(f"[{stamp(start)}] {who}{' (echo, hidden)' if hidden else ''}: {text}")


if __name__ == "__main__":
    main()
