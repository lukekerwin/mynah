"""Record your own dictation clips for the benchmark (~10 minutes).

    cd bench && uv run python record.py

Controls: Enter starts recording, Enter stops. Then Enter=keep, r=redo,
p=play back, s=skip, q=save & quit. Re-running resumes where you left off.

Add your own jargon-heavy sentences (one per line) to data/mine/extra_prompts.txt
before running and they'll be included as read prompts.
"""

import json
import subprocess
import sys
import threading
from pathlib import Path

import numpy as np
import sounddevice as sd
import soundfile as sf

from prompts import FREE, READ

SR = 16_000
OUT = Path(__file__).parent / "data" / "mine"
MANIFEST = OUT / "manifest.json"
BOLD, DIM, RED, GREEN, RESET = "\033[1m", "\033[2m", "\033[31m", "\033[32m", "\033[0m"


def record_until_enter() -> np.ndarray:
    chunks: list[np.ndarray] = []
    stop = threading.Event()

    def cb(indata, frames, t, status):
        chunks.append(indata.copy())

    with sd.InputStream(samplerate=SR, channels=1, dtype="float32", callback=cb):
        print(f"  {RED}● recording…{RESET} press Enter to stop", flush=True)
        threading.Thread(target=lambda: (input(), stop.set()), daemon=True).start()
        stop.wait()
    audio = np.concatenate(chunks)[:, 0] if chunks else np.zeros(0, dtype="float32")
    return audio


MIC_BLOCKED_HELP = f"""{RED}The microphone is delivering pure silence.{RESET}
macOS does this when the app running this script isn't allowed to use the mic --
it never asks, it just records zeros. Fix:
  - Run this from Terminal.app or iTerm (not an editor's built-in terminal), and
    click Allow when macOS asks; or
  - System Settings > Privacy & Security > Microphone > enable your terminal app,
    then quit and reopen it."""


def is_silent(audio: np.ndarray) -> bool:
    return len(audio) == 0 or float(np.abs(audio).max()) < 1e-4


def mic_check() -> None:
    """Record half a second up front so a blocked mic is caught before you read 25 prompts."""
    audio = sd.rec(int(0.6 * SR), samplerate=SR, channels=1, dtype="float32")
    sd.wait()
    if is_silent(audio[:, 0]):
        print(MIC_BLOCKED_HELP)
        sys.exit(1)


def load_manifest() -> list[dict]:
    if not MANIFEST.exists():
        return []
    entries = json.loads(MANIFEST.read_text())
    # Clips that came out silent (blocked mic) count as not recorded.
    return [e for e in entries
            if (OUT / e["file"]).exists() and not is_silent(sf.read(OUT / e["file"], dtype="float32")[0])]


def save_manifest(entries: list[dict]) -> None:
    MANIFEST.write_text(json.dumps(entries, indent=2))


def all_prompts() -> list[dict]:
    prompts = [{"id": cid, "category": cat, "ref": text, "kind": "read"} for cid, cat, text in READ]
    extra = OUT / "extra_prompts.txt"
    if extra.exists():
        for i, line in enumerate(l.strip() for l in extra.read_text().splitlines()):
            if line:
                prompts.append({"id": f"custom-{i + 1}", "category": "custom", "ref": line, "kind": "read"})
    prompts += [{"id": cid, "category": "free", "ref": None, "instruction": instr,
                 "intent": intent, "kind": "free"} for cid, instr, intent in FREE]
    return prompts


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    print(f"Input device: {sd.query_devices(kind='input')['name']}")
    mic_check()
    print(f"{DIM}Tip: speak like you normally dictate, using the mic you'll actually use day to day.{RESET}")
    entries = {e["id"]: e for e in load_manifest()}
    prompts = all_prompts()
    todo = [p for p in prompts if p["id"] not in entries]
    print(f"{len(prompts) - len(todo)}/{len(prompts)} already recorded.\n")

    for n, p in enumerate(todo, 1):
        print(f"{BOLD}[{n}/{len(todo)}] {p['id']}{RESET}")
        if p["kind"] == "read":
            print(f"  Read this naturally (don't worry about small slips — redo if you botch it):\n\n    {p['ref']}\n")
        else:
            print(f"  {BOLD}Speak freely:{RESET} {p['instruction']}\n")
        while True:
            cmd = input("  Enter to start (s=skip, q=quit) ").strip().lower()
            if cmd == "q":
                save_manifest(list(entries.values()))
                print("Saved. Re-run to resume.")
                return
            if cmd == "s":
                break
            audio = record_until_enter()
            if is_silent(audio):
                print(MIC_BLOCKED_HELP)
                save_manifest(list(entries.values()))
                sys.exit(1)
            dur = len(audio) / SR
            peak = float(np.abs(audio).max())
            warn = f" {RED}(very quiet — check mic){RESET}" if peak < 0.02 else ""
            if p["kind"] == "read" and dur < 0.25 * len(p["ref"].split()):
                warn += f" {RED}(that's short for this sentence — did Enter get pressed twice? r to redo){RESET}"
            print(f"  {dur:.1f}s captured{warn}")
            path = OUT / f"{p['id']}.wav"
            sf.write(path, audio, SR)
            choice = input("  Enter=keep, r=redo, p=play ").strip().lower()
            while choice == "p":
                subprocess.run(["afplay", str(path)])
                choice = input("  Enter=keep, r=redo, p=play ").strip().lower()
            if choice == "r":
                continue
            entries[p["id"]] = {k: v for k, v in p.items() if k != "kind"} | {"file": path.name}
            save_manifest(list(entries.values()))
            print(f"  {GREEN}✓ saved{RESET}\n")
            break

    save_manifest(list(entries.values()))
    print(f"{GREEN}Done!{RESET} {len(entries)} clips in {OUT}")


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(130)
