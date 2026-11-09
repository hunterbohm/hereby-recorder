# /// script
# dependencies = ["jiwer", "num2words"]
# ///
"""Score hypotheses against the reference: WER after light normalisation.

Usage: uv run bench/score.py REFERENCE.txt NAME=HYP.txt [NAME=HYP.txt ...]
Prints one JSON line per hypothesis.
"""
import json
import re
import sys

import jiwer
from num2words import num2words

ABBREV = {"mr": "mister", "mrs": "missus", "dr": "doctor", "st": "saint"}


def norm(text: str) -> str:
    text = text.lower().replace("-", " ")
    text = re.sub(r"\d+", lambda m: " " + num2words(int(m.group())) + " ", text)
    text = re.sub(r"[^a-z' ]+", " ", text).replace("'", "")
    words = [ABBREV.get(w, w) for w in text.split()]
    return " ".join(words)


def main() -> None:
    ref = norm(open(sys.argv[1]).read())
    for arg in sys.argv[2:]:
        name, path = arg.split("=", 1)
        hyp = norm(open(path).read())
        out = jiwer.process_words(ref, hyp)
        print(json.dumps({"name": name, "wer": round(out.wer * 100, 2), "sub": out.substitutions, "del": out.deletions, "ins": out.insertions, "ref_words": len(ref.split())}))


if __name__ == "__main__":
    main()
