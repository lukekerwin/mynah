#!/usr/bin/env bash
# Downloads AMI meetings (CC BY 4.0) + speaker annotations into bench/data/ami.
# Each series (e.g. ES2004) is 4 meetings (a–d) with the same 4 people, which is
# what lets us test "learn a voice in one meeting, recognise it in the next".
#
# Per meeting it writes:
#   <m>.headset.wav  all headset mics mixed: close to what a Teams call sounds like
#   <m>.teams.wav    the same, squeezed through Opus at 16 kb/s (a bad Teams line)
#   <m>.array.wav    one far-field room mic, sessions c and d only (a "different mic" stress test)
#   <m>.rttm         who spoke when (pyannote's word-aligned AMI annotations)
set -euo pipefail

cd "$(dirname "$0")/.."
mkdir -p data/ami && cd data/ami

SERIES=${*:-"ES2004 IS1009 TS3003 ES2011 IS1008 TS3004"}
AMI=https://groups.inf.ed.ac.uk/ami/AMICorpusMirror/amicorpus
RTTM=https://raw.githubusercontent.com/pyannote/AMI-diarization-setup/main/only_words/rttms

for series in $SERIES; do
  for s in a b c d; do
    m=$series$s
    if [[ ! -f $m.rttm ]]; then
      curl -fsSL "$RTTM/test/$m.rttm" -o $m.rttm 2>/dev/null || curl -fsSL "$RTTM/dev/$m.rttm" -o $m.rttm \
        || curl -fsSL "$RTTM/train/$m.rttm" -o $m.rttm
    fi
    if [[ ! -f $m.headset.wav ]]; then
      echo "downloading $m"
      curl -fsSL "$AMI/$m/audio/$m.Mix-Headset.wav" -o $m.headset.tmp.wav
      ffmpeg -loglevel error -y -i $m.headset.tmp.wav -ac 1 -ar 16000 $m.headset.wav
      rm $m.headset.tmp.wav
    fi
    if [[ ! -f $m.teams.wav ]]; then
      ffmpeg -loglevel error -y -i $m.headset.wav -c:a libopus -b:a 16k -application voip $m.teams.tmp.ogg
      ffmpeg -loglevel error -y -i $m.teams.tmp.ogg -ac 1 -ar 16000 $m.teams.wav
      rm $m.teams.tmp.ogg
    fi
    if [[ ($s == c || $s == d) && ! -f $m.array.wav ]]; then
      curl -fsSL "$AMI/$m/audio/$m.Array1-01.wav" -o $m.array.tmp.wav
      ffmpeg -loglevel error -y -i $m.array.tmp.wav -ac 1 -ar 16000 $m.array.wav
      rm $m.array.tmp.wav
    fi
  done
done
echo "done: $(ls *.headset.wav | wc -l | tr -d ' ') meetings in $(pwd)"
