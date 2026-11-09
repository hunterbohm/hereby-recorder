# /// script
# dependencies = ["num2words"]
# ///
"""First-correct visibility per reference utterance, from an sa-bench stream trace.

Usage: uv run bench/visibility.py PARTS_DIR CHANNEL TRACE.jsonl [THRESHOLD]

PARTS_DIR holds make_conversation.sh's NNN_{me,them}.wav parts and NNN_sil.wav gaps,
which give each utterance's reference start/end on the track timeline. CHANNEL is
"me" or "them". For each utterance of that channel, the trace is replayed in arrival
order; the displayed text for the utterance is every final plus the current volatile
result whose audio range overlaps the utterance (±0.5 s). The utterance is "visible"
at the first arrival where the displayed text contains THRESHOLD (default 0.8) of the
utterance's normalised reference words, and "final" at the first arrival where finals
alone do. Latency = that arrival minus the utterance's reference audio end.
"""
import collections
import glob
import json
import os
import re
import sys
import wave

from num2words import num2words


def norm(text: str) -> list[str]:
    text = text.lower().replace("-", " ")
    text = re.sub(r"(\d),(\d)", r"\1\2", text)
    text = re.sub(r"\d+", lambda m: " " + num2words(int(m.group())) + " ", text)
    text = re.sub(r"[^a-z' ]+", " ", text).replace("'", "")
    return text.split()


def duration(path: str) -> float:
    with wave.open(path) as w:
        return w.getnframes() / w.getframerate()


def speech_end(path: str) -> float:
    """Time of the last sample above 1 % full scale (say pads its output with silence)."""
    with wave.open(path) as w:
        rate, width, n = w.getframerate(), w.getsampwidth(), w.getnframes()
        data = w.readframes(n)
    assert width == 2
    samples = memoryview(data).cast("h")
    for i in range(len(samples) - 1, -1, -1):
        if abs(samples[i]) > 327:
            return (i + 1) / rate
    return 0.0


def utterances(parts_dir: str, reference: list[str]):
    files = sorted((f for f in glob.glob(os.path.join(parts_dir, "[0-9][0-9][0-9]_*.wav")) if "_mute" not in f),
                   key=lambda f: (os.path.basename(f)[:3], os.path.basename(f).endswith("_sil.wav")))
    t = 0.0
    spoken = 0
    for f in files:
        d = duration(f)
        who = os.path.basename(f)[4:-4]
        if who in ("me", "them"):
            yield who, t, t + speech_end(f), reference[spoken]
            spoken += 1
        t += d


def coverage(ref: list[str], shown: list[str]) -> float:
    have = collections.Counter(shown)
    hit = 0
    for w in ref:
        if have[w] > 0:
            have[w] -= 1
            hit += 1
    return hit / len(ref)


def main() -> None:
    parts_dir, channel, trace_path = sys.argv[1:4]
    threshold = float(sys.argv[4]) if len(sys.argv) > 4 else 0.8
    reference = [line.split("|", 1)[1].strip() for line in open(os.path.join(os.path.dirname(__file__), "conversation.txt")) if "|" in line]
    events = sorted((json.loads(l) for l in open(trace_path)), key=lambda e: e["arrival"])
    rows = []
    for who, s, e, text in utterances(parts_dir, reference):
        if who != channel:
            continue
        ref = norm(text)
        finals: list[dict] = []
        volatile: dict | None = None
        seen = fin = None
        best = 0.0
        for ev in events:
            if ev["final"]:
                finals.append(ev)
                volatile = None
            else:
                volatile = ev
            overl = lambda x: x["start"] < e + 0.5 and x["end"] > s - 0.5
            fin_words = [w for x in finals if overl(x) for w in norm(x["text"])]
            shown = fin_words + (norm(volatile["text"]) if volatile and overl(volatile) else [])
            c = coverage(ref, shown)
            best = max(best, c)
            if seen is None and c >= threshold:
                seen = ev["arrival"] - e
            if fin is None and coverage(ref, fin_words) >= threshold:
                fin = ev["arrival"] - e
        rows.append({"ch": channel, "ref_start": round(s, 2), "ref_end": round(e, 2), "words": len(ref), "best_coverage": round(best, 2),
                     "visible_correct_s": None if seen is None else round(seen, 2), "final_correct_s": None if fin is None else round(fin, 2)})
    for r in rows:
        print(json.dumps(r))
    vis = sorted(r["visible_correct_s"] for r in rows if r["visible_correct_s"] is not None)
    fins = sorted(r["final_correct_s"] for r in rows if r["final_correct_s"] is not None)
    pick = lambda a, p: a[min(len(a) - 1, int(p * len(a)))] if a else None
    print(json.dumps({"summary": channel, "utterances": len(rows), "threshold": threshold,
                      "visible_correct_n": len(vis), "visible_correct_p50": pick(vis, 0.5), "visible_correct_max": vis[-1] if vis else None,
                      "final_correct_n": len(fins), "final_correct_p50": pick(fins, 0.5), "final_correct_max": fins[-1] if fins else None}))


if __name__ == "__main__":
    main()
