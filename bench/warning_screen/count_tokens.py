#!/usr/bin/env python3
"""Count prompt tokens per packet with the API counting endpoint (no generation)."""
import json

import anthropic

from common import DATA, read_rows

import lml_hermes
import lml_screen
import screens


def main():
    screens.use_route('cliproxy')
    chosen = lml_screen.settings()
    client = anthropic.Anthropic(base_url=chosen['base_url'], auth_token=lml_screen.credential(chosen['secret'], 15),
                                 max_retries=2, timeout=30)
    counts = {}
    for packet_set in ('synthetic', 'replay'):
        for row in read_rows(DATA / f'{packet_set}_packets.jsonl'):
            key = row['case'] if packet_set == 'synthetic' else f"tick-{row['tick']:03d}"
            content = [{'role': 'user', 'content': lml_hermes.header() + row['prompt']}]
            counts[key] = {model: client.messages.count_tokens(model=model, messages=content).input_tokens
                           for model in ('claude-haiku-5-5', 'claude-opus-5-5')}
    (DATA / 'token_counts.json').write_text(json.dumps(counts, indent=1))
    values = list(counts.values())
    for model in ('claude-haiku-5-5', 'claude-opus-5-5'):
        replay = [counts[k][model] for k in counts if k.startswith('tick-')]
        print(model, 'replay mean', round(sum(replay) / len(replay)), 'min', min(replay), 'max', max(replay))


if __name__ == '__main__':
    main()
