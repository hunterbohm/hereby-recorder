import time
from types import SimpleNamespace

import pytest

import lml_screen
from lml_screen import ScreenFailed, credential, parse, screen


def message(text, stop='end_turn'):
    return SimpleNamespace(stop_reason=stop, content=[SimpleNamespace(type='text', text=text)])


@pytest.mark.parametrize('text', ['{"nudge":false}', '```json\n{"nudge":false}\n```', '{"nudge":false}\nNo issue found.'])
def test_parse_reads_the_first_json_object(text):
    assert parse(message(text)) == {'nudge': False}


@pytest.mark.parametrize('text,stop', [('No issue found.', 'end_turn'), ('[1, 2]', 'end_turn'),
                                       ('{"nudge":false', 'end_turn'), ('{"nudge":false}', 'max_tokens'),
                                       ('{"nudge":false}', 'refusal'), ('{}', 'end_turn'),
                                       ('{"nudge":"true"}', 'end_turn'), ('{"result":{"nudge":true}}', 'end_turn')])
def test_parse_rejects_unusable_replies(text, stop):
    with pytest.raises(ScreenFailed):
        parse(message(text, stop))


def test_hung_credential_lookup_is_killed_at_the_deadline(tmp_path, monkeypatch):
    tool = tmp_path / 'cc-secret'
    tool.write_text('#!/bin/sh\nsleep 30 &\nwait\n')
    tool.chmod(0o755)
    monkeypatch.setattr('lml_screen.SECRET_TOOL', tool)
    start = time.monotonic()
    with pytest.raises(ScreenFailed):
        credential('NAME', 0.5)
    assert time.monotonic() - start < 3


def test_credential_lookup_returns_the_trimmed_value(tmp_path, monkeypatch):
    tool = tmp_path / 'cc-secret'
    tool.write_text('#!/bin/sh\nprintf "  value-for-%s\\n" "$1"\n')
    tool.chmod(0o755)
    monkeypatch.setattr('lml_screen.SECRET_TOOL', tool)
    assert credential('NAME', 5) == 'value-for-NAME'


def test_detached_lookup_child_cannot_hold_the_deadline_open(tmp_path, monkeypatch):
    tool = tmp_path / 'cc-secret'
    tool.write_text('#!/bin/sh\npython3 -c "import os, time; os.setsid(); time.sleep(6)" &\nwait\n')
    tool.chmod(0o755)
    monkeypatch.setattr('lml_screen.SECRET_TOOL', tool)
    start = time.monotonic()
    with pytest.raises(ScreenFailed):
        credential('NAME', 0.5)
    assert time.monotonic() - start < 3


def test_screen_gives_up_at_the_wall_clock_deadline(monkeypatch):
    def hung(prompt, **kwargs):
        time.sleep(5)
    monkeypatch.setattr(lml_screen, 'ask', hung)
    start = time.monotonic()
    with pytest.raises(ScreenFailed) as failure:
        screen('prompt', deadline_s=0.2)
    assert failure.value.reason == 'timeout'
    assert time.monotonic() - start < 2


def test_screen_returns_the_parsed_reply_and_passes_errors_through(monkeypatch):
    monkeypatch.setattr(lml_screen, 'ask', lambda prompt, **kwargs: message('{"nudge":false}'))
    assert screen('prompt') == {'nudge': False}
    def failing(prompt, **kwargs):
        raise ScreenFailed('api_429')
    monkeypatch.setattr(lml_screen, 'ask', failing)
    with pytest.raises(ScreenFailed) as failure:
        screen('prompt')
    assert failure.value.reason == 'api_429'
