"""Worker: transcribe every clip in a dataset with ONE model and write JSON.

Run in its own process per model so peak memory is measured cleanly and a
crashing model can't take down the whole benchmark.

    uv run python run_asr.py --model parakeet-v3 --data data/synthetic --out results/x.json
"""

import argparse
import json
import time
from pathlib import Path

import mlx.core as mx
import soundfile as sf

from mynah_engine.models import ASR_MODELS as MODELS
from mynah_engine.vocab import apply_vocab


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", required=True, choices=MODELS)
    ap.add_argument("--data", required=True, type=Path)
    ap.add_argument("--out", required=True, type=Path)
    ap.add_argument("--vocab", type=Path, help="dictionary file (one term per line), applied like the app does")
    args = ap.parse_args()
    vocab = [l.strip() for l in args.vocab.read_text().splitlines() if l.strip()] if args.vocab else []

    from mlx_audio.stt.utils import load_model

    spec = MODELS[args.model]
    manifest = json.loads((args.data / "manifest.json").read_text())
    clips = [c for c in manifest if (args.data / c["file"]).exists()]

    t0 = time.perf_counter()
    source = spec.repo
    if spec.subfolder:
        from huggingface_hub import snapshot_download
        source = str(Path(snapshot_download(spec.repo)) / spec.subfolder)
    model = load_model(source)
    load_s = time.perf_counter() - t0

    def transcribe(path: Path) -> str:
        kwargs = dict(spec.generate_kwargs)
        if vocab and spec.hotwords:
            kwargs["hotwords"] = vocab
        text = model.generate(str(path), **kwargs).text.strip()
        return apply_vocab(text, vocab) if vocab else text

    # Warm-up so Metal kernel compilation isn't billed to the first clip.
    t0 = time.perf_counter()
    transcribe(args.data / clips[0]["file"])
    warmup_s = time.perf_counter() - t0

    results = []
    for c in clips:
        path = args.data / c["file"]
        info = sf.info(str(path))
        t0 = time.perf_counter()
        try:
            text, err = transcribe(path), None
        except Exception as e:  # keep going; record the failure
            text, err = "", repr(e)[:500]
        results.append({
            **c,
            "hyp": text,
            "error": err,
            "latency_s": time.perf_counter() - t0,
            "audio_s": info.frames / info.samplerate,
        })
        print(f"[{args.model}] {c['id']}: {results[-1]['latency_s']:.2f}s  {text[:70]}", flush=True)

    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps({
        "model": args.model,
        "repo": spec.repo,
        "load_s": load_s,
        "warmup_s": warmup_s,
        "peak_mem_gb": mx.get_peak_memory() / 1e9,
        "results": results,
    }, indent=2))


if __name__ == "__main__":
    main()
