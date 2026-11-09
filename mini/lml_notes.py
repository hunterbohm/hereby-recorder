import re


def front_matter(text):
    values = {}
    if not text.startswith('---\n'):
        return values, text
    head, separator, body = text[4:].partition('\n---')
    if not separator:
        return values, text
    key = None
    for line in head.splitlines():
        item = re.match(r'^([\w-]+):\s*(.*)$', line)
        if item:
            key, value = item.groups()
            value = value.strip()
            if value.startswith('[') and value.endswith(']'):
                value = [x.strip().strip('"\'') for x in re.split(r',\s*(?![^\[]*\]\])', value[1:-1])]
            else:
                value = value.strip('"\'')
            values[key] = value
        elif key and line.strip().startswith('- '):
            if not isinstance(values[key], list):
                values[key] = []
            values[key].append(line.strip()[2:].strip('"\''))
    return values, body.lstrip('\n')


def section(body, names):
    match = re.search(r'^##\s+(?:' + '|'.join(map(re.escape, names)) + r')\s*\n(.*?)(?=^##\s|\Z)', body, re.M | re.S | re.I)
    return match.group(1).strip() if match else ''


def links(value):
    if isinstance(value, list):
        value = ' '.join(value)
    return {name.split('|')[0].split('/')[-1].casefold() for name in re.findall(r'\[\[([^\]]+)\]\]', value or '')}
