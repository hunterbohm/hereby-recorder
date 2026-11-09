import re
from dataclasses import dataclass
from decimal import Decimal

NUMBER = re.compile(r'(?<![\w])(?:[$£€]\s*)?(?:\d{1,3}(?:,\d{3})+|\d{2}[- ]\d(?!\d)|\d+)(?:\.\d+)?\s*(?:[kKmM]\b|%|percent\b|dollars?\b|pounds?\b|euros?\b)?')
MONEY = re.compile(r'budget|price|pricing|cost|amount|money|dollar|fund|phase|fee|pay|paid|revenue', re.I)
SMALL = dict((w, i) for i, w in enumerate('zero one two three four five six seven eight nine ten eleven twelve thirteen '
                                         'fourteen fifteen sixteen seventeen eighteen nineteen'.split()))
TENS = dict((w, 10 * i) for i, w in enumerate('twenty thirty forty fifty sixty seventy eighty ninety'.split(), 2))
SCALE = {'hundred': 100, 'thousand': 1000, 'million': 1000000}
WORD_NUMBER = re.compile(r'\b(?:(?P<tens>' + '|'.join(TENS) + r')(?:[- ](?P<ones>' + '|'.join(list(SMALL)[1:10]) +
                         r'))?|(?P<small>' + '|'.join(SMALL) + r'))(?:\s+(?P<scale>' + '|'.join(SCALE) + r'))?\b'
                         r'(?P<unit>\s*(?:%|percent\b|dollars?\b|pounds?\b|euros?\b))?', re.I)


@dataclass(frozen=True)
class Number:
    raw: str
    value: Decimal
    digits: str
    unit: str
    start: int
    end: int
    shorthand: bool


def unit_of(raw, context, suffix):
    if '%' in raw or 'percent' in raw.lower():
        return 'percent'
    if '$' in raw or re.search(r'dollars?\b', raw, re.I):
        return 'USD'
    if '£' in raw or re.search(r'pounds?\b', raw, re.I):
        return 'GBP'
    if '€' in raw or re.search(r'euros?\b', raw, re.I):
        return 'EUR'
    if MONEY.search(context) or suffix:
        return 'money'
    return 'number'


def word_numbers(text):
    for match in WORD_NUMBER.finditer(text):
        words = {k: (v or '').lower() for k, v in match.groupdict().items()}
        if words['small'] == 'one' and not words['scale'] and not words['unit']:
            continue
        value = Decimal(TENS.get(words['tens'], 0) + SMALL.get(words['ones'], 0) + SMALL.get(words['small'], 0))
        value *= SCALE.get(words['scale'], 1)
        raw = match.group().rstrip()
        end = match.start() + len(raw)
        context = text[max(0, match.start() - 35):min(len(text), end + 35)]
        yield Number(raw, value, format(value, 'f').lstrip('0') or '0', unit_of(raw, context, ''), match.start(), end, False)


def numbers(text):
    result = list(word_numbers(text))
    for match in NUMBER.finditer(text):
        raw = match.group().rstrip()
        end = match.start() + len(raw)
        numeric = re.search(r'\d[\d,. -]*', raw).group().strip()
        shorthand = bool(re.fullmatch(r'\d{2}[-. ]\d', numeric))
        value = Decimal(numeric.replace(',', '').replace('-', '').replace(' ', ''))
        suffix = raw[len(raw.rstrip('kKmM')):]
        if suffix:
            value *= Decimal(1000 if suffix.lower() == 'k' else 1000000)
        context = text[max(0, match.start() - 35):min(len(text), end + 35)]
        unit = unit_of(raw, context, suffix)
        digits = format(value, 'f').replace('.', '').lstrip('0') or '0'
        result.append(Number(raw, value, digits, unit, match.start(), end,
                             shorthand and bool(MONEY.search(context) or unit not in {'number', 'percent'})))
    return sorted(result, key=lambda n: n.start)


def possible_shorthand(a, b):
    if a.value == b.value:
        return False
    short, long = sorted((a.digits, b.digits), key=len)
    substring = len(short) >= 2 and short in long
    if not a.value or not b.value:
        return substring
    ratio = max(abs(a.value), abs(b.value)) / min(abs(a.value), abs(b.value))
    while ratio >= 10 and ratio % 10 == 0:
        ratio /= 10
    return substring or ratio == 1


def same_unit(a, b):
    return a.unit == b.unit or {a.unit, b.unit} <= {'money', 'USD'}


def differing_pairs(current, prior):
    current_values, prior_values = {n.value for n in current}, {n.value for n in prior}
    return [(a, b) for a in current if a.value not in prior_values
            for b in prior if b.value not in current_values and same_unit(a, b)]


def annotate(text, references, *, partial=False, compare=True):
    result, cursor = [], 0
    own = numbers(text)
    pairs = [(a, b, source) for source_text, source in references if source_text != text
             for a, b in differing_pairs(own, numbers(source_text))] if compare else []
    for number in own:
        result.extend([text[cursor:number.start], number.raw])
        if partial:
            result.append('⟨unconfirmed⟩')
        matches = [(other, source) for a, other, source in pairs
                   if a == number and possible_shorthand(number, other)]
        if matches:
            other, source = matches[0]
            result.append(f' [as transcribed; may be spoken shorthand for {other.raw} ({source})]')
        elif compare and number.shorthand:
            result.append(' [as transcribed; possibly shorthand]')
        cursor = number.end
    result.append(text[cursor:])
    return ''.join(result)
