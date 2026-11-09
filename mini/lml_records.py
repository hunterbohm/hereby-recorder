import json
import re
from dataclasses import asdict, dataclass


@dataclass(frozen=True)
class Record:
    source: str
    date: str
    text: str
    kind: str = 'prior_meeting'
    due: str = ''

    def render(self):
        return '```lml-record\n' + json.dumps(asdict(self), ensure_ascii=False) + '\n```'


def records(brief):
    result = []
    for match in re.finditer(r'```lml-record\n(.*?)\n```', brief, re.S):
        try:
            value = json.loads(match.group(1))
            result.append(Record(**value))
        except (ValueError, TypeError):
            continue
    return result
