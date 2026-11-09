#!/bin/bash
# Second bench pass: Parakeet (FluidAudio), whisper with VAD, and two concurrent SpeechAnalyzer streams.
# Usage: bench/run_bench2.sh   (on the MBP, after run_bench.sh)
set -uo pipefail
export PATH=/opt/homebrew/bin:$PATH
cd "$(dirname "$0")"
D=data
R=data/results
FA=${FLUIDAUDIO_CLI:-$HOME/code/vendor/FluidAudio/.build/release/fluidaudiocli}
SA=sa-bench/.build/release/sa-bench
VAD=models/ggml-silero-v5.1.2.bin
[ -f "$VAD" ] || curl -sSL -o "$VAD" https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v5.1.2.bin

for v in clean zoom; do
  /usr/bin/time -p whisper-cli -m models/ggml-large-v3-turbo-q5_0.bin --vad -vm "$VAD" -f "$D/sample_$v.wav" -l en -nt -np -otxt -of "$R/whispervad_$v" 2> "$R/whispervad_$v.time" > /dev/null
  for mv in v2 v3; do
    /usr/bin/time -p "$FA" transcribe "$D/sample_$v.wav" --model-version "$mv" --output-json "$R/parakeet_${mv}_$v.json" > "$R/parakeet_${mv}_$v.log" 2> "$R/parakeet_${mv}_$v.time"
    jq -r '.text // .transcription // empty' "$R/parakeet_${mv}_$v.json" > "$R/parakeet_${mv}_$v.txt"
  done
  /usr/bin/time -p "$FA" transcribe "$D/sample_$v.wav" --model-version v3 --streaming --output-json "$R/parakeetstream_v3_$v.json" > "$R/parakeetstream_v3_$v.log" 2> "$R/parakeetstream_v3_$v.time"
  jq -r '.text // .transcription // empty' "$R/parakeetstream_v3_$v.json" > "$R/parakeetstream_v3_$v.txt"
done

"$SA" stream "$D/sample_clean.wav" > "$R/sa_dual_a.json" &
"$SA" stream "$D/sample_zoom.wav" > "$R/sa_dual_b.json" &
wait
jq -r .text "$R/sa_dual_a.json" > "$R/sa_dual_a.txt"
jq -r .text "$R/sa_dual_b.json" > "$R/sa_dual_b.txt"

args=()
for f in "$R"/*.txt; do args+=("$(basename "$f" .txt)=$f"); done
uv run score.py "$D/reference.txt" "${args[@]}"
for f in "$R"/*.time; do echo "$(basename "$f" .time) $(grep real "$f")"; done
for f in "$R"/sa_*.json; do echo "$(basename "$f" .json) $(jq -c 'del(.text)' "$f")"; done
