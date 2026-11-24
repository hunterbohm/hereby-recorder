// How much room each type of block wants, from what it holds, at the board's sizes (blocks.mjs draws them; arrange.mjs
// places them). Pure estimates: a line of text at the item size holds about `w / CHAR` characters.
//
// need(block) = { minW, idealW, maxW, minH, maxH, h(width) }: the least, best and most width it takes, the least and
// most height, and the height it wants at a width.
import { spanOf } from './model.mjs';

const CHAR = 12; // px per character of item text at the board's item size (24px Atkinson)
export const HEAD = 56; // a block's title row
export const PAD = 40; // a block's padding, top and bottom together (and left and right)
export const LIST_COLUMN = 340; // the least width of a list's column of rows
const lines = (text, width) => Math.max(1, Math.ceil((String(text || '').length * CHAR) / Math.max(60, width)));

const NEEDS = {
  // A wide list puts its rows side by side, LIST_COLUMN wide or more each (blocks.css), in reading order.
  list(block) {
    const actions = block.kind === 'actions';
    const height = (w) => {
      const columns = Math.max(1, Math.floor((w - PAD + 10) / (LIST_COLUMN + 10)));
      const inner = (w - PAD - 10 * (columns - 1)) / columns;
      const rows = block.items.map((item) => {
        const extra = (item.owner || item.due) && !actions ? 0.7 : 0;
        return 29 * (lines(item.text, inner - (actions ? 200 : 40)) + extra) + 24;
      });
      let total = 0;
      for (let i = 0; i < rows.length; i += columns) total += Math.max(...rows.slice(i, i + columns)) + 10;
      return HEAD + PAD + 10 + Math.max(60, total);
    };
    return { minW: 260, idealW: actions ? 460 : 380, maxW: actions ? 640 : 520, minH: 170, maxH: 640, h: height };
  },
  flow(block) {
    const n = Math.max(1, block.items.length);
    const links = (block.links || []).length;
    return { minW: Math.min(560, 200 * n), idealW: Math.max(520, 230 * n), maxW: 1400, minH: 210, maxH: 420,
      h: (w) => {
        const perRow = Math.max(1, Math.floor((w + 56) / (186 + 56)));
        const rows = Math.ceil(n / perRow);
        const nodeW = Math.min(250, (w - 56 * (perRow - 1)) / perRow);
        const tallest = Math.max(1, ...block.items.map((i) => lines(i.text, nodeW - 64)));
        return HEAD + PAD + rows * (56 + 30 * tallest) + (rows - 1) * 64 + (links ? 80 : 20);
      } };
  },
  timeline(block) {
    const n = Math.max(1, block.items.length);
    return { minW: Math.min(560, 190 * n), idealW: Math.max(560, 210 * n), maxW: 1400, minH: 220, maxH: 400,
      h: (w) => {
        const perRow = Math.max(1, Math.floor(w / 180));
        const rows = Math.ceil(n / perRow);
        const slot = w / Math.min(n, perRow);
        const tallest = Math.max(1, ...block.items.map((i) => lines(i.text, slot - 34)));
        return HEAD + PAD + rows * (100 + 28 * tallest) + (rows - 1) * 30;
      } };
  },
  chart(block) {
    const n = Math.max(3, block.items.length);
    const series = Math.max(1, (block.columns || []).length);
    // A donut: the ring and its parts named beside it, one row each.
    if (block.style === 'donut' || block.style === 'pie') {
      return { minW: 520, idealW: 680, maxW: 900, minH: 300, maxH: 520, h: () => HEAD + PAD + Math.max(260, Math.min(7, n) * 50 + 20) };
    }
    // A heatmap: a row per item and a column per series, like a table.
    if (block.style === 'heatmap') {
      return { minW: 300 + series * 90, idealW: 280 + series * 130, maxW: 320 + series * 180, minH: 220, maxH: 640,
        h: () => HEAD + PAD + 38 + block.items.length * 50 };
    }
    const per = block.style === 'stacked' ? 86 : 56 + 30 * series;
    return { minW: 380, idealW: Math.max(520, 90 + n * per), maxW: 1100, minH: 300, maxH: 520,
      h: () => HEAD + PAD + 300 + (series > 1 ? 34 : 0) };
  },
  table(block) {
    const cols = Math.max(2, (block.columns || []).length);
    const total = block.items.some((i) => Object.values(i.cells || {}).some((v) => typeof v === 'number'));
    return { minW: 200 + cols * 120, idealW: 260 + cols * 170, maxW: 300 + cols * 220, minH: 200, maxH: 680,
      h: (w) => {
        const first = Math.max(150, (w - PAD) * 0.3);
        const cellW = (w - PAD - first) / cols;
        const rows = block.items.reduce((sum, item) => sum + 6 + Math.max(50, 16 + 25 * Math.max(lines(item.text, first - 24),
          ...Object.values(item.cells || {}).map((v) => (typeof v === 'number' ? 1 : lines(v, cellW - 24))))), 0);
        return HEAD + PAD + 46 + Math.max(56, rows) + (total ? 46 : 0);
      } };
  },
  matrix() {
    return { minW: 440, idealW: 600, maxW: 820, minH: 340, maxH: 600, h: (w) => HEAD + PAD + Math.min(520, Math.max(300, w * 0.62)) };
  },
  mindmap(block) {
    const branches = block.items.filter((i) => !i.parent || !block.items.some((o) => o.id === i.parent));
    const perSide = Math.ceil(branches.length / 2);
    const leaves = block.items.length - branches.length;
    const sideH = Math.max(perSide * 70, leaves * 26);
    return { minW: 560, idealW: leaves ? 900 : 720, maxW: 1300, minH: 280, maxH: 600,
      h: () => HEAD + PAD + Math.max(200, sideH + 40) };
  },
  stats(block) {
    const n = Math.max(1, block.items.length);
    // A scorecard's tile adds its meter to the target and its sparkline.
    const extra = (block.items.some((i) => i.target) ? 40 : 0) + (block.items.some((i) => i.points?.length > 1) ? 46 : 0);
    return { minW: Math.min(520, 200 * n), idealW: Math.max(260, 250 * n), maxW: 300 * n + 40, minH: 170, maxH: 260 + extra,
      h: () => HEAD + PAD + 120 + extra };
  },
  funnel(block) {
    const n = block.items.length;
    return { minW: 560, idealW: 780, maxW: 1100, minH: 240, maxH: 600, h: () => HEAD + PAD + n * 60 + (n - 1) * 12 };
  },
  roadmap(block) {
    // A row for each bar that overlaps another in its lane, as the drawing packs them.
    const lanes = new Map();
    for (const item of block.items) {
      const span = spanOf(item);
      if (!span) continue;
      if (!lanes.has(item.lane || '')) lanes.set(item.lane || '', []);
      lanes.get(item.lane || '').push(span);
    }
    let rows = 0;
    for (const spans of lanes.values()) {
      const ends = [];
      for (const span of spans.sort((a, b) => a.from - b.from)) {
        const free = ends.findIndex((end) => end < span.from);
        if (free >= 0) ends[free] = span.to;
        else ends.push(span.to);
      }
      rows += ends.length;
    }
    const named = [...lanes.keys()].some(Boolean);
    return { minW: 640, idealW: named ? 1100 : 960, maxW: 1600, minH: 220, maxH: 640,
      h: () => HEAD + PAD + 40 + Math.max(1, rows) * 50 + lanes.size * 20 + 30 };
  },
  tree(block) {
    const byId = new Map(block.items.map((i) => [i.id, i]));
    const depth = (item) => {
      let n = 0;
      for (let at = item; at.parent && byId.has(at.parent) && n < 12; at = byId.get(at.parent)) n += 1;
      return n;
    };
    const levels = Math.max(...block.items.map(depth)) + 1;
    const leaves = block.items.filter((i) => !block.items.some((k) => k.parent === i.id)).length;
    const roles = block.items.some((i) => i.note);
    const node = roles ? 76 : 52;
    // Past what fits side by side, the last level stacks under its parent (blocks.mjs drawTree): taller, not wider.
    const stack = Math.max(0, ...block.items.map((i) => block.items.filter((k) => k.parent === i.id).length));
    return { minW: 560, idealW: Math.max(640, Math.min(1500, leaves * 210)), maxW: 1600, minH: 240, maxH: 680,
      h: (w) => {
        const side = w / Math.max(1, leaves) >= 170;
        return HEAD + PAD + (side ? levels * node + (levels - 1) * 50 : (levels - 1) * (node + 50) + stack * (node - 8));
      } };
  },
  swimlane(block) {
    const n = block.items.length;
    const lanes = new Set(block.items.map((i) => i.lane || '')).size;
    const tallest = (w) => Math.max(1, ...block.items.map((i) => lines(i.text, Math.min(230, (w - 170) / n - 30) - 60)));
    return { minW: Math.max(560, 150 * n + 170), idealW: Math.max(760, 210 * n + 170), maxW: 1600, minH: 220, maxH: 680,
      h: (w) => HEAD + PAD + lanes * Math.max(100, 40 + 28 * tallest(w)) + ((block.links || []).length ? 40 : 0) };
  },
  // A picture keeps the shape it was drawn at (svg.mjs: 1000 by 520 unless it says otherwise). It asks for the height
  // of a picture at most 840 wide: wider than that it only gains margin, and asking for more would make a lone picture
  // shrink the whole board's words to fit at 1280x720. The image scales down into whatever box it gets.
  sketch(block) {
    const [, width, height] = /viewBox="[-\d.]+ [-\d.]+ ([\d.]+) ([\d.]+)"/.exec(block.svg || '') || [0, 1000, 520];
    const ratio = Math.max(0.3, Math.min(1.2, height / width));
    return { minW: 520, idealW: 960, maxW: 1400, minH: 300, maxH: 760, h: (w) => HEAD + PAD + Math.min(w - PAD, 840) * ratio };
  },
};

// An empty block asks for its first item: it wants little room.
const EMPTY = { minW: 260, idealW: 380, maxW: 560, minH: 170, maxH: 280, h: () => HEAD + PAD + 90 };

// `open`: no most height, for a page as tall as its blocks (the notes' picture, a phone), so nothing is cut off there.
export function need(block, density = 1, { open = false } = {}) {
  const make = NEEDS[block?.type];
  const got = !make ? EMPTY : !block.items?.length && !['table', 'matrix', 'chart', 'sketch'].includes(block.type) ? EMPTY : make(block);
  const scale = (v) => v * density;
  const most = open ? Infinity : scale(got.maxH);
  return { minW: scale(got.minW), idealW: scale(got.idealW), maxW: scale(got.maxW), minH: scale(got.minH), maxH: most,
    h: (w) => Math.min(most, Math.max(scale(got.minH), got.h(w / density) * density)) };
}
