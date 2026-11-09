#!/bin/bash
# Build a conversational business-call sample with names, amounts, dates and commitments.
# Two macOS voices; "them" lines and "me" lines also go to separate files for the dual-channel bench.
# Usage: bench/make_conversation.sh OUTDIR
set -euo pipefail
export PATH=/opt/homebrew/bin:$PATH
OUT=${1:-data/conv}
mkdir -p "$OUT/parts"
SCRIPT=$(dirname "$0")/conversation.txt
: > "$OUT/reference.txt"; : > "$OUT/reference_me.txt"; : > "$OUT/reference_them.txt"
i=0
them_list=(); me_list=(); all_list=()
while IFS='|' read -r who line; do
  [ -z "$who" ] && continue
  i=$((i+1))
  f="$OUT/parts/$(printf %03d $i)_$who.wav"
  voice=Samantha; [ "$who" = me ] && voice=Daniel
  say -v "$voice" -o "$f" --data-format=LEI16@16000 "$line"
  sil="$OUT/parts/$(printf %03d $i)_sil.wav"
  ffmpeg -loglevel error -y -f lavfi -i anullsrc=r=16000:cl=mono -t 0.7 -c:a pcm_s16le "$sil"
  all_list+=("$f" "$sil")
  echo "$line" >> "$OUT/reference.txt"
  if [ "$who" = me ]; then echo "$line" >> "$OUT/reference_me.txt"; else echo "$line" >> "$OUT/reference_them.txt"; fi
done < "$SCRIPT"

concat() { local out=$1; shift; local lst="$OUT/parts/list_$(basename "$out").txt"; : > "$lst"; for p in "$@"; do echo "file '$PWD/$p'" >> "$lst"; done; ffmpeg -loglevel error -y -f concat -safe 0 -i "$lst" -c:a pcm_s16le -ar 16000 -ac 1 "$out"; }
concat "$OUT/conv_mix.wav" "${all_list[@]}"

# Per-channel tracks keep the timeline: the other side's turns become silence of equal length.
me_track=(); them_track=()
for f in "${all_list[@]}"; do
  case "$f" in
    *_sil.wav) me_track+=("$f"); them_track+=("$f");;
    *_me.wav)  me_track+=("$f"); s="${f%.wav}_mute.wav"; ffmpeg -loglevel error -y -i "$f" -af volume=0 -c:a pcm_s16le "$s"; them_track+=("$s");;
    *_them.wav) them_track+=("$f"); s="${f%.wav}_mute.wav"; ffmpeg -loglevel error -y -i "$f" -af volume=0 -c:a pcm_s16le "$s"; me_track+=("$s");;
  esac
done
concat "$OUT/conv_me.wav" "${me_track[@]}"
concat "$OUT/conv_them.wav" "${them_track[@]}"
ffmpeg -loglevel error -y -i "$OUT/conv_them.wav" -c:a libopus -b:a 16k -ar 16000 "$OUT/them.opus"
ffmpeg -loglevel error -y -i "$OUT/them.opus" -ar 16000 -ac 1 -c:a pcm_s16le "$OUT/conv_them_zoom.wav"
for w in conv_mix conv_me conv_them; do echo "$w $(ffprobe -v error -show_entries format=duration -of csv=p=0 "$OUT/$w.wav")s"; done
