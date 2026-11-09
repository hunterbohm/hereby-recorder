#!/bin/bash
# Count business-critical terms each transcript got right. Usage: keyterms.sh FILE...
terms=('42,500|42500|forty.two thousand five hundred' 'november (12|twelfth)' 'ninth|9th' '16th|sixteenth' '18,000|18000|eighteen thousand' 'snowflake' 'hubspot' 'salesforce is' 'marcus chen' '3.week|three.week' '6 weeks|six weeks' 'december (1st|first)' '10%|ten percent' '15%|fifteen percent' '24 months|twenty.four months' 'meridian' 'priya' '2:30|two thirty|230')
for f in "$@"; do
  hit=0; miss=()
  for t in "${terms[@]}"; do
    if grep -qiE "$t" "$f"; then hit=$((hit+1)); else miss+=("$t"); fi
  done
  echo "$(basename "$f") $hit/${#terms[@]} missed: ${miss[*]}"
done
