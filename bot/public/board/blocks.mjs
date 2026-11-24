// The board's visual blocks: one drawing for each type of block (model.mjs), at sizes that stay readable when a call
// shrinks and compresses the shared screen. Self-contained (it needs model.mjs, kinds.mjs and blocks.css only), so it
// can be lifted out as is; BLOCKS.md says how to add a type.
//
// draw(node, block, { w, h, changed, link }) draws `block` into its element `node` at w by h pixels and returns the
// elements of the items in `changed`, for the page to mark and point Hermes's cursor at. It changes what is there
// rather than starting over: an item keeps its element from one change to the next, so a new one fades in, a moved one
// glides to its place, a bar grows, and an arrow draws itself in. Every element of an item carries `data-id`.
import { branchOf, dayWords, kindOf, numberOf, ROUND, spanOf, withUnit } from './model.mjs';
import { HEAD, PAD } from './sizes.mjs';

const SVG = 'http://www.w3.org/2000/svg';
// Series colors, in a fixed order (validated for color-blind readers as a set of three, dataviz palette).
export const SERIES = ['#2a78d6', '#eb6834', '#1baf7a'];
// A mind map's branches, in order: the three above, then three more that stay apart from them and from each other.
export const BRANCHES = ['#2a78d6', '#eb6834', '#1baf7a', '#c98500', '#d55181', '#008300'];
// Scores on a five-step ramp of one blue, light to dark.
const RAMP = ['#e3eefc', '#b7d3f6', '#86b6ef', '#3987e5', '#1c5cab'];
// A whole's parts, or a stack's series past three, in this order (the branches' colors, as a set).
export const PARTS = BRANCHES;
// A heatmap's shades: one blue, light to dark (dataviz sequential steps 100 to 700); words go white from the fourth.
const HEAT = ['#cde2fb', '#9ec5f4', '#6da7ec', '#3987e5', '#256abf', '#184f95', '#0d366b'];
// A funnel's stages, dark at the top to lighter below, never lighter than step 250 so the last still shows.
const STAGES = ['#184f95', '#1c5cab', '#256abf', '#2a78d6', '#3987e5', '#5598e7', '#6da7ec', '#86b6ef'];
// "Other", for the parts past the sixth.
const OTHER = '#aab2bc';
const LEVEL = { high: 'High', medium: 'Medium', low: 'Low' };
const STATUS = { done: 'Done', now: 'Now', next: 'Next', late: 'Late' };

// What an empty block asks for, in the words to say.
const ASK = {
  list: { goals: 'add a goal: …', risks: 'add a risk: …', actions: 'Lee will send the deck by Friday', decisions: 'we decided …',
    pros: 'add a pro: …', cons: 'add a con: …', notes: 'add …' },
  flow: 'first we …, then …', timeline: 'add a milestone: launch in March', chart: 'add Q3 at 1.2 million',
  table: 'compare Priya and Sam on design', matrix: 'put SSO in quick wins', mindmap: 'add a branch: pricing',
  stats: 'add a key number: churn is 3%', funnel: 'add a stage: signups, 1,800', roadmap: 'payments work runs January to March',
  tree: 'add Sam, reporting to Priya', swimlane: 'support takes the request, then finance approves it',
  sketch: 'draw how the app talks to Stripe',
};
export function ask(block) {
  const words = block.type === 'list' ? ASK.list[kindOf(block)] || `add to ${block.title}` : ASK[block.type];
  return `Hey Hermes, ${words}`;
}

// --- Small pieces -----------------------------------------------------------------------------------------------------

const el = (tag, className, text) => {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined && text !== null) node.textContent = text;
  return node;
};

const svg = (tag, attrs = {}) => {
  const node = document.createElementNS(SVG, tag);
  for (const [key, value] of Object.entries(attrs)) node.setAttribute(key, value);
  return node;
};

// The children of `parent` that stand for `items`, by key: each is made once (`make`), filled every time (`fill`), and
// one whose item is gone fades out. New ones are marked `entering` for one animation. They stand in the items' order,
// so an item added at the top or moved shows there in a list, a table or a row of numbers.
function keyed(parent, items, keyOf, make, fill, { selector = ':scope > [data-key]', instant = false } = {}) {
  const old = new Map([...parent.querySelectorAll(selector)].map((n) => [n.dataset.key, n]));
  const out = new Map();
  for (const item of items) {
    const key = keyOf(item);
    let node = old.get(key);
    if (!node) {
      node = make(item);
      node.dataset.key = key;
      if (!instant) {
        node.classList.add('entering');
        node.addEventListener('animationend', () => node.classList.remove('entering'), { once: true });
      }
      parent.append(node);
    }
    old.delete(key);
    fill(node, item);
    out.set(key, node);
  }
  for (const node of old.values()) leave(node, instant);
  inOrder([...out.values()]);
  return out;
}

// Puts sibling elements in this order, moving only those out of place (each right after the one before it), so the
// rest keep their animations and whatever else shares the parent stays where it is.
export function inOrder(nodes) {
  const PRECEDING = 2; // Node.DOCUMENT_POSITION_PRECEDING
  for (let i = 1; i < nodes.length; i++) {
    if (nodes[i - 1].compareDocumentPosition(nodes[i]) & PRECEDING) nodes[i - 1].after(nodes[i]);
  }
}

function leave(node, instant) {
  if (instant || !node.isConnected || matchMedia('(prefers-reduced-motion: reduce)').matches) return node.remove();
  delete node.dataset.key;
  node.classList.add('leaving');
  node.style.pointerEvents = 'none';
  setTimeout(() => node.remove(), 260);
}

// Moves a positioned element to (x, y), gliding there; one just made appears in place. Its place is kept in data-x and
// data-y, so the page can point at where it ends up while it is still moving (board.mjs).
export function put(node, x, y) {
  const to = `${Math.round(x)}px ${Math.round(y)}px`;
  node.dataset.x = Math.round(x);
  node.dataset.y = Math.round(y);
  if (!node.style.translate) {
    node.style.transition = 'none';
    node.style.translate = to;
    void node.offsetWidth;
    node.style.transition = '';
  } else node.style.translate = to;
}

// A path that moves smoothly when it changes (Chrome animates `d`), and draws itself in when new.
function pathTo(path, d, instant) {
  const fresh = !path.style.d;
  path.style.d = `path("${d}")`;
  if (fresh && !instant) {
    path.setAttribute('pathLength', '1');
    path.classList.add('drawing');
    path.addEventListener('animationend', () => { path.classList.remove('drawing'); path.removeAttribute('pathLength'); }, { once: true });
  }
}

const empty = (block, link) => {
  const box = el('div', 'blk-empty');
  box.append(link ? 'Tap + Add, or say ' : 'Say ', el('q', '', ask(block)));
  return box;
};

// A number the way a board says it: 1200 as "1,200", 1250000 as "1.25M", with the unit's sign: "$1.2M", "38%".
export function shown(value, unit = '') {
  const n = numberOf(value);
  if (n === null) return '—';
  const abs = Math.abs(n);
  const round = (v, digits) => Number(v.toFixed(digits)).toLocaleString('en-US');
  let text = abs >= 1e9 ? `${round(n / 1e9, abs >= 1e10 ? 0 : 1)}B` : abs >= 1e6 ? `${round(n / 1e6, abs >= 1e7 ? 0 : 2)}M`
    : abs >= 1e5 ? `${round(n / 1e3, 0)}k` : round(n, abs < 10 && !Number.isInteger(n) ? 2 : abs < 100 ? 1 : 0);
  // A sign, and a size the numbers leave out ("$M"), are part of each number; a word unit is said once, beside them.
  const u = String(unit || '').trim();
  if (!/^(?:[$€£][kMB]?|%)$/.test(u)) return text;
  // Nothing has no size: an axis starts at "$0", not "$0M".
  return withUnit(text, n === 0 ? u.slice(0, 1) : u);
}
// A unit worth saying beside the numbers ("k users", "hrs"); a sign is part of each number instead.
const unitWords = (unit) => (/^(?:[$€£][kMB]?|%)?$/.test(String(unit || '').trim()) ? '' : String(unit).trim());

// Gridline steps that read well: 1, 2, 2.5 or 5 times a power of ten.
export function ticks(min, max, most = 5) {
  if (max <= min) max = min + 1;
  const raw = (max - min) / most;
  const power = 10 ** Math.floor(Math.log10(raw));
  const step = [1, 2, 2.5, 5, 10].map((m) => m * power).find((s) => s >= raw) || 10 * power;
  const lo = Math.floor(min / step) * step;
  const hi = Math.ceil(max / step) * step;
  const out = [];
  for (let v = lo; v <= hi + step / 2; v += step) out.push(Number(v.toFixed(10)));
  return out;
}

// --- The block itself ---------------------------------------------------------------------------------------------------

const META = {
  list: (b) => (b.items.length ? metaOfList(b) : ''),
  flow: (b) => (b.items.length ? `${b.items.length} step${b.items.length === 1 ? '' : 's'}` : ''),
  timeline: (b) => (b.items.length ? `${b.items.filter((i) => i.status === 'done').length} of ${b.items.length} done` : ''),
  chart: (b) => unitWords(b.unit),
  table: (b) => (b.pick ? '' : (b.columns || []).length ? `${b.columns.length} options` : ''),
  matrix: () => '',
  mindmap: () => '',
  stats: () => '',
  funnel: (b) => {
    const values = b.items.map((i) => numberOf(i.value));
    if (values.length < 2 || values[0] === null || !values[0] || values.at(-1) === null) return unitWords(b.unit);
    return `${shownShare(values.at(-1) / values[0])} end to end`;
  },
  roadmap: (b) => {
    const spans = b.items.map((i) => spanOf(i)).filter(Boolean);
    if (!spans.length) return '';
    const from = Math.min(...spans.map((x) => x.from));
    const to = Math.max(...spans.map((x) => x.to));
    return `${dayWords(from, { month: true })} to ${dayWords(to, { month: true, year: true })}`;
  },
  tree: () => '',
  swimlane: (b) => (b.items.length ? `${b.items.length} step${b.items.length === 1 ? '' : 's'}, ${lanesOf(b).length} lane${lanesOf(b).length === 1 ? '' : 's'}` : ''),
  sketch: () => '',
};

// A share as people say it: 38%, 4.5%, 0.8%.
const shownShare = (r) => `${Number((r * 100).toFixed(r < 0.1 ? 1 : 0))}%`;

// How far a key number is along to its target: the share the meter fills, null when either is not a number, and its
// words. Short of the target never reads as 100% (4.49 of 4.5 is "99.7% of target"), and a percent short of a percent
// target says the gap between them ("0.04 below target 99.99%"), never a percent of a percent.
export function toTarget(value, target) {
  const share = numberOf(value) !== null && numberOf(target) ? numberOf(value) / numberOf(target) : null;
  if (share === null) return { share, words: `Target ${target}` };
  if (share >= 1) return { share, words: `Target ${target} met` };
  if (/%\s*$/.test(String(value)) && /%\s*$/.test(String(target))) {
    const gap = Math.round((numberOf(target) - numberOf(value)) * 100) / 100;
    return { share, words: `${gap} below target ${target}` };
  }
  const said = Math.round(share * 100) >= 100 ? `${Math.floor(share * 1000) / 10}%` : shownShare(share);
  return { share, words: `${said} of target ${target}` };
}

function metaOfList(block) {
  const n = block.items.length;
  if (kindOf(block) !== 'actions') return String(n);
  const open = block.items.filter((i) => !i.owner).length;
  if (!open) return String(n);
  return `${n}, ${open === n ? (n === 1 ? 'needs an owner' : 'none has an owner') : `${open} need${open === 1 ? 's' : ''} an owner`}`;
}

// A title too long for its block is set smaller, down to three quarters of its size (still well above the smallest
// type the shared screen keeps), before it is cut short.
function fitTitle(title) {
  title.style.removeProperty('--fit');
  if (title.scrollWidth > title.clientWidth + 1) {
    title.style.setProperty('--fit', Math.max(0.75, (title.clientWidth / title.scrollWidth) * 0.98).toFixed(3));
  }
}

// Draws `block` into `node` (an <article>), w by h pixels. Returns Map(item id -> element) for the items in `changed`.
export function draw(node, block, { w, h, changed = new Set(), link = false, instant = false, density = 1 } = {}) {
  if (!node.querySelector(':scope > .blk-head')) {
    const head = el('div', 'blk-head');
    head.append(el('h2', 'blk-title'), el('span', 'blk-meta'));
    node.append(head, el('div', 'blk-body'));
  }
  node.dataset.block = block.id;
  node.dataset.id = block.id;
  node.dataset.kind = block.type === 'list' ? kindOf(block) : '';
  node.style.setProperty('--d', density);
  const body = node.querySelector(':scope > .blk-body');
  // A block drawn another way (a chart made a donut, a flow made a swimlane) starts its drawing over.
  const shape = shapeOf(block);
  if (node.dataset.shape !== shape) {
    body.replaceChildren();
    node.dataset.shape = shape;
  }
  node.dataset.type = block.type;
  const title = node.querySelector('.blk-title');
  if (title.textContent !== block.title) {
    title.textContent = block.title;
    fitTitle(title);
  }
  // A block's width changes as others come and go: its title is fitted again then.
  node.titleWatch ??= typeof ResizeObserver === 'function' ? new ResizeObserver(() => fitTitle(title)) : null;
  node.titleWatch?.observe(title);
  node.querySelector('.blk-meta').textContent = META[block.type]?.(block) || '';
  let add = node.querySelector(':scope > .blk-head > .add');
  if (link && !add && block.type !== 'sketch') {
    add = el('button', 'add', '+ Add');
    add.type = 'button';
    node.querySelector('.blk-head').append(add);
  } else if (!link && add) add.remove();
  const inner = { w: Math.max(80, w - PAD * density), h: Math.max(60, h - (HEAD + PAD) * density) };
  body.style.height = `${Math.round(inner.h)}px`;
  const drawn = (DRAW[block.type] || DRAW.list)(body, block, { ...inner, changed, link, instant, d: density });
  const hit = new Map();
  for (const id of changed) if (drawn.get(id)) hit.set(id, drawn.get(id));
  return hit;
}

function shapeOf(block) {
  if (block.type !== 'chart') return block.type;
  return ROUND.includes(block.style) ? 'chart:round' : block.style === 'heatmap' ? 'chart:heat' : 'chart';
}

// --- list: cards of one kind ------------------------------------------------------------------------------------------

function listRow(row, item, block) {
  const actions = kindOf(block) === 'actions';
  const signature = JSON.stringify([item, actions, kindOf(block)]);
  if (row.dataset.sig === signature) return;
  row.dataset.sig = signature;
  row.dataset.id = item.id;
  row.classList.toggle('act', actions);
  const words = el('span', 'words');
  if (kindOf(block) === 'decisions') words.append(el('span', 'check'));
  if (LEVEL[item.level]) words.append(el('span', `sev ${item.level}`, LEVEL[item.level]));
  words.append(item.text);
  const parts = [words];
  if (actions) {
    const owner = el('span', `owner${item.owner ? '' : ' none'}`);
    const name = el('span', '', item.owner || 'No owner');
    if (item.due) name.append(el('span', 'due', item.due));
    owner.append(el('i', '', (item.owner || '').trim().charAt(0).toUpperCase()), name);
    parts.push(owner);
  } else if (item.owner || item.due) {
    words.append(el('span', 'due', [item.owner, item.due].filter(Boolean).join(' · ')));
  }
  const tag = row.querySelector(':scope > .tag');
  row.replaceChildren(...parts, ...(tag ? [tag] : []));
}

function drawList(body, block, { link, instant }) {
  let list = body.querySelector(':scope > ul.rows');
  if (!list) list = body.appendChild(el('ul', 'rows'));
  const rows = keyed(list, block.items, (i) => i.id, () => el('li', 'row'), (row, item) => listRow(row, item, block),
    { selector: ':scope > li[data-key]', instant });
  body.querySelector(':scope > .blk-empty')?.remove();
  list.hidden = !block.items.length;
  if (!block.items.length) body.append(empty(block, link));
  // A list with more rows than fit says how many are out of sight: counted once drawn, and again whenever the list
  // changes size (a block glides to its new size, so the first count can see it half way).
  requestAnimationFrame(() => countHidden(body, list));
  if (!list.watch && typeof ResizeObserver === 'function') {
    list.watch = new ResizeObserver(() => countHidden(body, list));
    list.watch.observe(list);
  }
  return rows;
}

function countHidden(body, list) {
  let more = body.querySelector(':scope > .more');
  let hidden = 0;
  if (!list.hidden) {
    for (const row of list.children) if (row.dataset.key && row.offsetTop - list.offsetTop + row.offsetHeight > list.clientHeight + 2) hidden += 1;
  }
  if (!hidden) more?.remove();
  else {
    more ??= body.appendChild(el('span', 'more'));
    more.textContent = `+${hidden} more`;
  }
}

// --- flow: steps in order, joined by arrows ----------------------------------------------------------------------------

function drawFlow(body, block, { w, h, link, instant, d }) {
  const stage = stageOf(body);
  const items = block.items;
  if (!items.length) {
    stage.layer.replaceChildren();
    stage.lines.replaceChildren();
    stage.labels.replaceChildren();
    if (!body.querySelector(':scope > .blk-empty')) body.append(empty(block, link));
    return new Map();
  }
  body.querySelector(':scope > .blk-empty')?.remove();
  const gapX = 56 * d;
  const perRow = Math.max(1, Math.min(items.length, Math.floor((w + gapX) / (176 * d + gapX))));
  const nodeW = Math.min(250 * d, (w - gapX * (perRow - 1)) / perRow);
  const nodes = keyed(stage.layer, items, (i) => i.id, () => {
    const node = el('div', 'fnode');
    node.append(el('b', 'num'), el('span', 'txt'));
    return node;
  }, (node, item) => {
    node.dataset.id = item.id;
    node.dataset.shape = item.shape || 'step';
    node.style.width = `${Math.round(nodeW)}px`;
    node.querySelector('.num').textContent = String(items.slice(0, items.indexOf(item) + 1).filter((i) => !i.shape || i.shape === 'step').length);
    node.querySelector('.txt').textContent = item.text;
  }, { instant });
  // Rows of steps, each as tall as its tallest. A link that skips ahead within a row arcs over it; any other (back to
  // an earlier step, a loop) arcs under its row.
  const rows = [];
  for (let i = 0; i < items.length; i += perRow) rows.push(items.slice(i, i + perRow));
  const where = new Map(items.map((i, n) => [i.id, n]));
  const rowOf = (id) => Math.floor(where.get(id) / perRow);
  const known = (block.links || []).filter((l) => where.has(l.from) && where.has(l.to));
  // A link to the very next step is the order's own arrow, with its words ("No") on it.
  const next = (l) => where.get(l.to) === where.get(l.from) + 1;
  const said = new Map(known.filter(next).map((l) => [l.to, l.label]));
  const links = known.filter((l) => !next(l));
  const ahead = (l) => where.get(l.to) > where.get(l.from) && rowOf(l.from) === rowOf(l.to);
  const over = new Set(links.filter(ahead).map((l) => rowOf(l.from)));
  const under = new Set(links.filter((l) => !ahead(l)).map((l) => rowOf(l.from)));
  const ARC = 58 * d;
  const GAP_Y = 60 * d;
  const heights = new Map(items.map((i) => [i.id, nodes.get(i.id).offsetHeight]));
  const rowHeights = rows.map((row) => Math.max(...row.map((i) => heights.get(i.id))));
  const room = rows.map((_, r) => (over.has(r) ? ARC : 0) + (under.has(r) ? ARC : 0));
  const total = rowHeights.reduce((a, b) => a + b, 0) + room.reduce((a, b) => a + b, 0) + (rows.length - 1) * GAP_Y;
  let y = Math.max(0, (h - total) / 2);
  const box = new Map();
  rows.forEach((row, r) => {
    if (over.has(r)) y += ARC;
    const rowW = row.length * nodeW + (row.length - 1) * gapX;
    let x = Math.max(0, (w - rowW) / 2);
    for (const item of row) {
      const nh = heights.get(item.id);
      const top = y + (rowHeights[r] - nh) / 2;
      put(nodes.get(item.id), x, top);
      box.set(item.id, { x, y: top, w: nodeW, h: nh });
      x += nodeW + gapX;
    }
    y += rowHeights[r] + (under.has(r) ? ARC : 0) + GAP_Y;
  });
  // The order's arrows: side to side within a row, and down and back to the start of the next row.
  const lines = [];
  for (let i = 1; i < items.length; i++) {
    const a = box.get(items[i - 1].id);
    const b = box.get(items[i].id);
    const same = rowOf(items[i].id) === rowOf(items[i - 1].id);
    const mid = b.y - GAP_Y / 2 - (over.has(rowOf(items[i].id)) ? ARC : 0);
    const path = same
      ? `M ${a.x + a.w + 4} ${a.y + a.h / 2} L ${b.x - 10} ${b.y + b.h / 2}`
      : `M ${a.x + a.w / 2} ${a.y + a.h + 4} L ${a.x + a.w / 2} ${mid} L ${b.x + b.w / 2} ${mid} L ${b.x + b.w / 2} ${b.y - 10}`;
    const label = said.get(items[i].id);
    const at = same ? { x: (a.x + a.w + b.x) / 2, y: a.y + a.h / 2 - 17 * d } : { x: a.x + a.w / 2, y: (a.y + a.h + mid) / 2 };
    lines.push({ key: `seq:${items[i - 1].id}>${items[i].id}`, d: path, cls: 'arrow', ...(label ? { label, at } : {}) });
  }
  for (const l of links) {
    const a = box.get(l.from);
    const b = box.get(l.to);
    const ax = a.x + a.w / 2;
    const bx = b.x + b.w / 2;
    let path;
    let at;
    if (ahead(l)) {
      const top = Math.min(a.y, b.y);
      path = `M ${ax} ${a.y - 4} C ${ax} ${top - ARC}, ${bx} ${top - ARC}, ${bx} ${b.y - 10}`;
      at = { x: (ax + bx) / 2, y: top - ARC * 0.75 };
    } else {
      const bottom = Math.max(a.y + a.h, b.y + b.h);
      path = `M ${ax} ${a.y + a.h + 4} C ${ax} ${bottom + ARC}, ${bx} ${bottom + ARC}, ${bx} ${b.y + b.h + 10}`;
      at = { x: (ax + bx) / 2, y: bottom + ARC * 0.75 };
    }
    lines.push({ key: `link:${l.from}>${l.to}`, d: path, cls: 'arrow link', label: l.label, at });
  }
  drawLines(stage, lines, instant);
  return nodes;
}

// The arrows of a flow or a timeline's line or a mind map's twigs, keyed so each keeps its path from one change to the
// next; a link's words sit on it in a pill.
function drawLines(stage, lines, instant) {
  keyed(stage.lines, lines, (l) => l.key, (line) => svg('path', { 'marker-end': line.cls.includes('arrow') ? 'url(#hb-head)' : '' }),
    (path, line) => {
      path.setAttribute('class', line.cls);
      if (line.color) path.style.stroke = line.color;
      pathTo(path, line.d, instant);
    }, { selector: ':scope > path[data-key]', instant });
  keyed(stage.labels, lines.filter((l) => l.label), (l) => `label:${l.key}`, () => el('span', 'pill'), (pill, line) => {
    pill.textContent = line.label;
    put(pill, line.at.x, line.at.y);
  }, { instant });
}

// The arrowhead every flow shares, defined once in the page.
function arrowhead() {
  if (document.getElementById('hb-head')) return;
  const holder = svg('svg', { width: '0', height: '0', 'aria-hidden': 'true' });
  holder.style.position = 'absolute';
  const marker = svg('marker', { id: 'hb-head', viewBox: '0 0 10 10', refX: '6', refY: '5', markerWidth: '4.5', markerHeight: '4.5',
    orient: 'auto-start-reverse', markerUnits: 'strokeWidth' });
  marker.append(svg('path', { d: 'M 0 0 L 10 5 L 0 10 z', fill: '#8a94a0' }));
  holder.append(marker);
  document.body.append(holder);
}

// A block body that draws with positioned elements over an SVG of lines.
function stageOf(body) {
  let stage = body.querySelector(':scope > .stage');
  if (!stage) {
    arrowhead();
    stage = el('div', 'stage');
    stage.append(svg('svg', { class: 'lines', 'aria-hidden': 'true' }), el('div', 'layer'), el('div', 'labels'));
    body.append(stage);
  }
  return { node: stage, lines: stage.querySelector('svg.lines'), layer: stage.querySelector('.layer'), labels: stage.querySelector('.labels') };
}

// --- timeline: milestones in time order --------------------------------------------------------------------------------

function drawTimeline(body, block, { w, h, link, instant, d }) {
  const stage = stageOf(body);
  const items = block.items;
  if (!items.length) {
    stage.layer.replaceChildren();
    stage.lines.replaceChildren();
    stage.labels.replaceChildren();
    if (!body.querySelector(':scope > .blk-empty')) body.append(empty(block, link));
    return new Map();
  }
  body.querySelector(':scope > .blk-empty')?.remove();
  const perRow = Math.max(1, Math.min(items.length, Math.floor(w / (176 * d))));
  const rows = Math.ceil(items.length / perRow);
  const slot = w / perRow;
  const cards = keyed(stage.layer, items, (i) => i.id, () => {
    const card = el('div', 'tl-item');
    card.append(el('span', 'when'), el('span', 'dot'), el('span', 'txt'), el('span', 'state'));
    return card;
  }, (card, item) => {
    card.dataset.id = item.id;
    card.dataset.status = item.status || '';
    card.style.width = `${Math.round(slot - 24 * d)}px`;
    card.querySelector('.when').textContent = item.when || '';
    card.querySelector('.txt').textContent = item.text;
    card.querySelector('.state').textContent = item.status === 'late' || item.status === 'now' ? STATUS[item.status] : '';
  }, { instant });
  const rowH = Math.max(...items.map((i) => cards.get(i.id).offsetHeight));
  const gap = 28 * d;
  const total = rows * rowH + (rows - 1) * gap;
  let top = Math.max(0, (h - total) / 2);
  const lines = [];
  // How far along the work is: the line is dark up to the last milestone done or under way.
  const reached = Math.max(-1, ...items.map((i, n) => (i.status === 'done' || i.status === 'now' ? n : -1)));
  for (let r = 0; r < rows; r++) {
    const row = items.slice(r * perRow, (r + 1) * perRow);
    const lineY = top + 44 * d;
    row.forEach((item, i) => put(cards.get(item.id), i * slot + 12 * d, top));
    // The line starts at the first dot (a later row carries on from the edge) and is dark up to the dot reached.
    const dot = (i) => i * slot + 23 * d;
    const start = r === 0 ? dot(0) : 0;
    const end = row.length * slot - 4;
    lines.push({ key: `line:${r}`, d: `M ${start} ${lineY} L ${end} ${lineY}`, cls: 'tl-line' });
    const last = reached - r * perRow;
    if (last >= 0) {
      const to = last > row.length - 1 ? end : dot(last);
      lines.push({ key: `done:${r}`, d: `M ${start} ${lineY} L ${to} ${lineY}`, cls: 'tl-line reached' });
    }
    top += rowH + gap;
  }
  drawLines(stage, lines, instant);
  return cards;
}

// --- chart: numbers by category ----------------------------------------------------------------------------------------

function drawChart(body, block, opts) {
  if (ROUND.includes(block.style)) return drawRound(body, block, opts);
  if (block.style === 'heatmap') return drawHeat(body, block, opts);
  return drawAxes(body, block, opts);
}

const seriesOf = (block) => ((block.columns || []).length ? block.columns : [{ id: '', name: block.title }]);
const valueIn = (item, s) => (s.id ? numberOf(item.cells?.[s.id]) : numberOf(item.value));
const seriesColor = (k, n) => (n > SERIES.length ? PARTS : SERIES)[k % (n > SERIES.length ? PARTS : SERIES).length];

// Bars (grouped, or stacked: each category's series one on another), or a line, on real axes.
function drawAxes(body, block, { w, h, instant, d, link }) {
  const series = seriesOf(block);
  const valueOf = valueIn;
  const stacked = block.style === 'stacked' && series.length > 1;
  // A stack's height is its series together (a part below zero is left out of it).
  const totals = block.items.map((i) => series.reduce((sum, s) => sum + Math.max(0, valueOf(i, s) ?? 0), 0));
  const values = stacked ? totals : block.items.flatMap((i) => series.map((s) => valueOf(i, s))).filter((v) => v !== null);
  let plot = body.querySelector(':scope > .chart');
  if (!plot) {
    plot = el('div', 'chart');
    plot.append(el('div', 'legend'), el('div', 'grid'), svg('svg', { class: 'lines', 'aria-hidden': 'true' }), el('div', 'bars'),
      el('div', 'cats'));
    body.append(plot);
  }
  body.querySelector(':scope > .blk-empty')?.remove();
  if (!block.items.length) body.append(empty(block, link));
  // Two or more series get a legend; one is named by the block's title.
  const legend = plot.querySelector('.legend');
  legend.hidden = series.length < 2;
  if (series.length > 1) {
    legend.replaceChildren(...series.map((s, i) => {
      const key = el('span', 'key');
      const swatch = el('i');
      swatch.style.background = seriesColor(i, series.length);
      key.append(swatch, s.name);
      return key;
    }));
  }
  const line = block.style === 'line';
  const top = (series.length > 1 ? 44 : 6) * d + 30 * d;
  const left = 66 * d;
  const bottom = 58 * d;
  const plotW = Math.max(60, w - left - 6);
  const plotH = Math.max(60, h - top - bottom);
  plot.style.setProperty('--left', `${left}px`);
  const lo = Math.min(0, ...values);
  const hi = Math.max(lo + 1, ...values);
  const marks = ticks(lo, hi, plotH > 220 ? 5 : 4);
  const min = marks[0];
  const max = marks.at(-1);
  const yOf = (v) => top + plotH - ((v - min) / (max - min)) * plotH;
  // Gridlines and their numbers, quiet; the zero line a step stronger.
  keyed(plot.querySelector('.grid'), marks, (v) => `t:${v}`, () => {
    const tick = el('div', 'tick');
    tick.append(el('span'));
    return tick;
  }, (tick, v) => {
    tick.classList.toggle('zero', v === 0);
    tick.style.width = `${Math.round(left + plotW)}px`;
    put(tick, 0, yOf(v));
    tick.querySelector('span').textContent = shown(v, block.unit);
  }, { instant });
  const band = plotW / Math.max(1, block.items.length);
  const barW = line ? 0 : stacked ? Math.min(84 * d, band * 0.62) : Math.min(72 * d, (band * 0.64) / series.length);
  const marksOf = [];
  block.items.forEach((item, i) => {
    let base = 0;
    series.forEach((s, k) => {
      const v = valueOf(item, s);
      if (v === null) return;
      const cx = left + band * i + band / 2 + (line || stacked ? 0 : (k - (series.length - 1) / 2) * (barW + 4 * d));
      const from = stacked ? base : 0;
      if (stacked) base += Math.max(0, v);
      marksOf.push({ key: `${item.id}:${s.id}`, item, v, cx, k, from, color: seriesColor(k, series.length), name: s.name });
    });
    // A stack's top part has the rounded end, and the stack's total is said above it.
    const own = marksOf.filter((m) => m.item === item && m.v > 0);
    if (stacked && own.length) {
      own.at(-1).top = true;
      own.at(-1).total = totals[i];
    }
  });
  // Numbers on the marks while they fit; past that, on each series' highest and last only. A stack says its total.
  const roomy = marksOf.length <= 10 && (line || barW >= 40 * d);
  const labelled = new Set();
  if (stacked) for (const m of marksOf) { if (m.top) labelled.add(m.key); }
  else if (roomy) for (const m of marksOf) labelled.add(m.key);
  else {
    for (let k = 0; k < series.length; k++) {
      const own = marksOf.filter((m) => m.k === k);
      if (!own.length) continue;
      labelled.add(own.reduce((a, b) => (b.v > a.v ? b : a)).key);
      labelled.add(own.at(-1).key);
    }
  }
  const out = new Map();
  keyed(plot.querySelector('.bars'), marksOf, (m) => m.key, () => {
    const mark = el('div');
    mark.append(el('span', 'val'));
    return mark;
  }, (mark, m) => {
    mark.classList.toggle('bar', !line);
    mark.classList.toggle('pt', line);
    mark.classList.toggle('seg', stacked);
    mark.classList.toggle('top', Boolean(stacked && m.top));
    mark.dataset.id = m.item.id;
    mark.style.setProperty('--c', m.color);
    mark.title = `${m.item.text}${series.length > 1 ? `, ${m.name}` : ''}: ${shown(m.v, block.unit)}`;
    const value = mark.querySelector('.val');
    value.textContent = shown(stacked ? m.total : m.v, block.unit);
    value.hidden = !labelled.has(m.key);
    if (line) {
      mark.style.height = '';
      mark.style.width = '';
      put(mark, m.cx, yOf(m.v));
    } else if (stacked) {
      // Parts of a stack sit one on another with a 2px gap of the panel between them.
      const y0 = yOf(m.from);
      const y1 = yOf(m.from + Math.max(0, m.v));
      const gap = m.from > 0 ? 2 * d : 0;
      mark.style.width = `${Math.round(barW)}px`;
      mark.style.height = `${Math.round(Math.max(2, y0 - y1 - gap))}px`;
      mark.classList.remove('neg');
      put(mark, m.cx - barW / 2, y1);
    } else {
      const y0 = yOf(Math.max(0, min));
      const y1 = yOf(m.v);
      mark.style.width = `${Math.round(barW)}px`;
      mark.style.height = `${Math.round(Math.max(4, Math.abs(y0 - y1)))}px`;
      mark.classList.toggle('neg', m.v < 0);
      put(mark, m.cx - barW / 2, Math.min(y0, y1));
    }
    if (!out.has(m.item.id) || m.k === 0) out.set(m.item.id, mark);
  }, { instant });
  // A line chart's line, one per series, through its points in order.
  const paths = line ? series.map((s, k) => {
    const pts = marksOf.filter((m) => m.k === k);
    return { key: `line:${s.id || 'one'}`, color: seriesColor(k, series.length), n: pts.length,
      d: pts.map((m, i) => `${i ? 'L' : 'M'} ${m.cx} ${yOf(m.v)}`).join(' ') };
  }).filter((p) => p.n > 1) : [];
  keyed(plot.querySelector('svg.lines'), paths, (p) => p.key, () => svg('path', { class: 'series' }), (path, p) => {
    path.style.stroke = p.color;
    pathTo(path, p.d, instant);
  }, { selector: ':scope > path[data-key]', instant });
  // Names whose longest word is wider than their slot (a narrow chart: "November" beside another board) are made smaller,
  // down to three quarters, rather than broken inside the word.
  const slot = Math.max(40, band - 8);
  const longest = Math.max(1, ...block.items.flatMap((i) => String(i.text || '').split(/\s+/).map((word) => word.length)));
  plot.querySelector('.cats').style.setProperty('--fit', Math.max(0.75, Math.min(1, slot / (longest * 0.6 * 17 * d))).toFixed(3));
  const cats = keyed(plot.querySelector('.cats'), block.items, (i) => i.id, () => el('span', 'cat'), (cat, item) => {
    cat.dataset.id = item.id;
    cat.textContent = item.text;
    cat.style.width = `${Math.round(slot)}px`;
    put(cat, left + band * block.items.indexOf(item) + 4, top + plotH + 10 * d);
    cat.classList.toggle('missing', series.every((s) => valueOf(item, s) === null));
  }, { instant });
  for (const [id, cat] of cats) if (!out.has(id)) out.set(id, cat);
  return out;
}

// --- table: options compared on criteria -------------------------------------------------------------------------------

function drawTable(body, block, { link, instant, d }) {
  const columns = block.columns || [];
  let grid = body.querySelector(':scope > .table');
  if (!grid) grid = body.appendChild(el('div', 'table'));
  grid.style.gridTemplateColumns = `minmax(${Math.round(150 * d)}px, 1.25fr) repeat(${Math.max(1, columns.length)}, minmax(0, 1fr))`;
  const scale = block.scale || 5;
  const numeric = block.items.some((i) => columns.some((c) => typeof i.cells?.[c.id] === 'number'));
  const totals = Object.fromEntries(columns.map((c) => [c.id, block.items.reduce((sum, i) => sum + (typeof i.cells?.[c.id] === 'number' ? i.cells[c.id] : 0), 0)]));
  const rows = [{ key: 'head', head: true }, ...block.items.map((item) => ({ key: item.id, item })), ...(numeric ? [{ key: 'total', total: true }] : [])];
  const out = new Map();
  keyed(grid, rows, (r) => r.key, () => el('div', 'trow'), (row, r) => {
    row.className = `trow${r.head ? ' head' : ''}${r.total ? ' total' : ''}${['entering', 'new'].filter((c) => row.classList.contains(c)).map((c) => ` ${c}`).join('')}`;
    if (r.item) row.dataset.id = r.item.id;
    const first = el('div', 'crit', r.head ? '' : r.total ? 'Total' : r.item.text);
    const cells = columns.map((c) => {
      const cell = el('div', `cell${block.pick === c.id ? ' picked' : ''}`);
      cell.dataset.column = c.id;
      if (r.head) {
        cell.append(el('span', 'opt', c.name));
        if (block.pick === c.id) cell.append(el('span', 'badge', 'Picked'));
      } else if (r.total) {
        cell.append(el('b', 'sum', String(Number(totals[c.id].toFixed(1)))));
      } else {
        const value = r.item.cells?.[c.id];
        if (typeof value === 'number') {
          const chip = el('span', 'score', String(value));
          const step = Math.max(0, Math.min(RAMP.length - 1, Math.round((value / scale) * (RAMP.length - 1))));
          chip.style.background = RAMP[step];
          chip.classList.toggle('dark', step >= 3);
          cell.append(chip);
        } else if (value) cell.append(el('span', 'words', value));
        else cell.append(el('span', 'none', '—'));
      }
      return cell;
    });
    if (!columns.length && r.head) cells.push(el('div', 'cell none', 'No options yet'));
    row.replaceChildren(first, ...cells);
    if (r.item) out.set(r.item.id, row);
  }, { instant });
  body.querySelector(':scope > .blk-empty')?.remove();
  if (!block.items.length) body.append(empty(block, link));
  return out;
}

// --- matrix: a 2x2 -----------------------------------------------------------------------------------------------------

function drawMatrix(body, block, { link, instant, d }) {
  let box = body.querySelector(':scope > .matrix');
  if (!box) {
    box = el('div', 'matrix');
    box.append(el('div', 'yaxis'), el('div', 'quads'), el('div', 'xaxis'));
    for (const q of ['tl', 'tr', 'bl', 'br']) {
      const quad = el('div', 'quad');
      quad.dataset.q = q;
      quad.append(el('span', 'qname'), el('div', 'chips'));
      box.querySelector('.quads').append(quad);
    }
    body.append(box);
  }
  const x = block.x || { low: 'Low', high: 'High' };
  const y = block.y || { low: 'Low', high: 'High' };
  const yaxis = box.querySelector('.yaxis');
  yaxis.replaceChildren(el('span', 'hi', y.high), el('span', 'arrow'), el('span', 'lo', y.low));
  const xaxis = box.querySelector('.xaxis');
  xaxis.replaceChildren(el('span', 'lo', x.low), el('span', 'arrow'), el('span', 'hi', x.high));
  const out = new Map();
  for (const quad of box.querySelectorAll('.quad')) {
    const q = quad.dataset.q;
    quad.querySelector('.qname').textContent = block.quadrants?.[q] || '';
    const chips = keyed(quad.querySelector('.chips'), block.items.filter((i) => i.quadrant === q), (i) => i.id, () => el('span', 'chip'),
      (chip, item) => { chip.dataset.id = item.id; chip.textContent = item.text; }, { instant });
    for (const [id, chip] of chips) out.set(id, chip);
  }
  // An item with no quadrant yet waits under the 2x2.
  let loose = body.querySelector(':scope > .loose');
  const unplaced = block.items.filter((i) => !['tl', 'tr', 'bl', 'br'].includes(i.quadrant));
  if (unplaced.length && !loose) loose = body.appendChild(el('div', 'loose'));
  if (loose) {
    const chips = keyed(loose, unplaced, (i) => i.id, () => el('span', 'chip'), (chip, item) => { chip.dataset.id = item.id; chip.textContent = item.text; },
      { instant });
    for (const [id, chip] of chips) out.set(id, chip);
    if (!unplaced.length) loose.remove();
  }
  body.querySelector(':scope > .blk-empty')?.remove();
  if (!block.items.length) {
    const hint = empty(block, link);
    hint.classList.add('over');
    body.append(hint);
  }
  box.style.setProperty('--d', d);
  return out;
}

// --- mindmap: a topic and its branches ---------------------------------------------------------------------------------

// A mind map with room to spare is drawn bigger, up to this much.
const MIND_ZOOM = 1.45;

function drawMindmap(body, block, { w, h, instant, d, link }) {
  const stage = stageOf(body);
  const byId = new Map(block.items.map((i) => [i.id, i]));
  const isBranch = (i) => !i.parent || !byId.has(i.parent);
  const top = block.items.filter(isBranch);
  const color = new Map(top.map((b, i) => [b.id, BRANCHES[i % BRANCHES.length]]));
  const depth = (item) => {
    let n = 0;
    for (let at = item; at.parent && byId.has(at.parent) && n < 6; at = byId.get(at.parent)) n += 1;
    return n;
  };
  // Each branch with what hangs from it, depth first.
  const family = (branch) => {
    const out = [];
    const walk = (id) => {
      for (const child of block.items.filter((i) => i.parent === id)) {
        out.push(child);
        walk(child.id);
      }
    };
    walk(branch.id);
    return out;
  };
  const center = { id: `${block.id}:center`, text: block.title, center: true };
  const nodes = keyed(stage.layer, [center, ...block.items], (i) => i.id, () => el('div', 'mnode'), (node, item) => {
    node.dataset.id = item.center ? block.id : item.id;
    node.textContent = item.text;
    node.dataset.level = item.center ? 'center' : isBranch(item) ? 'branch' : 'leaf';
    node.style.setProperty('--c', item.center ? '' : color.get(branchOf(block, item).id) || '');
  }, { instant });
  const hub = nodes.get(center.id);
  if (!block.items.length) {
    stage.node.style.setProperty('--u', `${d}px`);
    hub.style.maxWidth = `${Math.round(Math.min(280 * d, w * 0.4))}px`;
    put(hub, (w - hub.offsetWidth) / 2, (h - hub.offsetHeight) / 2);
    stage.lines.replaceChildren();
    if (!body.querySelector(':scope > .blk-empty')) body.append(Object.assign(empty(block, link), { className: 'blk-empty under' }));
    return new Map();
  }
  body.querySelector(':scope > .blk-empty')?.remove();
  // Where everything goes at scale `u`: measured, not yet moved, so a second look at a bigger scale never shows.
  const plan = (u) => {
    stage.node.style.setProperty('--u', `${u}px`);
    hub.style.maxWidth = `${Math.round(Math.min(280 * u, w * 0.3))}px`;
    const cs = { w: hub.offsetWidth, h: hub.offsetHeight };
    const cx = w / 2;
    const cy = h / 2;
    const puts = [[hub, cx - cs.w / 2, cy - cs.h / 2]];
    const lines = [];
    let [minY, maxY, minX, maxX] = [cy - cs.h / 2, cy + cs.h / 2, cx - cs.w / 2, cx + cs.w / 2];
    // Branches alternate right and left; each side's width is shared by its branches and what hangs from them.
    const side = Math.max(120 * u, (w - cs.w) / 2 - 6 * u);
    const reach = Math.max(36 * u, Math.min(96 * u, side * 0.14));
    const twig = 34 * u;
    [top.filter((_, i) => i % 2 === 0), top.filter((_, i) => i % 2 === 1)].forEach((branches, s) => {
      const dir = s === 0 ? 1 : -1;
      const leafy = branches.some((b) => family(b).length);
      const branchMax = leafy ? Math.min(230 * u, (side - reach - twig) * 0.46) : Math.min(300 * u, side - reach);
      const stacks = branches.map((branch) => {
        nodes.get(branch.id).style.maxWidth = `${Math.round(branchMax)}px`;
        const kids = family(branch);
        for (const kid of kids) {
          const indent = (depth(kid) - 1) * 20 * u;
          nodes.get(kid.id).style.maxWidth = `${Math.round(Math.max(80 * u, side - reach - branchMax - twig - indent))}px`;
        }
        return { branch, kids };
      });
      for (const st of stacks) {
        st.kidsH = st.kids.reduce((sum, k) => sum + nodes.get(k.id).offsetHeight + 6 * u, -6 * u);
        st.height = Math.max(nodes.get(st.branch.id).offsetHeight, st.kidsH);
      }
      const gap = 18 * u;
      const total = stacks.reduce((sum, st) => sum + st.height, 0) + (stacks.length - 1) * gap;
      let y = cy - total / 2;
      minY = Math.min(minY, y);
      maxY = Math.max(maxY, y + total);
      for (const st of stacks) {
        const bn = nodes.get(st.branch.id);
        const [bw, bh] = [bn.offsetWidth, bn.offsetHeight];
        const bx = dir > 0 ? cx + cs.w / 2 + reach : cx - cs.w / 2 - reach - bw;
        const by = y + st.height / 2 - bh / 2;
        puts.push([bn, bx, by]);
        minX = Math.min(minX, bx);
        maxX = Math.max(maxX, bx + bw);
        const c = color.get(st.branch.id);
        const from = [cx + dir * (cs.w / 2 - 6 * u), cy];
        const to = [dir > 0 ? bx : bx + bw, by + bh / 2];
        const mid = (from[0] + to[0]) / 2;
        lines.push({ key: `m:${st.branch.id}`, cls: 'twig', color: c,
          d: `M ${from[0]} ${from[1]} C ${mid} ${from[1]}, ${mid} ${to[1]}, ${to[0]} ${to[1]}` });
        let ky = y + st.height / 2 - st.kidsH / 2;
        const at = new Map([[st.branch.id, { x: bx, y: by, w: bw, h: bh }]]);
        for (const kid of st.kids) {
          const kn = nodes.get(kid.id);
          const [kw, kh] = [kn.offsetWidth, kn.offsetHeight];
          const indent = (depth(kid) - 1) * 20 * u;
          const kx = dir > 0 ? bx + bw + twig + indent : bx - twig - indent - kw;
          puts.push([kn, kx, ky]);
          minX = Math.min(minX, kx);
          maxX = Math.max(maxX, kx + kw);
          at.set(kid.id, { x: kx, y: ky, w: kw, h: kh });
          const p = at.get(kid.parent);
          const ex = dir > 0 ? kx : kx + kw;
          const ey = ky + kh / 2;
          let path;
          if (kid.parent === st.branch.id) {
            const px = dir > 0 ? p.x + p.w : p.x;
            const py = p.y + p.h / 2;
            const m = (px + ex) / 2;
            path = `M ${px} ${py} C ${m} ${py}, ${m} ${ey}, ${ex} ${ey}`;
          } else {
            const px = dir > 0 ? p.x + 10 * u : p.x + p.w - 10 * u;
            path = `M ${px} ${p.y + p.h} L ${px} ${ey} L ${ex} ${ey}`;
          }
          lines.push({ key: `m:${kid.id}`, cls: 'twig thin', color: c, d: path });
          ky += kh + 6 * u;
        }
        y += st.height + gap;
      }
    });
    return { puts, lines, height: maxY - minY, width: maxX - minX };
  };
  let made = plan(d);
  // Plenty of room: the same map, bigger, as far as the block's height and width allow.
  const zoom = Math.min(MIND_ZOOM, (h * 0.86) / Math.max(1, made.height), (w * 0.96) / Math.max(1, made.width));
  if (zoom > 1.08) made = plan(d * zoom);
  for (const [node, x, y] of made.puts) put(node, x, y);
  drawLines(stage, made.lines, instant);
  return nodes;
}

// --- stats: a few key numbers ------------------------------------------------------------------------------------------

// A key number may also have a target, drawn as a meter of how far along it is, and its recent values, drawn as a
// sparkline: a scorecard.
function drawStats(body, block, { link, instant, d }) {
  let row = body.querySelector(':scope > .stats');
  if (!row) row = body.appendChild(el('div', 'stats'));
  const tiles = keyed(row, block.items, (i) => i.id, () => {
    const tile = el('div', 'stat');
    const meter = el('div', 'meter');
    meter.append(el('span', 'track'), el('span', 'words'));
    meter.querySelector('.track').append(el('i'));
    const spark = svg('svg', { class: 'spark', 'aria-hidden': 'true' });
    spark.append(svg('path', { class: 'spark-line' }), svg('circle', { class: 'spark-end', r: '4' }));
    tile.append(el('span', 'label'), el('b', 'value'), el('span', 'note'), meter, spark);
    return tile;
  }, (tile, item) => {
    tile.dataset.id = item.id;
    tile.dataset.trend = item.trend || '';
    tile.querySelector('.label').textContent = item.text;
    tile.querySelector('.value').textContent = item.value || '—';
    const note = tile.querySelector('.note');
    // A note about the target ("against a target of $4.5M") is left to the meter, which says it.
    const words = item.target && /\btarget\b/i.test(item.note || '') ? '' : item.note || '';
    note.replaceChildren(...(item.trend ? [el('i', `trend ${item.trend}`)] : []), words);
    note.hidden = !item.trend && !words;
    // How far along to the target: the meter fills to it, green once it is met.
    const meter = tile.querySelector('.meter');
    meter.hidden = !item.target;
    if (item.target) {
      const { share, words: said } = toTarget(item.value, item.target);
      meter.classList.toggle('met', share !== null && share >= 1);
      meter.querySelector('i').style.width = `${Math.round(Math.max(0, Math.min(1, share ?? 0)) * 100)}%`;
      meter.querySelector('.words').textContent = said;
    }
    const spark = tile.querySelector('.spark');
    const points = (item.points || []).filter((v) => Number.isFinite(v));
    spark.style.display = points.length > 1 ? '' : 'none';
    if (points.length > 1) {
      // Drawn at the tile's own size, so the end dot stays round.
      const W = Math.max(40, spark.clientWidth || 200);
      const H = Math.max(16, spark.clientHeight || 38 * d);
      const lo = Math.min(...points);
      const hi = Math.max(...points);
      const r = 4 * d;
      const at = (v, i) => [r + (i / (points.length - 1)) * (W - 2 * r), H - r - ((v - lo) / (hi - lo || 1)) * (H - 2 * r)];
      spark.setAttribute('viewBox', `0 0 ${W} ${H}`);
      spark.querySelector('path').setAttribute('d', points.map((v, i) => `${i ? 'L' : 'M'} ${at(v, i).join(' ')}`).join(' '));
      const [x, y] = at(points.at(-1), points.length - 1);
      const end = spark.querySelector('circle');
      end.setAttribute('cx', x);
      end.setAttribute('cy', y);
      end.setAttribute('r', String(Math.round(r * 10) / 10));
    }
  }, { instant });
  body.querySelector(':scope > .blk-empty')?.remove();
  if (!block.items.length) body.append(empty(block, link));
  // A number wider than its tile ("2.1 days" in a narrow one) gets smaller, down to about half, before it is cut.
  requestAnimationFrame(() => fitValues(row));
  if (!row.watch && typeof ResizeObserver === 'function') {
    row.watch = new ResizeObserver(() => fitValues(row));
    row.watch.observe(row);
  }
  return tiles;
}

function fitValues(row) {
  for (const value of row.querySelectorAll('.value')) {
    value.style.removeProperty('--fit');
    if (value.scrollWidth > value.clientWidth + 1) {
      value.style.setProperty('--fit', Math.max(0.55, (value.clientWidth / value.scrollWidth) * 0.97).toFixed(3));
    }
  }
}


// --- chart as a donut or a pie: one whole and its parts ----------------------------------------------------------------

// The parts drawn: those with a number above zero, in the order said; past six, the smallest fold into "Other" so no
// color is ever made up.
function partsOf(block) {
  const series = (block.columns || [])[0];
  const all = block.items.map((item) => ({ item, v: series ? numberOf(item.cells?.[series.id]) : numberOf(item.value) }))
    .filter((p) => p.v !== null && p.v > 0);
  if (all.length <= PARTS.length) return all.map((p, k) => ({ ...p, key: p.item.id, color: PARTS[k] }));
  const kept = new Set([...all].sort((a, b) => b.v - a.v).slice(0, PARTS.length - 1).map((p) => p.item.id));
  const shown = all.filter((p) => kept.has(p.item.id)).map((p, k) => ({ ...p, key: p.item.id, color: PARTS[k] }));
  const rest = all.filter((p) => !kept.has(p.item.id));
  return [...shown, { key: `${block.id}:other`, item: { id: `${block.id}:other`, text: `Other (${rest.length})` },
    v: rest.reduce((sum, p) => sum + p.v, 0), color: OTHER, other: true }];
}

function arc(cx, cy, r, inner, a0, a1) {
  const point = (rad, a) => [cx + rad * Math.cos(a), cy + rad * Math.sin(a)].map((n) => Math.round(n * 10) / 10);
  // A whole circle is drawn as two halves, so its path keeps the same commands as any other slice.
  const end = Math.min(a1, a0 + Math.PI * 2 - 1e-4);
  const large = end - a0 > Math.PI ? 1 : 0;
  const [x0, y0] = point(r, a0);
  const [x1, y1] = point(r, end);
  if (!inner) return `M ${cx} ${cy} L ${x0} ${y0} A ${r} ${r} 0 ${large} 1 ${x1} ${y1} Z`;
  const [x2, y2] = point(inner, end);
  const [x3, y3] = point(inner, a0);
  return `M ${x0} ${y0} A ${r} ${r} 0 ${large} 1 ${x1} ${y1} L ${x2} ${y2} A ${inner} ${inner} 0 ${large} 0 ${x3} ${y3} Z`;
}

function drawRound(body, block, { w, h, instant, d, link }) {
  let box = body.querySelector(':scope > .round');
  if (!box) {
    box = el('div', 'round');
    const ring = svg('svg', { class: 'ring', 'aria-hidden': 'true' });
    box.append(ring, el('div', 'middle'), el('ol', 'parts'));
    body.append(box);
  }
  body.querySelector(':scope > .blk-empty')?.remove();
  const parts = partsOf(block);
  if (!block.items.length) body.append(empty(block, link));
  const total = parts.reduce((sum, p) => sum + p.v, 0);
  const pie = block.style === 'pie';
  // The ring on the left as big as the block allows; the parts, named, beside it.
  const size = Math.max(120, Math.min(h - 8 * d, w * 0.48, 420 * d));
  const r = size / 2;
  const inner = pie ? 0 : r * 0.6;
  const ring = box.querySelector('.ring');
  ring.setAttribute('width', size);
  ring.setAttribute('height', size);
  ring.setAttribute('viewBox', `0 0 ${size} ${size}`);
  put(ring, 0, (h - size) / 2);
  let at = -Math.PI / 2;
  const slices = parts.map((p) => {
    const a0 = at;
    at += (p.v / (total || 1)) * Math.PI * 2;
    return { ...p, d: arc(r, r, r - 2 * d, inner, a0, at) };
  });
  const out = new Map();
  keyed(ring, slices, (p) => p.key, () => svg('path', { class: 'slice' }), (path, p) => {
    path.dataset.id = p.item.id;
    path.style.fill = p.color;
    path.style.stroke = 'var(--panel)';
    path.style.strokeWidth = `${3 * d}px`;
    pathTo(path, p.d, instant);
  }, { selector: ':scope > path[data-key]', instant });
  const middle = box.querySelector('.middle');
  middle.hidden = pie || !parts.length;
  middle.replaceChildren(el('b', '', shown(total, block.unit)), el('span', '', unitWords(block.unit) || 'in all'));
  middle.style.width = `${Math.round(inner * 2 - 16 * d)}px`;
  put(middle, r - (inner - 8 * d), (h - size) / 2 + r);
  const list = box.querySelector('.parts');
  list.style.left = `${Math.round(size + 34 * d)}px`;
  list.style.width = `${Math.round(Math.max(120, w - size - 34 * d))}px`;
  const rows = keyed(list, [...parts, ...block.items.filter((i) => !parts.some((p) => p.item.id === i.id) && !parts.some((p) => p.other))
    .map((item) => ({ key: item.id, item, v: null, color: 'transparent' }))], (p) => p.key, () => {
    const row = el('li', 'part');
    row.append(el('i', 'swatch'), el('span', 'name'), el('b', 'num'), el('span', 'pct'));
    return row;
  }, (row, p) => {
    row.dataset.id = p.item.id;
    row.querySelector('.swatch').style.background = p.color;
    row.querySelector('.name').textContent = p.item.text;
    row.querySelector('.num').textContent = p.v === null ? '—' : shown(p.v, block.unit);
    row.querySelector('.pct').textContent = p.v === null || !total ? '' : shownShare(p.v / total);
    row.classList.toggle('missing', p.v === null);
  }, { selector: ':scope > li[data-key]', instant });
  for (const [key, row] of rows) out.set(key, row);
  return out;
}

// --- chart as a heatmap: a grid of numbers, each shaded by its size -----------------------------------------------------

function drawHeat(body, block, { link, instant, d }) {
  const series = seriesOf(block);
  let grid = body.querySelector(':scope > .heat');
  if (!grid) grid = body.appendChild(el('div', 'heat'));
  grid.style.gridTemplateColumns = `minmax(${Math.round(120 * d)}px, 1.1fr) repeat(${series.length}, minmax(0, 1fr))`;
  const values = block.items.flatMap((i) => series.map((s) => valueIn(i, s))).filter((v) => v !== null);
  const lo = Math.min(...values);
  const hi = Math.max(...values);
  const step = (v) => (hi > lo ? Math.round(((v - lo) / (hi - lo)) * (HEAT.length - 1)) : Math.floor(HEAT.length / 2));
  const rows = [{ key: 'head', head: true }, ...block.items.map((item) => ({ key: item.id, item }))];
  const out = new Map();
  keyed(grid, rows, (r) => r.key, () => el('div', 'hrow'), (row, r) => {
    row.classList.toggle('head', Boolean(r.head));
    if (r.item) row.dataset.id = r.item.id;
    const cells = series.map((s) => {
      if (r.head) return el('div', 'hcol', s.name);
      const v = valueIn(r.item, s);
      const cell = el('div', 'hcell', v === null ? '—' : shown(v, block.unit));
      if (v !== null) {
        cell.style.background = HEAT[step(v)];
        cell.classList.toggle('dark', step(v) >= 3);
      } else cell.classList.add('none');
      return cell;
    });
    row.replaceChildren(el('div', 'hname', r.head ? '' : r.item.text), ...cells);
    if (r.item) out.set(r.item.id, row);
  }, { instant });
  body.querySelector(':scope > .blk-empty')?.remove();
  if (!block.items.length) body.append(empty(block, link));
  return out;
}

// --- funnel: stages that lose people on the way ---------------------------------------------------------------------

function drawFunnel(body, block, { w, h, instant, d, link }) {
  const stage = stageOf(body);
  const items = block.items;
  body.querySelector(':scope > .blk-empty')?.remove();
  if (!items.length) {
    stage.layer.replaceChildren();
    stage.lines.replaceChildren();
    body.append(empty(block, link));
    return new Map();
  }
  const values = items.map((i) => numberOf(i.value));
  const counted = values.some((v) => v !== null);
  const most = Math.max(1, ...values.filter((v) => v !== null));
  // With no numbers yet, the stages still narrow, so it reads as a funnel from the first one said.
  const share = (v, i) => (counted ? (v ?? 0) / most : 1 - (i / Math.max(1, items.length - 1)) * 0.5);
  const labelW = Math.min(260 * d, w * 0.28);
  const numW = Math.min(210 * d, w * 0.24);
  const area = Math.max(80, w - labelW - numW - 32 * d);
  const gap = 12 * d;
  const rowH = Math.max(34 * d, Math.min(78 * d, (h - gap * (items.length - 1)) / items.length));
  const top = Math.max(0, (h - items.length * rowH - gap * (items.length - 1)) / 2);
  const color = (i) => STAGES[Math.round((i / Math.max(1, items.length - 1)) * Math.min(STAGES.length - 1, items.length + 1))];
  const boxes = items.map((item, i) => {
    const bw = Math.max(10 * d, share(values[i], i) * area);
    return { item, i, x: labelW + 16 * d + (area - bw) / 2, y: top + i * (rowH + gap), w: bw, h: rowH };
  });
  const parts = keyed(stage.layer, boxes, (b) => b.item.id, () => {
    const row = el('div', 'fun');
    row.append(el('span', 'fname'), el('i', 'fbar'), el('span', 'fnum'));
    row.querySelector('.fnum').append(el('b'), el('small'));
    return row;
  }, (row, b) => {
    row.dataset.id = b.item.id;
    row.style.width = `${Math.round(w)}px`;
    row.style.height = `${Math.round(b.h)}px`;
    put(row, 0, b.y);
    const name = row.querySelector('.fname');
    name.textContent = b.item.text;
    name.style.width = `${Math.round(labelW)}px`;
    const bar = row.querySelector('.fbar');
    bar.style.left = `${Math.round(b.x)}px`;
    bar.style.width = `${Math.round(b.w)}px`;
    bar.style.background = color(b.i);
    const num = row.querySelector('.fnum');
    num.style.width = `${Math.round(numW)}px`;
    num.querySelector('b').textContent = values[b.i] === null ? (counted ? '—' : '') : shown(values[b.i], block.unit);
    const before = b.i > 0 ? values[b.i - 1] : null;
    num.querySelector('small').textContent = before && values[b.i] !== null ? `${shownShare(values[b.i] / before)} of ${items[b.i - 1].text}` : '';
  }, { instant });
  // Between two stages, the drop drawn as the funnel's narrowing wall.
  const walls = boxes.slice(1).map((b, k) => {
    const a = boxes[k];
    return { key: `wall:${a.item.id}>${b.item.id}`, cls: 'wall',
      d: `M ${a.x} ${a.y + a.h} L ${a.x + a.w} ${a.y + a.h} L ${b.x + b.w} ${b.y} L ${b.x} ${b.y} Z` };
  });
  keyed(stage.lines, walls, (l) => l.key, () => svg('path'), (path, l) => {
    path.setAttribute('class', l.cls);
    pathTo(path, l.d, true);
  }, { selector: ':scope > path[data-key]', instant });
  return parts;
}

// --- roadmap: work over date ranges, in lanes ----------------------------------------------------------------------------

const lanesOf = (block) => [...new Set(block.items.map((i) => i.lane || ''))];

function drawRoadmap(body, block, { w, h, instant, d, link }) {
  const stage = stageOf(body);
  const today = new Date();
  const now = Math.floor(today.getTime() / 86400000);
  const placed = block.items.map((item) => ({ item, span: spanOf(item, today) })).filter((x) => x.span);
  body.querySelector(':scope > .blk-empty')?.remove();
  if (!placed.length) {
    stage.layer.replaceChildren();
    stage.lines.replaceChildren();
    stage.labels.replaceChildren();
    body.append(empty(block, link));
    return new Map();
  }
  // The months shown: from the first start to the last end, whole months, with today when it is near.
  let lo = Math.min(...placed.map((x) => x.span.from));
  let hi = Math.max(...placed.map((x) => x.span.to));
  if (now >= lo - 45 && now <= hi + 45) {
    lo = Math.min(lo, now);
    hi = Math.max(hi, now);
  }
  const first = new Date(lo * 86400000);
  const months = [];
  for (let y = first.getUTCFullYear(), m = first.getUTCMonth(); ; m++) {
    const at = Date.UTC(y, m, 1) / 86400000;
    if (at > hi) break;
    months.push(at);
  }
  lo = months[0];
  const last = new Date(months.at(-1) * 86400000);
  hi = Date.UTC(last.getUTCFullYear(), last.getUTCMonth() + 1, 1) / 86400000;
  const lanes = lanesOf({ items: placed.map((x) => x.item) });
  const named = lanes.some(Boolean);
  const labelW = named ? Math.min(170 * d, w * 0.18) : 0;
  const plotW = Math.max(100, w - labelW);
  const xOf = (day) => labelW + ((day - lo) / (hi - lo)) * plotW;
  const axisH = 34 * d;
  // A mark every month, or every second or third when months are too narrow for their names.
  const monthW = plotW / months.length;
  const every = [1, 2, 3].find((n) => monthW * n >= 76 * d) || 3;
  const quarterly = every === 3;
  const marks = months.filter((at, k) => (quarterly ? new Date(at * 86400000).getUTCMonth() % 3 === 0 : k % every === 0));
  const yearShown = new Set();
  const ticksOf = marks.map((at) => {
    const date = new Date(at * 86400000);
    const year = date.getUTCFullYear();
    const label = quarterly ? `Q${Math.floor(date.getUTCMonth() / 3) + 1}` : dayWords(at, { month: true });
    const withYear = !yearShown.has(year);
    yearShown.add(year);
    return { key: `m:${at}`, at, label: withYear && monthW * every >= 110 * d ? `${label} ${year}` : withYear ? `${label} ’${String(year).slice(2)}` : label };
  });
  // Each bar where its dates are, its words inside when they fit, else just after it (before it near the right edge).
  // Bars, words and all, are packed into as few rows of their lane as keep any two from touching.
  const textW = (text) => text.length * 10.5 * d + 22 * d;
  const bars = [...placed].sort((a, b) => a.span.from - b.span.from).map((x) => {
    const left = xOf(x.span.from);
    const width = Math.max(10 * d, xOf(x.span.to + 1) - left);
    const fits = textW(x.item.text) <= width;
    const before = !fits && left + width + 8 * d + textW(x.item.text) > w;
    const from = before ? left - 8 * d - textW(x.item.text) : left;
    const to = fits || before ? left + width : left + width + 8 * d + textW(x.item.text);
    return { ...x, left, width, fits, before, from, to };
  });
  const rowsOf = new Map(lanes.map((lane) => [lane, []]));
  for (const bar of bars) {
    const rows = rowsOf.get(bar.item.lane || '');
    let row = rows.findIndex((end) => end + 6 * d <= bar.from);
    if (row < 0) row = rows.push(0) - 1;
    rows[row] = bar.to;
    bar.row = row;
  }
  const rowCount = [...rowsOf.values()].reduce((sum, rows) => sum + rows.length, 0);
  const pad = 10 * d;
  const barH = Math.max(26 * d, Math.min(44 * d, (h - axisH - 30 * d - lanes.length * pad * 2 - rowCount * 8 * d) / Math.max(1, rowCount)));
  let y = axisH;
  const bands = lanes.map((lane, k) => {
    const height = rowsOf.get(lane).length * (barH + 8 * d) - 8 * d + pad * 2;
    const band = { key: `lane:${k}:${lane}`, lane, y, h: height, k };
    y += height;
    return band;
  });
  const bandOf = new Map(bands.map((b) => [b.lane, b]));
  const out = new Map();
  keyed(stage.layer, [...bands.map((b) => ({ key: b.key, band: b })), ...ticksOf.map((t) => ({ key: t.key, tick: t })),
    ...bars.map((bar) => ({ key: bar.item.id, bar }))], (p) => p.key, (p) => {
    if (p.band) {
      const band = el('div', 'rm-lane');
      band.append(el('span', 'rm-name'));
      return band;
    }
    if (p.tick) return el('span', 'rm-tick');
    const bar = el('div', 'rm-bar');
    bar.append(el('span', 'rm-text'));
    return bar;
  }, (node, p) => {
    if (p.band) {
      node.querySelector('.rm-name').textContent = p.band.lane;
      node.classList.toggle('odd', p.band.k % 2 === 1);
      node.style.width = `${Math.round(w)}px`;
      node.style.height = `${Math.round(p.band.h)}px`;
      node.style.setProperty('--label', `${Math.round(labelW)}px`);
      put(node, 0, p.band.y);
      return;
    }
    if (p.tick) {
      node.textContent = p.tick.label;
      node.style.height = `${Math.round(y)}px`;
      put(node, xOf(p.tick.at), 0);
      return;
    }
    const { item, left, width, fits, before, row } = p.bar;
    node.dataset.id = item.id;
    node.dataset.status = item.status || '';
    node.style.width = `${Math.round(width)}px`;
    node.style.height = `${Math.round(barH)}px`;
    put(node, left, bandOf.get(item.lane || '').y + pad + row * (barH + 8 * d));
    node.querySelector('.rm-text').textContent = item.text;
    node.classList.toggle('out', !fits);
    node.classList.toggle('before', before);
    out.set(item.id, node);
  }, { instant });
  const lines = [];
  if (now >= lo && now <= hi) {
    lines.push({ key: 'today', cls: 'rm-today', d: `M ${xOf(now)} ${axisH - 6 * d} L ${xOf(now)} ${y}` });
  }
  drawLines(stage, lines, instant);
  keyed(stage.labels, now >= lo && now <= hi ? [{ key: 'today' }] : [], (l) => l.key, () => el('span', 'rm-now', 'Today'), (pill) => {
    put(pill, xOf(now), y + 4 * d);
  }, { instant });
  return out;
}

// --- tree: a hierarchy, top down -------------------------------------------------------------------------------------

function drawTree(body, block, { w, h, instant, d, link }) {
  const stage = stageOf(body);
  const items = block.items;
  body.querySelector(':scope > .blk-empty')?.remove();
  if (!items.length) {
    stage.layer.replaceChildren();
    stage.lines.replaceChildren();
    body.append(empty(block, link));
    return new Map();
  }
  const byId = new Map(items.map((i) => [i.id, i]));
  const kids = (id) => items.filter((i) => i.parent === id && byId.has(id));
  const roots = items.filter((i) => !i.parent || !byId.has(i.parent));
  const depthOf = (item) => {
    let n = 0;
    for (let at = item; at.parent && byId.has(at.parent) && n < 12; at = byId.get(at.parent)) n += 1;
    return n;
  };
  // Each branch under the top keeps one color down its whole line; past six branches, the rest go plain (never a made-up
  // or repeated color).
  const firsts = items.filter((i) => depthOf(i) === 1);
  const topOf = (item) => {
    let at = item;
    while (depthOf(at) > 1) at = byId.get(at.parent);
    return at;
  };
  const branchColor = new Map(items.filter((i) => depthOf(i) >= 1).map((i) => [i.id, BRANCHES[firsts.indexOf(topOf(i))]])
    .filter(([, color]) => color));
  const nodes = keyed(stage.layer, items, (i) => i.id, () => {
    const node = el('div', 'tnode');
    node.append(el('b', 'tname'), el('span', 'trole'));
    return node;
  }, (node, item) => {
    node.dataset.id = item.id;
    node.dataset.level = depthOf(item) === 0 ? 'root' : 'kid';
    node.style.setProperty('--c', branchColor.get(item.id) || 'var(--ink)');
    node.querySelector('.tname').textContent = item.text;
    const role = node.querySelector('.trole');
    role.textContent = item.note || '';
    role.hidden = !item.note;
  }, { instant });
  // Slots across: a leaf takes one; a parent the sum of its children's. Too many for the width, and a parent whose
  // children are all leaves stacks them under itself instead, an org chart's usual way.
  const plan = (stack) => {
    const stacked = new Set(stack ? items.filter((i) => kids(i.id).length && kids(i.id).every((k) => !kids(k.id).length)).map((i) => i.id) : []);
    const slots = new Map();
    const count = (item) => {
      const children = stacked.has(item.id) ? [] : kids(item.id);
      const n = children.length ? children.reduce((sum, k) => sum + count(k), 0) : 1;
      slots.set(item.id, n);
      return n;
    };
    const total = roots.reduce((sum, r) => sum + count(r), 0);
    return { stacked, slots, total };
  };
  let layout = plan(false);
  if (w / layout.total < 170 * d) layout = plan(true);
  const slotW = w / Math.max(1, layout.total);
  const nodeW = Math.max(110 * d, Math.min(250 * d, slotW - 18 * d));
  for (const item of items) {
    const node = nodes.get(item.id);
    node.style.width = `${Math.round(layout.stacked.has(item.parent) ? nodeW - 22 * d : nodeW)}px`;
  }
  const height = (id) => nodes.get(id).offsetHeight;
  const levels = Math.max(...items.map((i) => (layout.stacked.has(i.parent) ? -1 : depthOf(i)))) + 1;
  const rowH = Math.max(...items.filter((i) => !layout.stacked.has(i.parent)).map((i) => height(i.id)));
  const stackH = (id) => kids(id).reduce((sum, k) => sum + height(k.id) + 8 * d, 0);
  const tallestStack = Math.max(0, ...[...layout.stacked].map(stackH));
  const gapY = Math.max(26 * d, Math.min(64 * d, (h - levels * rowH - tallestStack) / Math.max(1, levels)));
  const where = new Map();
  let cursor = 0;
  const place = (item, depth) => {
    const children = layout.stacked.has(item.id) ? [] : kids(item.id);
    let cx;
    if (children.length) {
      const centers = children.map((k) => place(k, depth + 1));
      cx = (centers[0] + centers.at(-1)) / 2;
    } else {
      cx = (cursor + 0.5) * slotW;
      cursor += 1;
    }
    const y = depth * (rowH + gapY);
    where.set(item.id, { x: cx - nodeW / 2, y, w: nodeW, h: height(item.id) });
    if (layout.stacked.has(item.id)) {
      let ky = y + height(item.id) + 14 * d;
      for (const kid of kids(item.id)) {
        where.set(kid.id, { x: cx - nodeW / 2 + 22 * d, y: ky, w: nodeW - 22 * d, h: height(kid.id), stacked: true });
        ky += height(kid.id) + 8 * d;
      }
    }
    return cx;
  };
  for (const root of roots) place(root, 0);
  const bottom = Math.max(...[...where.values()].map((b) => b.y + b.h));
  const shift = Math.max(0, (h - bottom) / 2);
  for (const [id, b] of where) put(nodes.get(id), b.x, b.y + shift);
  const lines = [];
  for (const item of items) {
    const parent = byId.get(item.parent);
    if (!parent || !where.has(item.id) || !where.has(parent.id)) continue;
    const a = where.get(parent.id);
    const b = where.get(item.id);
    if (b.stacked) {
      const x = a.x + 10 * d;
      lines.push({ key: `t:${item.id}`, cls: 'twig', d: `M ${x} ${a.y + a.h + shift} L ${x} ${b.y + b.h / 2 + shift} L ${b.x} ${b.y + b.h / 2 + shift}` });
    } else {
      const mid = a.y + a.h + (b.y - a.y - a.h) / 2 + shift;
      lines.push({ key: `t:${item.id}`, cls: 'twig', d: `M ${a.x + a.w / 2} ${a.y + a.h + shift} L ${a.x + a.w / 2} ${mid} L ${b.x + b.w / 2} ${mid} L ${b.x + b.w / 2} ${b.y + shift}` });
    }
  }
  drawLines(stage, lines, instant);
  return nodes;
}

// --- swimlane: steps in order, each in the lane of who does it ----------------------------------------------------------

function drawSwimlane(body, block, { w, h, instant, d, link }) {
  const stage = stageOf(body);
  const items = block.items;
  body.querySelector(':scope > .blk-empty')?.remove();
  if (!items.length) {
    stage.layer.replaceChildren();
    stage.lines.replaceChildren();
    stage.labels.replaceChildren();
    body.append(empty(block, link));
    return new Map();
  }
  const lanes = lanesOf(block);
  const labelW = Math.min(130 * d, w * 0.15);
  const colW = (w - labelW - 8 * d) / items.length;
  const nodeW = Math.max(80 * d, Math.min(230 * d, colW - 22 * d));
  const laneH = h / lanes.length;
  const laneOf = new Map(lanes.map((lane, k) => [lane, k]));
  const nodes = keyed(stage.layer, [...lanes.map((lane, k) => ({ key: `lane:${k}:${lane}`, lane, k })), ...items.map((item) => ({ key: item.id, item }))],
    (p) => p.key, (p) => {
      if (!p.item) {
        const band = el('div', 'sl-lane');
        band.append(el('span', 'sl-name'));
        return band;
      }
      const node = el('div', 'fnode');
      node.append(el('b', 'num'), el('span', 'txt'));
      return node;
    }, (node, p) => {
      if (!p.item) {
        node.querySelector('.sl-name').textContent = p.lane;
        node.classList.toggle('odd', p.k % 2 === 1);
        node.style.width = `${Math.round(w)}px`;
        node.style.height = `${Math.round(laneH - 4 * d)}px`;
        node.style.setProperty('--label', `${Math.round(labelW)}px`);
        put(node, 0, p.k * laneH);
        return;
      }
      const { item } = p;
      node.dataset.id = item.id;
      node.dataset.shape = item.shape || 'step';
      node.style.width = `${Math.round(nodeW)}px`;
      node.querySelector('.num').textContent = String(items.slice(0, items.indexOf(item) + 1).filter((i) => !i.shape || i.shape === 'step').length);
      node.querySelector('.txt').textContent = item.text;
    }, { instant });
  const box = new Map();
  items.forEach((item, i) => {
    const node = nodes.get(item.id);
    const nh = node.offsetHeight;
    const x = labelW + 8 * d + colW * i + (colW - nodeW) / 2;
    const y = laneOf.get(item.lane || '') * laneH + (laneH - nh) / 2;
    put(node, x, y);
    box.set(item.id, { x, y, w: nodeW, h: nh });
  });
  const where = new Map(items.map((item, n) => [item.id, n]));
  const known = (block.links || []).filter((l) => where.has(l.from) && where.has(l.to));
  const next = (l) => where.get(l.to) === where.get(l.from) + 1;
  const said = new Map(known.filter(next).map((l) => [l.to, l.label]));
  const lines = [];
  for (let i = 1; i < items.length; i++) {
    const a = box.get(items[i - 1].id);
    const b = box.get(items[i].id);
    const mid = (a.x + a.w + b.x) / 2;
    const ay = a.y + a.h / 2;
    const by = b.y + b.h / 2;
    const path = Math.abs(ay - by) < 2 ? `M ${a.x + a.w + 4} ${ay} L ${b.x - 10} ${by}`
      : `M ${a.x + a.w + 4} ${ay} L ${mid} ${ay} L ${mid} ${by} L ${b.x - 10} ${by}`;
    const label = said.get(items[i].id);
    lines.push({ key: `seq:${items[i - 1].id}>${items[i].id}`, d: path, cls: 'arrow', ...(label ? { label, at: { x: mid, y: (ay + by) / 2 } } : {}) });
  }
  // A branch or a loop back arcs under the steps it skips.
  for (const l of known.filter((x) => !next(x))) {
    const a = box.get(l.from);
    const b = box.get(l.to);
    const low = Math.max(a.y + a.h, b.y + b.h) + 30 * d;
    lines.push({ key: `link:${l.from}>${l.to}`, cls: 'arrow link', label: l.label, at: { x: (a.x + b.x + b.w) / 2, y: low - 4 * d },
      d: `M ${a.x + a.w / 2} ${a.y + a.h + 4} C ${a.x + a.w / 2} ${low}, ${b.x + b.w / 2} ${low}, ${b.x + b.w / 2} ${b.y + b.h + 10}` });
  }
  drawLines(stage, lines, instant);
  const out = new Map();
  for (const item of items) out.set(item.id, nodes.get(item.id));
  return out;
}

// --- sketch: Hermes's custom picture -----------------------------------------------------------------------------------

// The board's font inside the picture. An SVG shown as an image cannot load anything, so the font goes in it, as data;
// fetched once, and left out (the system's sans) when it cannot be.
const FONT_FILES = [400, 700].map((weight) => [weight,
  `https://cdn.jsdelivr.net/npm/@fontsource/atkinson-hyperlegible-next@5.2.7/files/atkinson-hyperlegible-next-latin-${weight}-normal.woff2`]);
let fontFaces = null;
function sketchFont() {
  fontFaces ??= Promise.all(FONT_FILES.map(async ([weight, url]) => {
    const bytes = new Uint8Array(await (await fetch(url)).arrayBuffer());
    let text = '';
    for (let i = 0; i < bytes.length; i += 0x8000) text += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
    return `@font-face{font-family:"Board";font-weight:${weight === 400 ? '100 500' : '600 900'};src:url(data:font/woff2;base64,${btoa(text)}) format("woff2")}`;
  })).then((faces) => faces.join('')).catch(() => '');
  return fontFaces;
}
// Pictures still being put on the page, so a picture of the board waits for them (board.mjs print()).
const painting = new Set();
export const sketchesDrawn = () => Promise.all([...painting]);

// The picture as an image the page shows: the SVG the room kept (svg.mjs), with the font and the board's text color
// added, from a blob. An image cannot run anything in it or load anything from anywhere.
async function paint(frame, picture) {
  const css = await sketchFont();
  const open = /^<svg\b[^>]*>/.exec(picture)?.[0];
  if (!open) return;
  const head = `${open.replace(/>$/, ' font-family="Board, Atkinson Next, system-ui, sans-serif" fill="#17202a">')}` +
    (css ? `<defs><style>${css}</style></defs>` : '');
  const url = URL.createObjectURL(new Blob([head + picture.slice(open.length)], { type: 'image/svg+xml' }));
  const image = new Image();
  image.className = 'sketch-img';
  image.alt = frame.dataset.alt || '';
  image.src = url;
  try {
    await image.decode();
  } catch {
    URL.revokeObjectURL(url);
    return;
  }
  // Only the newest picture asked for goes up; one that took longer to load than a later one is dropped.
  if (frame.picture !== picture) return URL.revokeObjectURL(url);
  const old = frame.querySelector(':scope > img.sketch-img');
  frame.prepend(image);
  if (old) {
    URL.revokeObjectURL(old.src);
    old.remove();
  }
}

function drawSketch(body, block) {
  let frame = body.querySelector(':scope > .sketch');
  if (!frame) {
    frame = el('div', 'sketch');
    const wait = el('div', 'sketch-wait');
    wait.append(el('span', 'sketch-spin'), el('b', '', 'Hermes is drawing this'), el('q'));
    frame.append(wait, el('span', 'sketch-badge', 'Redrawing'), el('p', 'sketch-failed'));
    body.append(frame);
  }
  frame.dataset.id = block.id;
  frame.dataset.alt = block.brief || block.title;
  const picture = block.svg || '';
  frame.classList.toggle('drawing', Boolean(block.drawing));
  frame.classList.toggle('has', Boolean(picture));
  frame.querySelector('.sketch-wait q').textContent = block.brief || '';
  frame.querySelector('.sketch-badge').textContent = picture ? 'Redrawing' : 'Drawing';
  const failed = frame.querySelector('.sketch-failed');
  failed.textContent = block.failed ? `Hermes could not draw this (${block.failed}). Say it again.` : '';
  failed.hidden = !block.failed;
  if (frame.picture !== picture) {
    frame.picture = picture;
    if (picture) {
      const job = paint(frame, picture).finally(() => painting.delete(job));
      painting.add(job);
    } else frame.querySelector(':scope > img.sketch-img')?.remove();
  }
  return new Map([[block.id, frame]]);
}

const DRAW = { list: drawList, flow: drawFlow, timeline: drawTimeline, chart: drawChart, table: drawTable, matrix: drawMatrix,
  mindmap: drawMindmap, stats: drawStats, funnel: drawFunnel, roadmap: drawRoadmap, tree: drawTree, swimlane: drawSwimlane,
  sketch: drawSketch };
export const DRAWN = Object.keys(DRAW);
