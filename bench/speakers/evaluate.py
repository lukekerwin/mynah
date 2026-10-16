# /// script
# requires-python = ">=3.12"
# dependencies = ["numpy", "scipy"]
# ///
"""Scores speaker-probe output against AMI annotations. Run with `uv run evaluate.py`.

Part 1, diarization: within one meeting, are the voices split into the right speakers?
Part 2, profiles: replays meetings in order the way Mynah would use them. Each speaker
found is matched against the people named so far ("Bob", or "Speaker N" if nothing is
close enough). Then the "user" names every speaker correctly, which saves that voiceprint
to the person's profile. People from other AMI series are on the list too, so a stranger
being called Bob shows up as an error.
"""

import argparse
import json
from collections import defaultdict
from pathlib import Path

import numpy as np
from scipy.optimize import linear_sum_assignment

HERE = Path(__file__).resolve().parent
DATA = HERE.parent / "data" / "ami"
RESULTS = HERE.parent / "results" / "speakers"

FRAME = 0.01
COLLAR = 0.25
MIN_SPEAKER_S = 5.0  # speakers with less speech than this aren't named or saved to a profile
THRESHOLDS = [0.3, 0.35, 0.4, 0.45, 0.5, 0.55, 0.6, 0.65, 0.7, 0.75, 0.8]


def load_rttm(path: Path) -> list[tuple[float, float, str]]:
    turns = []
    for line in path.read_text().splitlines():
        f = line.split()
        if f and f[0] == "SPEAKER":
            turns.append((float(f[3]), float(f[3]) + float(f[4]), f[7]))
    return turns


def frames(turns, n: int) -> dict[str, np.ndarray]:
    out: dict[str, np.ndarray] = defaultdict(lambda: np.zeros(n, bool))
    for s, e, spk in turns:
        out[spk][int(s / FRAME):int(e / FRAME)] = True
    return dict(out)


def diarization(ref_turns, hyp_turns) -> dict:
    """DER with a 0.25 s collar, overlapped speech not scored (FluidAudio's convention).

    Also returns, for each hypothesis speaker, the reference person it mostly covers
    (or None if under half of it is one person): who the user would say it is."""
    n = int(max(e for _, e, _ in ref_turns + hyp_turns) / FRAME) + 1
    ref, hyp = frames(ref_turns, n), frames(hyp_turns, n)
    ref_ids, hyp_ids = sorted(ref), sorted(hyp)
    R = np.stack([ref[k] for k in ref_ids]) if ref_ids else np.zeros((0, n), bool)
    H = np.stack([hyp[k] for k in hyp_ids]) if hyp_ids else np.zeros((0, n), bool)

    scored = R.sum(0) <= 1
    for s, e, _ in ref_turns:
        for edge in (s, e):
            scored[max(0, int((edge - COLLAR) / FRAME)):int((edge + COLLAR) / FRAME)] = False
    R, H = R[:, scored], H[:, scored]

    overlap = R.astype(np.int32) @ H.T.astype(np.int32)  # ref x hyp frames in common
    rows, cols = linear_sum_assignment(-overlap)
    ref_speech = R.any(0)
    hyp_speech = H.any(0)
    miss = int((ref_speech & ~hyp_speech).sum())
    fa = int((~ref_speech & hyp_speech).sum())
    matched = int(overlap[rows, cols].sum())
    both = int((ref_speech & hyp_speech).sum())
    total = max(1, int(ref_speech.sum()))

    owner = {}
    for j, h in enumerate(hyp_ids):
        col = overlap[:, j]
        owner[h] = ref_ids[int(col.argmax())] if col.sum() and col.max() / max(1, H[j].sum()) >= 0.5 else None
    return {"der": (miss + fa + both - matched) / total, "miss": miss / total, "fa": fa / total,
            "confusion": (both - matched) / total, "ref_speakers": len(ref_ids), "owner": owner}


def series_order(meetings: list[str]) -> list[str]:
    """All a-sessions, then all b-sessions, …: the people list fills up across series."""
    return sorted(meetings, key=lambda m: (m[-1], m[:-1]))


def replay(probes: dict[str, dict], owners: dict[str, dict], kind: str, threshold: float) -> dict:
    gallery: dict[str, list[np.ndarray]] = defaultdict(list)
    c = defaultdict(float)
    by_session = defaultdict(lambda: defaultdict(float))
    for m in series_order(list(probes)):
        session = m[-1]
        for spk, info in probes[m]["speakers"].items():
            if info["speechS"] < MIN_SPEAKER_S or not info.get(kind):
                continue
            truth = owners[m].get(spk)
            v = np.asarray(info[kind])
            scores = {p: max(float(v @ e) for e in es) for p, es in gallery.items()}
            best = max(scores, key=scores.get) if scores else None
            guess = best if best is not None and scores[best] >= threshold else None
            known = truth in gallery
            if truth is None:
                outcome = "junk_named" if guess else "junk_unknown"
            elif known:
                outcome = "right" if guess == truth else ("wrong" if guess else "missed")
            else:
                outcome = "stranger_named" if guess else "stranger_ok"
            c[outcome] += 1
            c[outcome + "_s"] += info["speechS"]
            by_session[session][outcome] += 1
            if truth is not None:
                gallery[truth].append(v)
    return {"counts": dict(c), "by_session": {k: dict(v) for k, v in by_session.items()}}


def pair_scores(probes, owners, kind):
    """Cosine between every pair of (meeting, speaker) voiceprints from different meetings."""
    items = []
    for m, p in probes.items():
        for spk, info in p["speakers"].items():
            t = owners[m].get(spk)
            if t and info["speechS"] >= MIN_SPEAKER_S and info.get(kind):
                items.append((m, t, np.asarray(info[kind])))
    same, diff = [], []
    for i in range(len(items)):
        for j in range(i + 1, len(items)):
            if items[i][0] == items[j][0]:
                continue
            (same if items[i][1] == items[j][1] else diff).append(float(items[i][2] @ items[j][2]))
    return np.array(same), np.array(diff)


def eer(same, diff) -> tuple[float, float]:
    """Equal error rate and its threshold: where missed matches ≈ false matches."""
    best = (1.0, 0.0)
    for t in np.linspace(-0.2, 1, 601):
        err = max((same < t).mean(), (diff >= t).mean())
        if err < best[0]:
            best = (float(err), float(t))
    return best


def load_variant(variant: str, meetings: list[str]) -> dict[str, dict]:
    """`array` = headset for sessions a/b (enrolment), room mic for c/d (testing)."""
    out = {}
    for m in meetings:
        v = variant
        if variant == "array":
            v = "array" if m[-1] in "cd" else "headset"
        path = RESULTS / f"{m}.{v}.json"
        if path.exists():
            out[m] = json.loads(path.read_text())
    return out


def report(variant: str) -> dict:
    meetings = sorted(p.stem for p in DATA.glob("*.rttm"))
    probes = load_variant(variant, meetings)
    if not probes:
        print(f"\n== {variant}: no probe results in {RESULTS}")
        return {}
    print(f"\n==================== {variant} ({len(probes)} meetings) ====================")
    owners, rows = {}, []
    audio_s = diar_s = 0.0
    print(f"{'meeting':10} {'DER':>6} {'miss':>6} {'FA':>6} {'conf':>6}  speakers(found/true)  speed")
    for m in series_order(list(probes)):
        p = probes[m]
        ref = load_rttm(DATA / f"{m}.rttm")
        hyp = [(s["start"], s["end"], s["speaker"]) for s in p["segments"]]
        d = diarization(ref, hyp)
        owners[m] = d["owner"]
        found = sum(1 for s in p["speakers"].values() if s["speechS"] >= MIN_SPEAKER_S)
        audio_s += p["durationS"]
        diar_s += p["diarizeS"] + p["embedS"]
        rows.append(d)
        print(f"{m:10} {d['der']:6.1%} {d['miss']:6.1%} {d['fa']:6.1%} {d['confusion']:6.1%}  "
              f"{found:>2}/{d['ref_speakers']:<2}  {p['durationS'] / max(p['diarizeS'], 1e-6):6.0f}x")
    print(f"{'average':10} {np.mean([r['der'] for r in rows]):6.1%} {np.mean([r['miss'] for r in rows]):6.1%} "
          f"{np.mean([r['fa'] for r in rows]):6.1%} {np.mean([r['confusion'] for r in rows]):6.1%}  "
          f"{sum(1 for r, m in zip(rows, series_order(list(probes))) if sum(1 for s in probes[m]['speakers'].values() if s['speechS'] >= MIN_SPEAKER_S) == r['ref_speakers'])}/{len(rows)} right count  "
          f"{audio_s / 3600:.1f} h audio in {diar_s:.0f} s total")

    summary = {"variant": variant, "meetings": len(probes), "der": float(np.mean([r["der"] for r in rows])), "kinds": {}}
    for kind in ("wespeaker", "campp"):
        same, diff = pair_scores(probes, owners, kind)
        if not len(same):
            continue
        err, t_eer = eer(same, diff)
        print(f"\n-- voiceprint: {kind}   same person across meetings: cos {np.median(same):.2f} median "
              f"(5th pct {np.percentile(same, 5):.2f}); different people: {np.median(diff):.2f} median "
              f"(95th pct {np.percentile(diff, 95):.2f}, max {diff.max():.2f}); EER {err:.1%} at {t_eer:.2f}")
        print(f"   {'thresh':>6}  {'named right':>11} {'named WRONG':>11} {'not named':>9} "
              f"{'stranger→unknown':>16} {'stranger→named':>14} {'junk named':>10}")
        best = None
        for t in THRESHOLDS:
            c = replay(probes, owners, kind, t)["counts"]
            known = c.get("right", 0) + c.get("wrong", 0) + c.get("missed", 0)
            strangers = c.get("stranger_ok", 0) + c.get("stranger_named", 0)
            line = (f"   {t:6.2f}  {c.get('right', 0) / max(1, known):11.0%} {c.get('wrong', 0) / max(1, known):11.0%} "
                    f"{c.get('missed', 0) / max(1, known):9.0%} {c.get('stranger_ok', 0) / max(1, strangers):16.0%} "
                    f"{c.get('stranger_named', 0) / max(1, strangers):14.0%} {int(c.get('junk_named', 0)):10d}")
            print(line)
            errors = c.get("wrong", 0) + c.get("stranger_named", 0) + c.get("junk_named", 0)
            score = c.get("right", 0) - 3 * errors  # a wrong name is worse than "Speaker 2"
            if best is None or score > best[0]:
                best = (score, t, c)
        _, t, c = best
        known = c.get("right", 0) + c.get("wrong", 0) + c.get("missed", 0)
        bs = replay(probes, owners, kind, t)["by_session"]
        per = "  ".join(f"{s}: {bs[s].get('right', 0) / max(1, sum(bs[s].get(k, 0) for k in ('right', 'wrong', 'missed'))):.0%}"
                        for s in sorted(bs) if s != "a")
        print(f"   best (wrong name counts 3x): {t:.2f} → {c.get('right', 0) / max(1, known):.0%} of returning "
              f"speakers named right; by meeting #  {per}")
        summary["kinds"][kind] = {"eer": err, "eer_threshold": t_eer, "best_threshold": t,
                                  "right": c.get("right", 0) / max(1, known), "counts": c}
    return summary


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("variants", nargs="*", default=["headset", "teams", "array"])
    args = ap.parse_args()
    out = [report(v) for v in args.variants]
    RESULTS.mkdir(parents=True, exist_ok=True)
    (RESULTS / "summary.json").write_text(json.dumps(out, indent=2, default=float))


if __name__ == "__main__":
    main()
