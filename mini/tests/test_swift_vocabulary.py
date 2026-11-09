"""The Mac app and the mini share state names as strings. Both sides are source, so read both and compare."""
import ast
import re
from pathlib import Path

import lml_common
import lml_status

ROOT = Path(__file__).resolve().parents[2]
SWIFT = ROOT / 'mac/Sources/LMLCore'


def swift_cases(file, declaration):
    """The case names of `declaration` (e.g. 'enum State: String') in a Swift source file."""
    text = (SWIFT / file).read_text()
    start = text.index(declaration)
    body = text[text.index('{', start) + 1:text.index('}', start)]
    names = set()
    for line in body.splitlines():
        match = re.match(r'\s*case\s+(.+)$', line.split('//')[0])
        if match:
            names |= {name.strip() for name in match.group(1).split(',')}
    assert names, f'no cases found after {declaration!r}'
    return names


def returned_literals(function):
    return {node.value.value for node in ast.walk(function)
            if isinstance(node, ast.Return) and isinstance(node.value, ast.Constant)}


def python_filing_states():
    tree = ast.parse(Path(lml_status.__file__).read_text())
    ledger_state = next(item for node in ast.walk(tree) if isinstance(node, ast.ClassDef)
                        for item in node.body if isinstance(item, ast.FunctionDef) and item.name == 'state'
                        and 'done_at' in [a.arg for a in item.args.args])
    # The final `return 'waiting' if ... else 'failed'` is a conditional, not a bare constant.
    conditional = {branch.value for node in ast.walk(ledger_state) if isinstance(node, ast.IfExp)
                   for branch in (node.body, node.orelse) if isinstance(branch, ast.Constant)}
    return returned_literals(ledger_state) | conditional


def test_session_states_match_the_mac_app():
    swift = swift_cases('Models.swift', 'public enum State: String, Codable, Sendable { case active')
    # 'active' is the only open state the mini tests for (lml_common.Session.is_live); the rest end a session.
    assert "!= 'active'" in Path(lml_common.__file__).read_text()
    assert swift == {'active'} | set(lml_status.ENDED)


def test_heartbeat_states_cover_what_the_mini_calls_recording():
    swift = swift_cases('Outbox.swift', 'public enum State: String, Codable, Sendable { case idle')
    assert set(lml_common.RECORDING) <= swift
    assert 'recording' in lml_common.RECORDING
    assert swift == {'idle', 'armed', 'recording', 'paused'}


def test_filing_states_match_the_mac_app():
    swift = swift_cases('UIContract.swift', 'public enum FilingState: String')
    assert swift == python_filing_states()
