import json
import os
import queue
import signal
import subprocess
import threading
import time
from pathlib import Path

from lml_common import config

SETTINGS = {'model': 'claude-haiku-5-5', 'base_url': 'http://127.0.0.1:8317', 'secret': 'CLIPROXY_API_KEY',
            'auth': 'bearer'}
DEADLINE_S = 10
SECRET_TOOL = Path.home() / '.local/bin/cc-secret'


class ScreenFailed(Exception):
    def __init__(self, reason):
        super().__init__('Meeting screen failed: ' + reason)
        self.reason = reason


def settings():
    value = config().get('screen')
    return {**SETTINGS, **(value if isinstance(value, dict) else {})}


def credential(name, timeout):
    # Hermes scrubs secrets from cron script environments, so the key is fetched per check.
    path = os.environ.get('PATH') or '/usr/bin:/bin'
    env = dict(os.environ, PATH=path + ':/usr/local/bin:/opt/homebrew/bin')
    try:
        process = subprocess.Popen([str(SECRET_TOOL), name], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                   text=True, env=env, start_new_session=True)
    except OSError:
        raise ScreenFailed('credential') from None
    try:
        value, _ = process.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        # The lookup's own children would otherwise hold the pipe open past the deadline.
        os.killpg(process.pid, signal.SIGKILL)
        process.wait()
        process.stdout.close()
        raise ScreenFailed('credential') from None
    if process.returncode or not value.strip():
        raise ScreenFailed('credential')
    return value.strip()


def ask(prompt, *, deadline_s=DEADLINE_S, options=None):
    deadline = time.monotonic() + deadline_s
    chosen = settings()
    try:
        import anthropic
    except ImportError:
        raise ScreenFailed('sdk') from None
    key = credential(chosen['secret'], max(0.5, deadline - time.monotonic()))
    auth = {'auth_token': key} if chosen['auth'] == 'bearer' else {'api_key': key}
    remaining = deadline - time.monotonic()
    if remaining <= 0.5:
        raise ScreenFailed('timeout')
    client = anthropic.Anthropic(base_url=chosen['base_url'], max_retries=0, timeout=remaining, **auth)
    request = {'model': chosen['model'], 'max_tokens': 4096, 'thinking': {'type': 'adaptive'},
               'messages': [{'role': 'user', 'content': prompt}], **(options or {})}
    try:
        return client.messages.create(**request)
    except anthropic.APITimeoutError:
        raise ScreenFailed('timeout') from None
    except anthropic.APIStatusError as exc:
        raise ScreenFailed(f'api_{exc.status_code}') from None
    except anthropic.APIError:
        raise ScreenFailed('api') from None


def parse(message):
    if message.stop_reason != 'end_turn':
        raise ScreenFailed('stop_' + str(message.stop_reason))
    text = ''.join(block.text for block in message.content if block.type == 'text')
    try:
        value = json.JSONDecoder().raw_decode(text, text.index('{'))[0]
    except ValueError:
        raise ScreenFailed('format') from None
    if type(value.get('nudge')) is not bool:
        raise ScreenFailed('format')
    return value


def screen(prompt, *, deadline_s=DEADLINE_S):
    # The SDK timeout is per network phase, so a daemon thread enforces the wall-clock cap.
    result = queue.SimpleQueue()
    def run():
        try:
            result.put(parse(ask(prompt, deadline_s=deadline_s)))
        except Exception as exc:
            result.put(exc)
    threading.Thread(target=run, daemon=True).start()
    try:
        value = result.get(timeout=deadline_s + 0.5)
    except queue.Empty:
        raise ScreenFailed('timeout') from None
    if isinstance(value, Exception):
        raise value
    return value
