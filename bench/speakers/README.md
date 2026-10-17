# Speaker profiles POC

A go/no-go test for "Speaker 2 is Bob, and next meeting Mynah knows it's Bob". Nothing
here ships in the app.

Data: the [AMI Meeting Corpus](https://groups.inf.ed.ac.uk/ami/corpus/) (CC BY 4.0).
Each series (e.g. `ES2004`) is four meetings with the same four people, annotated with
who spoke when. Six series = 24 meetings, 24 people, about 12 hours of audio.

```sh
cd bench/speakers
./fetch_ami.sh                       # ~2 GB into bench/data/ami (git-ignored)
swift build -c release
.build/release/SpeakerProbe --out ../results/speakers ../data/ami/*.wav
uv run evaluate.py                   # or: uv run evaluate.py headset
```

`SpeakerProbe` runs FluidAudio's offline diarizer (pyannote community-1 segmentation,
WeSpeaker embeddings, VBx clustering, all on Core ML). For each speaker it finds, it saves
two voiceprints: the WeSpeaker centroid and a CAM++ embedding (a model built for
speaker verification).

`evaluate.py` reports:

1. **Diarization**: DER (0.25 s collar, overlapped speech not scored) and whether the
   number of speakers was right.
2. **Voiceprints**: cosine similarity for the same person across meetings vs different
   people, and the equal error rate.
3. **Profile replay**: meetings are played back in order (every series' meeting a, then
   every b, …). Each speaker found is matched against everyone named so far, then the
   "user" names it correctly, which adds that voiceprint to the person's profile. People
   from other series are always in the list, so strangers being given a name counts as
   an error. Speakers with under 5 s of speech are skipped.

Audio variants:

| variant | what | stands in for |
|---|---|---|
| `headset` | all headset mics mixed | a normal Teams call (each person on their own mic) |
| `teams` | `headset` through Opus at 16 kb/s | a poor connection |
| `array` | profiles learned on headsets (a, b), tested on a far-field room mic (c, d) | someone switching devices (harsher than reality) |

Caveat: in AMI everyone keeps the same headset in every meeting, so `headset` is the best
case for recognition. `array` is the pessimistic bound.
