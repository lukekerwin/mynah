"""Benchmark LLM cleanup models on cleanup_cases.CASES.

    uv run python bench_cleanup.py                 # all models
    uv run python bench_cleanup.py -m s1-mini -m qwen3-4b
    uv run python bench_cleanup.py --report-only

Each model runs in its own subprocess (`--worker`) for clean memory numbers.
"""

import argparse
import json
import statistics
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).parent
OUT_DIR = HERE / "results" / "cleanup"


from mynah_engine.models import LLM_MODELS as LLMS


def worker(key: str, out: Path) -> None:
    """Runs the engine's own cleanup path (prompt, prefix cache, sanitize, vocab)."""
    import mlx.core as mx

    from cleanup_cases import CASES
    from mynah_engine.cleanup import Llm
    from mynah_engine.vocab import apply_vocab

    spec = LLMS[key]
    llm = Llm(key)

    def run(case):
        vocab = list(case.vocab)
        t0 = time.perf_counter()
        text = apply_vocab(llm.clean(apply_vocab(case.raw, vocab), case.app, vocab), vocab)
        return {"output": text, "latency_s": time.perf_counter() - t0}

    run(CASES[0])  # warm-up
    results = []
    for case in CASES:
        r = run(case) | {"id": case.id}
        results.append(r)
        print(f"[{key}] {case.id}: {r['latency_s']:.2f}s  {r['output'][:70]!r}", flush=True)

    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps({"model": key, "repo": spec.repo, "params": spec.params,
                               "load_s": llm.load_s, "peak_mem_gb": mx.get_peak_memory() / 1e9,
                               "results": results}, indent=2))


def score(case, output: str) -> dict:
    import jiwer

    from bench_asr import normalize

    low = output.lower()
    # "a|b" in an include check means either spelling is acceptable
    checks = [any(alt.lower() in low for alt in s.split("|")) for s in case.include]
    checks += [s.lower() not in low for s in case.exclude]
    if case.id == "filler-only":
        checks.append(len(output.strip(" .")) == 0)
    exp, hyp = normalize(case.expected), normalize(output)
    wer = (0.0 if not hyp else 1.0) if not exp else jiwer.wer(exp, hyp or "<empty>")
    return {"checks_passed": sum(checks), "checks_total": len(checks),
            "all_checks": all(checks), "wer": wer}


def report(runs: list[dict]) -> str:
    from cleanup_cases import CASES

    cases = {c.id: c for c in CASES}
    lines = ["# Cleanup LLM benchmark", "",
             "| Model | Params | Cases fully passed | Check pass rate | WER vs expected | median latency | p90 latency | load | peak mem |",
             "|---|---|---|---|---|---|---|---|---|"]
    rows = []
    for run in runs:
        scored = [score(cases[r["id"]], r["output"]) | r for r in run["results"]]
        full = sum(s["all_checks"] for s in scored)
        cp = sum(s["checks_passed"] for s in scored) / max(1, sum(s["checks_total"] for s in scored))
        wer = statistics.mean(s["wer"] for s in scored)
        lats = sorted(s["latency_s"] for s in scored)
        p90 = lats[min(len(lats) - 1, int(round(0.9 * (len(lats) - 1))))]
        rows.append((-full, wer, f"| **{run['model']}** | {run['params']} | **{full}/{len(scored)}** | {cp * 100:.0f}% | {wer * 100:.1f}% "
                                 f"| {statistics.median(lats):.2f}s | {p90:.2f}s | {run['load_s']:.1f}s | {run['peak_mem_gb']:.1f} GB |"))
        run["_scored"] = {s["id"]: s for s in scored}
    lines += [r for *_, r in sorted(rows)]
    lines += ["", "*Cases fully passed* = every hard check for that case (e.g. self-correction applied, question not answered, vocab spelled right).", "",
              "## Per-case outputs", ""]
    for cid, case in cases.items():
        lines += [f"### {cid}  _(app: {case.app}{', vocab: ' + ', '.join(case.vocab) if case.vocab else ''})_",
                  f"- **raw**: {case.raw}", f"- **expected**: {json.dumps(case.expected)}"]
        for run in runs:
            s = run["_scored"].get(cid)
            if s:
                mark = "✅" if s["all_checks"] else "❌"
                lines.append(f"- {mark} {run['model']} ({s['latency_s']:.2f}s): {json.dumps(s['output'])}")
        lines.append("")
    return "\n".join(lines)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("-m", "--model", action="append", choices=LLMS)
    ap.add_argument("--worker", choices=LLMS)
    ap.add_argument("--out", type=Path)
    ap.add_argument("--report-only", action="store_true")
    args = ap.parse_args()

    if args.worker:
        worker(args.worker, args.out)
        return

    keys = args.model or list(LLMS)
    if not args.report_only:
        for key in keys:
            print(f"\n=== {key} ===", flush=True)
            rc = subprocess.run([sys.executable, __file__, "--worker", key, "--out", str(OUT_DIR / f"{key}.json")],
                                cwd=HERE).returncode
            if rc:
                print(f"!! {key} failed", flush=True)
    runs = [json.loads((OUT_DIR / f"{k}.json").read_text()) for k in keys if (OUT_DIR / f"{k}.json").exists()]
    md = report(runs)
    (OUT_DIR / "report.md").write_text(md)
    print("\n" + md.split("## Per-case")[0])
    print(f"Full report: {OUT_DIR / 'report.md'}")


if __name__ == "__main__":
    main()
