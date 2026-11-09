#!/bin/bash
# Run every engine on the sample and print a results table.
# Usage: bench/run_bench.sh   (on the MBP, from the repo root, after prepare_sample.py)
set -euo pipefail
export PATH=/opt/homebrew/bin:$PATH
cd "$(dirname "$0")"
D=data
R=data/results
mkdir -p "$R"
SA=sa-bench/.build/release/sa-bench
FA=${FLUIDAUDIO_CLI:-$HOME/code/vendor/FluidAudio/.build/release/fluidaudiocli}
WM=models/ggml-large-v3-turbo-q5_0.bin

for v in clean zoom; do
  "$SA" file "$D/sample_$v.wav" > "$R/sa_file_$v.json"
  jq -r .text "$R/sa_file_$v.json" > "$R/sa_file_$v.txt"
  "$SA" stream "$D/sample_$v.wav" > "$R/sa_stream_$v.json"
  jq -r .text "$R/sa_stream_$v.json" > "$R/sa_stream_$v.txt"

  /usr/bin/time -p whisper-cli -m "$WM" -f "$D/sample_$v.wav" -l en -nt -np -otxt -of "$R/whisper_$v" 2> "$R/whisper_$v.time" > /dev/null

  if [ -x "$FA" ]; then
    for mv in v2 v3; do
      /usr/bin/time -p "$FA" transcribe "$D/sample_$v.wav" --model-version "$mv" --output-json "$R/parakeet_${mv}_$v.json" > "$R/parakeet_${mv}_$v.log" 2> "$R/parakeet_${mv}_$v.time" || true
      jq -r '.text // .transcription // empty' "$R/parakeet_${mv}_$v.json" > "$R/parakeet_${mv}_$v.txt" 2>/dev/null || true
    done
  fi
done

args=()
for f in "$R"/*.txt; do args+=("$(basename "$f" .txt)=$f"); done
uv run score.py "$D/reference.txt" "${args[@]}"
