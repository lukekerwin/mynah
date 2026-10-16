"""Generate a smoke-test dataset with macOS `say` (optionally with added noise).

Synthetic speech is far cleaner than real dictation, so use this only to check
the pipeline works and get rough latency numbers -- not to pick a model.
"""

import json
import subprocess
from pathlib import Path

from prompts import READ

OUT = Path(__file__).parent / "data" / "synthetic"
VOICES = ["Samantha", "Daniel", "Karen", "Moira"]


def available_voices() -> set[str]:
    out = subprocess.run(["say", "-v", "?"], capture_output=True, text=True).stdout
    return {line.split()[0] for line in out.splitlines() if line.strip()}


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    voices = [v for v in VOICES if v in available_voices()] or ["Samantha"]
    manifest = []
    for i, (cid, cat, text) in enumerate(READ):
        voice = voices[i % len(voices)]
        aiff, wav = OUT / f"{cid}.aiff", OUT / f"{cid}.wav"
        subprocess.run(["say", "-v", voice, "-o", str(aiff), text], check=True)
        # Every other clip gets light pink noise to roughly mimic a laptop mic.
        effects = ["rate", "16k", "channels", "1"]
        if i % 2:
            noisy = OUT / f"{cid}.noise.wav"
            subprocess.run(["sox", str(aiff), "-r", "16k", "-c", "1", str(wav)], check=True)
            dur = subprocess.run(["soxi", "-D", str(wav)], capture_output=True, text=True).stdout.strip()
            subprocess.run(["sox", "-n", "-r", "16k", "-c", "1", str(noisy), "synth", dur, "pinknoise", "vol", "0.03"], check=True)
            subprocess.run(["sox", "-m", str(wav), str(noisy), str(wav) + ".tmp.wav"], check=True)
            Path(str(wav) + ".tmp.wav").replace(wav)
            noisy.unlink()
        else:
            subprocess.run(["sox", str(aiff), str(wav), *effects], check=True)
        aiff.unlink()
        manifest.append({"id": cid, "category": cat, "ref": text, "file": wav.name,
                         "voice": voice, "noisy": bool(i % 2)})
        print(f"{cid} ({voice}{', noisy' if i % 2 else ''})")
    (OUT / "manifest.json").write_text(json.dumps(manifest, indent=2))


if __name__ == "__main__":
    main()
