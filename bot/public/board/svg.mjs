// A custom picture's SVG, made safe to show: the board room keeps only what this returns (src/ops.js), and the page
// shows that as an image (blocks.mjs), where nothing can run. Pure: tests run it alone.
//
// The model's SVG is read tag by tag and written again from scratch, so nothing passes through as written: only the
// shapes, words and plain attributes listed here, each value checked against what that attribute may hold. Out go
// scripts, styles, event handlers, links, images, foreignObject, filters, animation, entities and every reference to
// anything outside the picture (a url() may only name a marker in the same picture). The text can be cut short, as
// while it is still streaming: a tag left open is closed, a half-written tag is dropped.

const MAX_INPUT = 64 * 1024;
const MAX_OUTPUT = 20000;
const MAX_ELEMENTS = 600;
const MAX_DEPTH = 16;
const MAX_TEXT = 300;
// Elements open at once, kept or not: more is no picture, and would slow every closing tag.
const MAX_OPEN = 64;

// Every pattern here matches in one pass: no two parts of one can take the same characters, so a long value that fails
// fails at once (a list of numbers or transforms is walked a piece at a time, never matched whole).
const NUM = /^[-+]?(?:\d+(?:\.\d*)?|\.\d+)(?:e[-+]?\d+)?(?:px|%)?$/i;
const ONE_NUM = /[-+]?(?:\d+(?:\.\d*)?|\.\d+)(?:e[-+]?\d+)?(?:px|%)?/iy;
const GAP = /[\s,]*/y;
const PATH = /^[MmZzLlHhVvCcSsQqTtAa\d\s,.eE+-]+$/;
const ONE_TRANSFORM = /(?:translate|scale|rotate|matrix|skewX|skewY)\s*\([-+\d.eE\s,]*\)/g;
const COLOR = /^(?:#(?:[0-9a-f]{3,4}|[0-9a-f]{6}|[0-9a-f]{8})|rgba?\(\s*[\d.%\s,]+\)|[a-z]{3,20})$/i;
const REF = /^url\(\s*#([A-Za-z][\w-]{0,31})\s*\)$/;
const ID = /^[A-Za-z][\w-]{0,31}$/;

const short = (limit, test) => (value) => value.length <= limit && test.test(value);
// Numbers apart by spaces or commas ("10,20 30 -4"), read one at a time.
const numbersUpTo = (limit) => (value) => {
  const text = value.trim();
  if (!text || text.length > limit) return false;
  for (let at = 0, first = true; at < text.length; first = false) {
    if (!first) {
      GAP.lastIndex = at;
      GAP.exec(text);
      at = GAP.lastIndex;
    }
    ONE_NUM.lastIndex = at;
    if (!ONE_NUM.exec(text) || ONE_NUM.lastIndex === at) return false;
    at = ONE_NUM.lastIndex;
  }
  return true;
};
// Transforms ("translate(10 20) rotate(45)"): at least one, and nothing between them but spaces and commas.
const transform = (value) => value.length <= 300 && /\(/.test(value) && /^[\s,]*$/.test(value.replace(ONE_TRANSFORM, ''));
const oneOf = (...words) => (value) => words.includes(value);
const paint = (value) => value.length <= 40 && (COLOR.test(value) || REF.test(value));
// A dash pattern repeats at least every 4 units: finer, a long line is thousands of dashes, each slow to paint.
const dashes = (value) => value === 'none' || (numbers(value) && value.split(/[\s,]+/).filter(Boolean)
  .map(Number.parseFloat).reduce((sum, n) => sum + Math.max(0, n), 0) >= 4);
const ref = (value) => value === 'none' || REF.test(value);
const number = short(24, NUM);
const numbers = numbersUpTo(200);

// Each attribute a kept element may carry, and what its value may be.
const ATTRIBUTES = {
  fill: paint, stroke: paint, 'stroke-width': number, 'stroke-dasharray': (v) => dashes(v),
  'stroke-linecap': oneOf('butt', 'round', 'square'), 'stroke-linejoin': oneOf('miter', 'round', 'bevel'),
  'stroke-opacity': number, 'fill-opacity': number, opacity: number, 'fill-rule': oneOf('nonzero', 'evenodd'),
  transform, id: short(32, ID), 'marker-start': ref, 'marker-end': ref,
  'font-size': number, 'font-weight': oneOf('normal', 'bold', 'bolder', 'lighter', '100', '200', '300', '400', '500', '600', '700',
    '800', '900'), 'font-style': oneOf('normal', 'italic'), 'text-anchor': oneOf('start', 'middle', 'end'),
  'dominant-baseline': oneOf('auto', 'middle', 'central', 'hanging', 'alphabetic', 'text-top', 'text-bottom', 'mathematical',
    'ideographic'), 'letter-spacing': number,
  x: numbers, y: numbers, dx: numbers, dy: numbers, width: number, height: number, rx: number, ry: number, cx: number,
  cy: number, r: number, x1: number, y1: number, x2: number, y2: number, points: numbersUpTo(4000), d: short(12000, PATH),
  viewBox: (v) => box(v) !== null, refX: number, refY: number, markerWidth: number, markerHeight: number,
  orient: (v) => v === 'auto' || v === 'auto-start-reverse' || number(v), markerUnits: oneOf('strokeWidth', 'userSpaceOnUse'),
};
const SHARED = ['fill', 'stroke', 'stroke-width', 'stroke-dasharray', 'stroke-linecap', 'stroke-linejoin', 'stroke-opacity',
  'fill-opacity', 'opacity', 'fill-rule', 'transform', 'id', 'marker-start', 'marker-end', 'font-size',
  'font-weight', 'font-style', 'text-anchor', 'dominant-baseline', 'letter-spacing'];
// The elements kept, each with the attributes of its own beyond the shared ones. Any other element goes, with all it
// holds. No marker-mid (a marker at every corner of a long path), and no markers inside a marker: a browser draws each
// marker's own markers again for every one, so a few kilobytes could take it minutes to paint. Marker properties are
// inherited, and a marker's shapes inherit from what is around the marker, so a marker is kept only in a <defs> right
// under the picture, and that <defs> takes none.
const ELEMENTS = {
  svg: ['viewBox'], g: [], defs: [], marker: ['viewBox', 'refX', 'refY', 'markerWidth', 'markerHeight', 'orient', 'markerUnits'],
  rect: ['x', 'y', 'width', 'height', 'rx', 'ry'], circle: ['cx', 'cy', 'r'], ellipse: ['cx', 'cy', 'rx', 'ry'],
  line: ['x1', 'y1', 'x2', 'y2'], polyline: ['points'], polygon: ['points'], path: ['d'], text: ['x', 'y', 'dx', 'dy'],
  tspan: ['x', 'y', 'dx', 'dy'],
};
const WORDS = new Set(['text', 'tspan']);
// The few named characters a model writes; any other "&name;" is kept as plain words.
const NAMED = { amp: '&', lt: '<', gt: '>', quot: '"', apos: "'", nbsp: ' ', mdash: '—', ndash: '–', rarr: '→', larr: '←',
  harr: '↔', uarr: '↑', darr: '↓', hellip: '…', times: '×', middot: '·', bull: '•', check: '✓' };

// A viewBox as [x, y, w, h], or null: four numbers, a size above zero and below 10000.
function box(value) {
  const parts = String(value).trim().split(/[\s,]+/).map(Number);
  if (parts.length !== 4 || parts.some((n) => !Number.isFinite(n))) return null;
  if (parts[2] <= 0 || parts[3] <= 0 || parts[2] > 10000 || parts[3] > 10000) return null;
  return parts;
}

function decode(text) {
  return text.replace(/&(#x[0-9a-f]{1,6}|#\d{1,7}|[a-z]{2,8});/gi, (all, name) => {
    if (name[0] === '#') {
      const code = name[1] === 'x' || name[1] === 'X' ? parseInt(name.slice(2), 16) : parseInt(name.slice(1), 10);
      // Only characters a picture's words might use: no control characters, no surrogates.
      const fine = code >= 0x20 && code <= 0x10ffff && !(code >= 0xd800 && code <= 0xdfff) && code !== 0x7f && code !== 0xfffe
        && code !== 0xffff;
      return fine ? String.fromCodePoint(code) : '';
    }
    return NAMED[name.toLowerCase()] ?? all;
  });
}

const escapeText = (text) => text.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
const escapeValue = (text) => escapeText(text).replace(/"/g, '&quot;');
// Characters an SVG may not hold: an image with one fails to show at all.
// eslint-disable-next-line no-control-regex
const CONTROL = /[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f\ufffe\uffff]/g;

const TAG = /<(\/?)([A-Za-z][\w:.-]*)((?:\s+[^\s=/>"'<]+(?:\s*=\s*(?:"[^"<]*"|'[^'<]*'|[^\s"'<>=`]+))?)*)\s*(\/?)>/y;
const ATTR = /([^\s=/>"'<]+)(?:\s*=\s*(?:"([^"<]*)"|'([^'<]*)'|([^\s"'<>=`]+)))?/g;

// The SVG in `text` made safe, as a string, or null when there is none or it is too big.
export function cleanSvg(text) {
  const source = String(text ?? '');
  if (source.length > MAX_INPUT) return null;
  const start = source.search(/<svg[\s>]/i);
  if (start < 0) return null;
  const out = [];
  // Each open element: whether it is kept (one inside a dropped element never is).
  const open = [];
  let kept = 0;
  let size = 0;
  let root = false;
  let at = start;
  const write = (piece) => {
    size += piece.length;
    out.push(piece);
  };
  const keeping = () => open.length === 0 || open.at(-1).kept;
  while (at < source.length) {
    const lt = source.indexOf('<', at);
    const words = lt < 0 ? source.slice(at) : source.slice(at, lt);
    if (words && open.length && open.at(-1).kept && WORDS.has(open.at(-1).name)) {
      const clean = decode(words).replace(CONTROL, '').replace(/\s+/g, ' ').slice(0, MAX_TEXT);
      if (clean.trim()) write(escapeText(clean));
    }
    if (lt < 0) break;
    at = lt;
    // Comments and character data are dropped; a doctype, an entity or a processing instruction is never read.
    if (source.startsWith('<!--', at)) {
      const end = source.indexOf('-->', at + 4);
      if (end < 0) break;
      at = end + 3;
      continue;
    }
    if (source.startsWith('<![CDATA[', at)) {
      const end = source.indexOf(']]>', at + 9);
      if (end < 0) break;
      at = end + 3;
      continue;
    }
    if (source[at + 1] === '!' || source[at + 1] === '?') return null;
    // A "<" that starts no tag ("p95 < 200 ms") is words, as a browser would read it.
    if (!/[A-Za-z/!?]/.test(source[at + 1] ?? '')) {
      if (source.length > at + 1 && open.length && open.at(-1).kept && WORDS.has(open.at(-1).name)) write('&lt;');
      at += 1;
      continue;
    }
    TAG.lastIndex = at;
    const tag = TAG.exec(source);
    if (!tag) {
      // A tag still being written (the end of a stream): what came before it stands. Anything else is not SVG.
      if (source.indexOf('>', at) < 0) break;
      return null;
    }
    at = TAG.lastIndex;
    const [, closing, name, attrs, selfClosing] = tag;
    if (closing) {
      const found = open.map((o) => o.name).lastIndexOf(name);
      if (found < 0) continue;
      while (open.length > found) {
        const done = open.pop();
        if (done.kept) write(`</${done.name}>`);
      }
      if (!open.length) break;
      continue;
    }
    if (!root && name !== 'svg') continue;
    const home = open.length === 2 && open[1].name === 'defs' && open[1].kept;
    const allowed = Object.hasOwn(ELEMENTS, name) && keeping() && (name !== 'svg' || !root) && open.length < MAX_DEPTH
      && (name !== 'marker' || home);
    if (allowed && ++kept > MAX_ELEMENTS) return null;
    if (allowed) {
      const own = new Set([...ELEMENTS[name], ...(name === 'svg' ? [] : SHARED)]);
      if (name === 'defs' || name === 'marker' || open.some((o) => o.name === 'marker')) {
        own.delete('marker-start');
        own.delete('marker-end');
      }
      const parts = [];
      let viewBox = null;
      for (const [, key, double, single, bare] of attrs.matchAll(ATTR)) {
        // An attribute said twice keeps its first value: twice in the output is not an image at all.
        if (!own.has(key)) continue;
        own.delete(key);
        const value = decode(double ?? single ?? bare ?? '').replace(CONTROL, '').trim();
        if (!ATTRIBUTES[key](value)) continue;
        if (key === 'viewBox' && name === 'svg') viewBox = box(value);
        else parts.push(`${key}="${escapeValue(value)}"`);
      }
      if (name === 'svg') {
        // The picture's own size: its viewBox, else its width and height, else the board's usual canvas.
        const width = Number.parseFloat(/\swidth\s*=\s*["']?(\d+(?:\.\d+)?)/.exec(attrs)?.[1]);
        const height = Number.parseFloat(/\sheight\s*=\s*["']?(\d+(?:\.\d+)?)/.exec(attrs)?.[1]);
        viewBox ??= box(`0 0 ${width} ${height}`) || [0, 0, 1000, 520];
        root = true;
        write(`<svg xmlns="http://www.w3.org/2000/svg" viewBox="${viewBox.join(' ')}">`);
        if (selfClosing) {
          write('</svg>');
          break;
        }
      } else write(`<${name}${parts.length ? ` ${parts.join(' ')}` : ''}${selfClosing ? '/>' : '>'}`);
    }
    if (!selfClosing && open.push({ name, kept: allowed }) > MAX_OPEN) return null;
    if (!allowed && selfClosing) continue;
    if (size > MAX_OUTPUT) return null;
  }
  if (!root) return null;
  while (open.length) {
    const done = open.pop();
    if (done.kept) write(`</${done.name}>`);
  }
  // Half of a character cut in two (an emoji at the 300th place of a label) becomes U+FFFD: a lone half cannot be
  // saved as UTF-8, by the page or by the notes.
  const svg = out.join('').replace(/[\ud800-\udbff](?![\udc00-\udfff])|(?<![\ud800-\udbff])[\udc00-\udfff]/g, '\ufffd');
  return svg.length <= MAX_OUTPUT ? svg : null;
}

// Whether a picture has anything to see yet: a shape or some words.
export const drawsSomething = (svg) => /<(?:rect|circle|ellipse|line|polyline|polygon|path|text)\b/.test(String(svg || ''));
