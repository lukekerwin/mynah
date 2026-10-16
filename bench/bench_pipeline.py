"""End-to-end: run the engine's full dictation path (ASR -> dictionary -> LLM
cleanup -> dictionary) on recorded clips, for one or more ASR models.

    uv run python bench_pipeline.py --data data/mine --vocab data/mine/vocab.txt \
        -a parakeet-v3 -a qwen3-asr-1.7b
"""

import argparse
import gc
import json
import statistics
import time
from pathlib import Path

import soundfile as sf

from mynah_engine.asr import Asr
from mynah_engine.cleanup import Llm
from mynah_engine.models import DEFAULT_LLM
from mynah_engine.server import Engine

HERE = Path(__file__).parent
# Clips were read as generic text, so let the destination app follow the category.
APP_FOR = {"email": "Mail", "chat": "Slack", "tech": "Cursor", "free": "Notes"}


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--data", required=True, type=Path)
    ap.add_argument("--vocab", type=Path)
    ap.add_argument("-a", "--asr", action="append", required=True)
    ap.add_argument("--llm", default=DEFAULT_LLM)
    args = ap.parse_args()

    vocab = [l.strip() for l in args.vocab.read_text().splitlines() if l.strip()] if args.vocab else []
    manifest = json.loads((args.data / "manifest.json").read_text())
    engine = Engine()
    engine.llm = Llm(args.llm)

    runs = {}
    for key in args.asr:
        engine.asr = None
        gc.collect()
        engine.asr = Asr(key)
        rows = []
        for clip in manifest:
            audio, _ = sf.read(args.data / clip["file"], dtype="float32")
            ctx = {"app": APP_FOR.get(clip["category"], "Notes"), "vocab": vocab, "cleanup": True}
            t0 = time.perf_counter()
            out = engine.dictate(audio, ctx)
            rows.append(out | {"id": clip["id"], "ref": clip.get("ref"), "total_ms": (time.perf_counter() - t0) * 1000})
            print(f"[{key}] {clip['id']}: {rows[-1]['total_ms']:.0f}ms {out['text'][:70]!r}", flush=True)
        runs[key] = rows

    out_dir = HERE / "results" / f"{args.data.name}-pipeline"
    out_dir.mkdir(parents=True, exist_ok=True)
    (out_dir / "pipeline.json").write_text(json.dumps(runs, indent=2))

    lines = [f"# Full pipeline — `{args.data}` (cleanup: {args.llm})", ""]
    lines += ["| ASR | median total | p90 total | median ASR | median cleanup |", "|---|---|---|---|---|"]
    for key, rows in runs.items():
        tot = sorted(r["total_ms"] for r in rows)
        lines.append(f"| {key} | {statistics.median(tot):.0f} ms | {tot[int(0.9 * (len(tot) - 1))]:.0f} ms "
                     f"| {statistics.median(r['asr_ms'] for r in rows):.0f} ms "
                     f"| {statistics.median(r['llm_ms'] for r in rows):.0f} ms |")
    lines.append("")
    for i, clip in enumerate(manifest):
        lines.append(f"### {clip['id']}")
        if clip.get("ref"):
            lines.append(f"- **script**: {clip['ref']}")
        elif clip.get("instruction"):
            lines.append(f"- **prompt**: {clip['instruction']}")
        for key, rows in runs.items():
            r = rows[i]
            lines.append(f"- **{key}** raw: {r['raw']}")
            lines.append(f"  - **final** ({r['total_ms']:.0f} ms): {json.dumps(r['text'])}")
        lines.append("")
    (out_dir / "report.md").write_text("\n".join(lines))
    print("\n".join(lines[:2 + 2 + len(runs)]))
    print(f"Full report: {out_dir / 'report.md'}")


if __name__ == "__main__":
    main()
