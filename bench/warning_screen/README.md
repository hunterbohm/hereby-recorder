# Warning screen evaluation

Compares cheap screens for mid-call warnings (Haiku, Jev) with the Hermes path on the same packets.
Run on the mini from this folder with the Hermes script interpreter, so the screens use the production SDK.
Data goes to `bench/data/warning_screen/`, which git ignores. Hermes sessions are deleted after each check.

1. `python3 replay.py` copies the Oct 23 session read-only and saves every packet the per-minute tick would send.
2. `python3 cases.py` builds the synthetic cases and checks that each true candidate passes `gate()`.
3. `$P count_tokens.py` counts prompt tokens per packet.
4. `$P run.py fast synthetic ...`, `$P run.py fast replay ...`, then `$P run.py hermes ...`. See `run.py` for flags.
5. `python3 select_hermes.py` picks the 20 replay packets for the Hermes path.
6. `python3 export.py` merges rows into `warning-eval-raw.jsonl`, then `python3 report.py warning-eval-raw.jsonl`.

`$P cron_proof.py hermes|minimal` runs the nudge script print-only the way the Hermes cron would.
`$P` is the Hermes script interpreter, `~/.hermes/installs/<id>/environments/<id>/venv/bin/python`.
