"""Run every ASR model over a dataset and produce a comparison report.

    uv run python bench_asr.py --data data/mine                # all models
    uv run python bench_asr.py --data data/mine -m parakeet-v3 -m qwen3-asr-1.7b
    uv run python bench_asr.py --data data/mine --report-only  # re-score cached runs
"""

import argparse
import json
import re
import statistics
import subprocess
import sys
import unicodedata
from collections import defaultdict
from pathlib import Path

import jiwer

from mynah_engine.models import ASR_MODELS as MODELS

HERE = Path(__file__).parent

# Spoken-form equivalences so "3:30 PM" vs "three thirty p.m." isn't counted as
# an ASR error -- formatting is the cleanup LLM's job, not the recognizer's.
_EQUIV = [
    (r"\bp\.?\s?m\.?\b", "pm"), (r"\ba\.?\s?m\.?\b", "am"),
    (r"\bokay\b", "ok"), (r"\bpercent\b", "%"),
]
_NUM_WORDS = {
    "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6,
    "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12,
    "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16,
    "seventeen": 17, "eighteen": 18, "nineteen": 19, "twenty": 20, "thirty": 30,
    "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
}
_ORDINALS = {"first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5,
             "twelfth": 12, "nineteenth": 19, "twentieth": 20, "thirtieth": 30}


def normalize(text: str) -> str:
    text = unicodedata.normalize("NFKC", text).lower()
    text = text.replace("’", "'")
    for pat, rep in _EQUIV:
        text = re.sub(pat, rep, text)
    text = re.sub(r"(\d),(\d)", r"\1\2", text)          # 1,000 -> 1000
    text = re.sub(r"(\d)\.(\d)", r"\1 point \2", text)   # 4.2 -> 4 point 2
    text = re.sub(r"(\d+)(st|nd|rd|th)\b", r"\1", text)   # 23rd -> 23
    text = re.sub(r"(\d):(\d\d)", r"\1 \2", text)         # 3:30 -> 3 30
    text = re.sub(r"[$%]", lambda m: " dollars " if m[0] == "$" else " percent ", text)
    text = re.sub(r"[-/]", " ", text)
    text = "".join(ch for ch in text if ch == "'" or not unicodedata.category(ch).startswith("P"))
    words = []
    for w in text.split():
        if w in _ORDINALS:
            w = str(_ORDINALS[w])
        elif w in _NUM_WORDS:
            w = str(_NUM_WORDS[w])
        words.append(w)
    # merge "20 3" -> "23" (twenty three) and "3 30" stays (times)
    merged: list[str] = []
    for w in words:
        if merged and w.isdigit() and merged[-1].isdigit() and int(merged[-1]) % 10 == 0 \
                and 20 <= int(merged[-1]) <= 90 and int(w) < 10:
            merged[-1] = str(int(merged[-1]) + int(w))
        else:
            merged.append(w)
    text = " ".join(merged)
    # "$4.2 million" and "four point two million dollars" -> same tokens
    num = r"(\d+(?: point \d+)?)"
    text = re.sub(rf"dollars {num} (million|billion|thousand)", r"\1 \2 dollars", text)
    text = re.sub(rf"dollars {num}", r"\1 dollars", text)
    return re.sub(r"\s+", " ", text).strip()


def run_model(key: str, data: Path, out: Path, vocab: Path | None) -> bool:
    cmd = [sys.executable, str(HERE / "run_asr.py"), "--model", key,
           "--data", str(data), "--out", str(out)]
    if vocab:
        cmd += ["--vocab", str(vocab)]
    print(f"\n=== {key} ===", flush=True)
    return subprocess.run(cmd, cwd=HERE).returncode == 0


def report(data: Path, runs: list[dict]) -> str:
    lines = [f"# ASR benchmark — `{data}`", ""]
    lines += ["| Model | WER (all) | " + " | ".join(_cats(runs)) +
              " | median latency | p90 latency | speed (x realtime) | load | peak mem |",
              "|---|---|" + "---|" * len(_cats(runs)) + "---|---|---|---|---|"]
    rows = []
    for run in runs:
        scored = [r for r in run["results"] if r.get("ref")]
        if not scored:
            continue
        refs = [normalize(r["ref"]) for r in scored]
        hyps = [normalize(r["hyp"]) for r in scored]
        wer_all = jiwer.wer(refs, hyps)
        by_cat = defaultdict(lambda: ([], []))
        for r, ref, hyp in zip(scored, refs, hyps):
            by_cat[r["category"]][0].append(ref)
            by_cat[r["category"]][1].append(hyp)
        cat_wers = [f"{jiwer.wer(*by_cat[c]) * 100:.1f}%" if c in by_cat else "–" for c in _cats(runs)]
        lats = sorted(r["latency_s"] for r in run["results"])
        p90 = lats[min(len(lats) - 1, int(round(0.9 * (len(lats) - 1))))]
        rtfx = sum(r["audio_s"] for r in run["results"]) / sum(lats)
        rows.append((wer_all, f"| **{run['model']}** | **{wer_all * 100:.1f}%** | " + " | ".join(cat_wers) +
                     f" | {statistics.median(lats):.2f}s | {p90:.2f}s | {rtfx:.0f}x"
                     f" | {run['load_s']:.1f}s | {run['peak_mem_gb']:.1f} GB |"))
    lines += [row for _, row in sorted(rows)]
    lines += ["", "WER is computed after normalizing case, punctuation and number formatting.", ""]

    # Per-clip diffs, so you can eyeball *what* each model gets wrong.
    lines += ["## Per-clip outputs", ""]
    by_id = defaultdict(dict)
    for run in runs:
        for r in run["results"]:
            by_id[r["id"]][run["model"]] = r
    for cid, per_model in by_id.items():
        first = next(iter(per_model.values()))
        lines += [f"### {cid}", f"- **reference**: {first.get('ref') or '_(free speech — no reference)_'}"]
        for model, r in per_model.items():
            mark = ""
            if r.get("ref"):
                w = jiwer.wer(normalize(r["ref"]), normalize(r["hyp"]) or "<empty>")
                mark = f" `{w * 100:.0f}%`"
            lines.append(f"- {model}{mark}: {r['hyp'] or '_(empty)_'}{' — ERROR ' + r['error'] if r.get('error') else ''}")
        lines.append("")
    return "\n".join(lines)


def _cats(runs: list[dict]) -> list[str]:
    seen: dict[str, None] = {}
    for run in runs:
        for r in run["results"]:
            if r.get("ref"):
                seen.setdefault(r["category"], None)
    return list(seen)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--data", required=True, type=Path)
    ap.add_argument("-m", "--model", action="append", choices=MODELS)
    ap.add_argument("--vocab", type=Path, help="dictionary file: hotwords + spelling fix, like the app")
    ap.add_argument("--report-only", action="store_true")
    args = ap.parse_args()

    keys = args.model or [k for k, m in MODELS.items() if not m.gated]
    out_dir = HERE / "results" / (args.data.name + ("-vocab" if args.vocab else ""))
    if not args.report_only:
        for key in keys:
            vocab = args.vocab.resolve() if args.vocab else None
            if not run_model(key, args.data.resolve(), out_dir / f"{key}.json", vocab):
                print(f"!! {key} failed", flush=True)

    runs = [json.loads((out_dir / f"{k}.json").read_text()) for k in keys if (out_dir / f"{k}.json").exists()]
    md = report(args.data, runs)
    (out_dir / "report.md").write_text(md)
    print("\n" + md.split("## Per-clip")[0])
    print(f"Full report: {out_dir / 'report.md'}")


if __name__ == "__main__":
    main()
