# /// script
# dependencies = ["pyarrow", "soundfile", "numpy"]
# ///
"""Build the benchmark sample: a ~5 minute clip from the
LibriSpeech dummy split, plus a reference transcript and a Zoom-like
(Opus 16 kbps round-trip) copy.

Usage: uv run bench/prepare_sample.py OUT_DIR
"""
import io
import json
import subprocess
import sys
import urllib.request
from pathlib import Path

import numpy as np
import pyarrow.parquet as pq
import soundfile as sf

URL = "https://huggingface.co/api/datasets/hf-internal-testing/librispeech_asr_dummy/parquet/clean/validation/0.parquet"
SR = 16000
GAP = np.zeros(int(0.6 * SR), dtype=np.float32)


def main() -> None:
    out = Path(sys.argv[1])
    out.mkdir(parents=True, exist_ok=True)
    pq_path = out / "librispeech_dummy.parquet"
    if not pq_path.exists():
        urllib.request.urlretrieve(URL, pq_path)
    rows = pq.read_table(pq_path).to_pylist()
    rows.sort(key=lambda r: r["id"])
    by_speaker: dict[int, list[dict]] = {}
    for r in rows:
        by_speaker.setdefault(r["speaker_id"], []).append(r)
    speakers = sorted(by_speaker, key=lambda s: -len(by_speaker[s]))[:4]
    picked: list[dict] = []
    i = 0
    total = 0.0
    while total < 300 and any(by_speaker[s] for s in speakers):
        s = speakers[i % len(speakers)]
        i += 1
        if not by_speaker[s]:
            continue
        r = by_speaker[s].pop(0)
        audio, sr = sf.read(io.BytesIO(r["audio"]["bytes"]), dtype="float32")
        assert sr == SR, sr
        picked.append({"id": r["id"], "speaker": s, "text": r["text"].lower(), "audio": audio})
        total += len(audio) / SR + len(GAP) / SR
    chunks, segments, t = [], [], 0.0
    for p in picked:
        dur = len(p["audio"]) / SR
        segments.append({"id": p["id"], "speaker": p["speaker"], "start": round(t, 3), "end": round(t + dur, 3), "text": p["text"]})
        chunks += [p["audio"], GAP]
        t += dur + len(GAP) / SR
    clip = np.concatenate(chunks)
    sf.write(out / "sample_clean.wav", clip, SR, subtype="PCM_16")
    (out / "reference.txt").write_text(" ".join(p["text"] for p in picked) + "\n")
    (out / "reference_segments.json").write_text(json.dumps(segments, indent=1))
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", str(out / "sample_clean.wav"), "-c:a", "libopus", "-b:a", "16k", str(out / "sample_zoom.opus")], check=True)
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", str(out / "sample_zoom.opus"), "-ar", "16000", "-ac", "1", str(out / "sample_zoom.wav")], check=True)
    print(json.dumps({"utterances": len(picked), "speakers": speakers, "seconds": round(len(clip) / SR, 1), "words": sum(len(p["text"].split()) for p in picked)}))


if __name__ == "__main__":
    main()
