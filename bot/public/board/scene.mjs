// A board as Excalidraw element skeletons, for the editable .excalidraw file kept in the notes (canvas.mjs turns them
// into a file). Each block is a panel where the notes' picture has it (arrange.mjs, every block as tall as it needs),
// holding its items as boxes, lines and words that can be moved and changed in Excalidraw. Pure: tests run it alone.
import { arrange } from './arrange.mjs';
import { dayWords, kindOf, numberOf, ROUND, spanOf, withUnit } from './model.mjs';

const WIDTH = 1208;
const TOP = 84;
const FONT = 2; // Excalidraw's plain sans-serif
const INK = '#17202a';
const MUTED = '#5a6572';
const LINE = '#8a94a0';
const WASH = '#f3f5f7';
const PAPER = '#ffffff';
const SERIES = ['#2a78d6', '#eb6834', '#1baf7a'];
const BRANCHES = ['#2a78d6', '#eb6834', '#1baf7a', '#c98500', '#d55181', '#008300'];
const HEAT = ['#cde2fb', '#9ec5f4', '#6da7ec', '#3987e5', '#256abf', '#184f95', '#0d366b'];
const STAGES = ['#184f95', '#1c5cab', '#256abf', '#2a78d6', '#3987e5', '#5598e7', '#6da7ec', '#86b6ef'];
const BAR_STATUS = { done: '#aab2bc', now: '#1c5cab', next: '#86b6ef', late: '#b23a24' };
const TINTS = { goals: ['#e8f4ed', '#1d7448'], pros: ['#e8f4ed', '#1d7448'], risks: ['#fbece8', '#b23a24'], cons: ['#fbece8', '#b23a24'],
  actions: ['#eef0f3', '#2b3440'], decisions: ['#eef0f3', '#2b3440'], notes: ['#eaf2fa', '#1f5f99'] };
const LEVELS = { high: 'High', medium: 'Medium', low: 'Low' };
const STATUS = { done: 'done', now: 'under way', next: 'next', late: 'late' };
const PAD = 20;

// Breaks text into lines of at most `width` characters, at spaces where it can.
export function wrap(text, width) {
  const lines = [];
  for (const paragraph of String(text ?? '').split('\n')) {
    let line = '';
    for (let word of paragraph.split(/\s+/).filter(Boolean)) {
      while (word.length > width) {
        if (line) lines.push(line);
        lines.push(`${word.slice(0, width - 1)}-`);
        word = word.slice(width - 1);
        line = '';
      }
      if (!line) line = word;
      else if (line.length + 1 + word.length <= width) line += ` ${word}`;
      else {
        lines.push(line);
        line = word;
      }
    }
    if (line) lines.push(line);
  }
  return lines.length ? lines.join('\n') : ' ';
}

// Characters of `size` text that fit `width` pixels, and the height of `lines` lines of it.
const fit = (width, size) => Math.max(4, Math.floor(width / (size * 0.56)));
const tall = (value, size) => Math.ceil(String(value).split('\n').length * size * 1.25);

function text(id, x, y, value, size, color = INK, extra = {}) {
  return { type: 'text', id, x, y, text: value, fontSize: size, fontFamily: FONT, strokeColor: color, ...extra };
}

function box(id, x, y, width, height, fill, { stroke = fill, label = '', size = 20, round = true, color = INK } = {}) {
  return { type: 'rectangle', id, x, y, width, height, backgroundColor: fill, strokeColor: stroke, fillStyle: 'solid', strokeWidth: 2,
    roughness: 0, ...(round ? { roundness: { type: 3 } } : {}),
    ...(label ? { label: { text: label, fontSize: size, fontFamily: FONT, strokeColor: color } } : {}) };
}

function line(id, points, { color = LINE, width = 3, arrow = false, label = '', dashed = false, from, to } = {}) {
  const [x1, y1] = points[0];
  const xs = points.map(([x]) => x);
  const ys = points.map(([, y]) => y);
  return { type: arrow ? 'arrow' : 'line', id, x: x1, y: y1, width: Math.max(...xs) - Math.min(...xs), height: Math.max(...ys) - Math.min(...ys),
    points: points.map(([x, y]) => [x - x1, y - y1]), strokeColor: color, strokeWidth: width, roughness: 0,
    ...(dashed ? { strokeStyle: 'dashed' } : {}), ...(arrow ? { endArrowhead: 'arrow' } : { endArrowhead: null }),
    ...(from ? { start: { id: from } } : {}), ...(to ? { end: { id: to } } : {}),
    ...(label ? { label: { text: wrap(label, 18), fontSize: 18, fontFamily: FONT, strokeColor: INK } } : {}) };
}

const itemId = (item) => `n:${item.id}`;

// Each type of block, drawn in the area { x, y, w, h } under its title. Pushes to `out`.
const DRAW = {
  list(block, area, out) {
    const actions = kindOf(block) === 'actions';
    let y = area.y;
    for (const item of block.items) {
      const more = [item.level ? `${LEVELS[item.level]} risk` : '', item.owner || (actions ? 'No owner' : ''), item.due || '']
        .filter(Boolean).join(' · ');
      const words = wrap(`${kindOf(block) === 'decisions' ? '✓ ' : ''}${item.text}`, fit(area.w - 32, 22)) + (more ? `\n${more}` : '');
      const h = Math.max(54, tall(words, 22) + 24);
      out.push(box(itemId(item), area.x, y, area.w, h, PAPER, { label: words, size: 22 }));
      y += h + 10;
    }
  },
  flow(block, area, out) {
    const n = block.items.length;
    const perRow = Math.max(1, Math.min(n, Math.floor((area.w + 50) / 230)));
    const w = Math.min(240, (area.w - 50 * (perRow - 1)) / perRow);
    const h = 96;
    const at = new Map();
    block.items.forEach((item, i) => {
      const x = area.x + (i % perRow) * (w + 50);
      const y = area.y + Math.floor(i / perRow) * (h + 60);
      const fill = item.shape === 'decision' ? '#fff4d6' : item.shape === 'start' || item.shape === 'end' ? INK : PAPER;
      const label = wrap(`${item.shape === 'start' || item.shape === 'end' || item.shape === 'decision' ? '' : `${i + 1}. `}${item.text}`, fit(w - 24, 20));
      out.push(item.shape === 'decision'
        ? { ...box(itemId(item), x, y, w, h, fill, { stroke: '#b07800', label, size: 20 }) }
        : box(itemId(item), x, y, w, h, fill, { label, size: 20, color: fill === INK ? PAPER : INK }));
      at.set(item.id, { x, y, w, h });
    });
    const side = (a, b) => (Math.abs(a.y - b.y) < 2 ? [[a.x + a.w, a.y + a.h / 2], [b.x, b.y + b.h / 2]]
      : [[a.x + a.w / 2, a.y + a.h], [b.x + b.w / 2, b.y]]);
    // A link to the very next step is the order's own arrow, with its words on it (as on the page).
    const next = (l) => block.items.findIndex((i) => i.id === l.to) === block.items.findIndex((i) => i.id === l.from) + 1;
    for (let i = 1; i < n; i++) {
      const [a, b] = [block.items[i - 1], block.items[i]];
      const label = (block.links || []).find((l) => l.from === a.id && l.to === b.id)?.label;
      out.push(line(`f:${b.id}`, side(at.get(a.id), at.get(b.id)), { arrow: true, from: itemId(a), to: itemId(b), ...(label ? { label } : {}) }));
    }
    for (const l of (block.links || []).filter((link) => !next(link))) {
      const a = at.get(l.from);
      const b = at.get(l.to);
      if (!a || !b) continue;
      const low = Math.max(a.y + a.h, b.y + b.h) + 40;
      out.push(line(`l:${l.from}>${l.to}`, [[a.x + a.w / 2, a.y + a.h], [a.x + a.w / 2, low], [b.x + b.w / 2, low], [b.x + b.w / 2, b.y + b.h]],
        { arrow: true, dashed: true, label: l.label, from: itemId({ id: l.from }), to: itemId({ id: l.to }) }));
    }
  },
  timeline(block, area, out) {
    const n = Math.max(1, block.items.length);
    const perRow = Math.max(1, Math.min(n, Math.floor(area.w / 180)));
    const slot = area.w / perRow;
    for (let r = 0; r * perRow < n; r++) {
      const y = area.y + r * 170 + 40;
      out.push(line(`t:${block.id}:${r}`, [[area.x, y], [area.x + Math.min(n - r * perRow, perRow) * slot, y]], { color: '#c3c9d1', width: 6 }));
    }
    block.items.forEach((item, i) => {
      const x = area.x + (i % perRow) * slot + 6;
      const y = area.y + Math.floor(i / perRow) * 170;
      if (item.when) out.push(text(`w:${item.id}`, x, y, item.when, 18, MUTED));
      const done = item.status === 'done';
      out.push({ type: 'ellipse', id: itemId(item), x, y: y + 29, width: 22, height: 22, roughness: 0, fillStyle: 'solid',
        backgroundColor: done ? INK : item.status === 'now' ? '#2a78d6' : item.status === 'late' ? '#b23a24' : PAPER,
        strokeColor: done ? INK : item.status === 'now' ? '#2a78d6' : item.status === 'late' ? '#b23a24' : '#9aa3ad', strokeWidth: 3 });
      const words = wrap(item.text, fit(slot - 20, 20)) + (item.status && !done ? `\n(${STATUS[item.status]})` : '');
      out.push(text(`x:${item.id}`, x, y + 62, words, 20, done ? MUTED : INK));
    });
  },
  chart(block, area, out) {
    if (ROUND.includes(block.style)) return parts(block, area, out);
    if (block.style === 'heatmap') return heat(block, area, out);
    const series = (block.columns || []).length ? block.columns : [{ id: '', name: block.title }];
    const valueOf = (item, s) => (s.id ? numberOf(item.cells?.[s.id]) : numberOf(item.value));
    const stacked = block.style === 'stacked';
    const values = stacked ? block.items.map((i) => series.reduce((sum, s) => sum + Math.max(0, valueOf(i, s) ?? 0), 0))
      : block.items.flatMap((i) => series.map((s) => valueOf(i, s))).filter((v) => v !== null);
    const max = Math.max(1, ...values);
    const plotH = 220;
    const top = area.y + (series.length > 1 ? 40 : 10) + 24;
    if (series.length > 1) {
      series.forEach((s, k) => {
        out.push(box(`k:${block.id}:${k}`, area.x + k * 170, area.y, 16, 16, SERIES[k % 3], { round: false }));
        out.push(text(`kt:${block.id}:${k}`, area.x + k * 170 + 24, area.y - 4, s.name, 18));
      });
    }
    out.push(line(`z:${block.id}`, [[area.x, top + plotH], [area.x + area.w, top + plotH]], { color: '#aab2bc', width: 2 }));
    const band = area.w / Math.max(1, block.items.length);
    const barW = Math.min(64, (band * 0.64) / (stacked ? 1 : series.length));
    block.items.forEach((item, i) => {
      if (stacked) {
        let base = top + plotH;
        series.forEach((s, k) => {
          const v = Math.max(0, valueOf(item, s) ?? 0);
          if (!v) return;
          const h = Math.max(4, (v / max) * plotH);
          out.push(box(`${itemId(item)}:${s.id}`, area.x + band * i + band / 2 - 32, base - h, 64, h - 2, SERIES[k % 3], { round: false }));
          base -= h;
        });
        out.push(text(`v:${item.id}`, area.x + band * i + band / 2 - 32, base - 26, amount(values[i], block.unit), 17));
        out.push(text(`c:${item.id}`, area.x + band * i + 4, top + plotH + 10, wrap(item.text, fit(band - 8, 17)), 17));
        return;
      }
      series.forEach((s, k) => {
        const v = valueOf(item, s);
        if (v === null) return;
        const h = Math.max(4, (Math.max(0, v) / max) * plotH);
        const x = area.x + band * i + band / 2 + (k - (series.length - 1) / 2) * (barW + 4) - barW / 2;
        out.push(box(`${itemId(item)}${s.id ? `:${s.id}` : ''}`, x, top + plotH - h, barW, h, SERIES[k % 3], { round: false }));
        out.push(text(`v:${item.id}:${s.id}`, x, top + plotH - h - 26, amount(v, block.unit), 17));
      });
      out.push(text(`c:${item.id}`, area.x + band * i + 4, top + plotH + 10, wrap(item.text, fit(band - 8, 17)), 17));
    });
  },
  table(block, area, out) {
    const columns = block.columns || [];
    const first = Math.min(260, area.w * 0.34);
    const cellW = (area.w - first) / Math.max(1, columns.length);
    columns.forEach((c, k) => out.push(text(`h:${c.id}`, area.x + first + k * cellW + 10, area.y,
      `${c.name}${block.pick === c.id ? ' (picked)' : ''}`, 20, block.pick === c.id ? '#1d7448' : INK)));
    let y = area.y + 40;
    for (const item of block.items) {
      const crit = wrap(item.text, fit(first - 20, 20));
      const h = Math.max(48, tall(crit, 20) + 20);
      out.push(box(itemId(item), area.x, y, area.w, h, PAPER));
      out.push(text(`r:${item.id}`, area.x + 12, y + 12, crit, 20));
      columns.forEach((c, k) => {
        const v = item.cells?.[c.id];
        if (v === undefined) return;
        out.push(text(`v:${item.id}:${c.id}`, area.x + first + k * cellW + 10, y + 12, wrap(String(v), fit(cellW - 20, 20)), 20));
      });
      y += h + 8;
    }
  },
  matrix(block, area, out) {
    const w = (area.w - 70) / 2;
    const h = Math.max(140, (area.h - 40) / 2);
    const q = { tl: [0, 0], tr: [1, 0], bl: [0, 1], br: [1, 1] };
    for (const [name, [cx, cy]] of Object.entries(q)) {
      const x = area.x + 70 + cx * (w + 8);
      const y = area.y + cy * (h + 8);
      out.push(box(`q:${block.id}:${name}`, x, y, w, h, PAPER));
      if (block.quadrants?.[name]) out.push(text(`qn:${block.id}:${name}`, x + 12, y + 10, block.quadrants[name], 18, MUTED));
      const items = block.items.filter((i) => i.quadrant === name);
      if (items.length) out.push(text(`qi:${block.id}:${name}`, x + 12, y + 40, items.map((i) => `• ${wrap(i.text, fit(w - 40, 18))}`).join('\n'), 18));
    }
    const x = block.x || { low: 'Low', high: 'High' };
    const y = block.y || { low: 'Low', high: 'High' };
    out.push(text(`ya:${block.id}`, area.x, area.y, wrap(y.high, 8), 16, MUTED));
    out.push(text(`yb:${block.id}`, area.x, area.y + 2 * h - 20, wrap(y.low, 8), 16, MUTED));
    out.push(text(`xa:${block.id}`, area.x + 70, area.y + 2 * h + 16, x.low, 16, MUTED));
    out.push(text(`xb:${block.id}`, area.x + area.w - 120, area.y + 2 * h + 16, x.high, 16, MUTED));
  },
  mindmap(block, area, out) {
    const byId = new Map(block.items.map((i) => [i.id, i]));
    const branches = block.items.filter((i) => !i.parent || !byId.has(i.parent));
    const cw = 220;
    const cx = area.x + area.w / 2 - cw / 2;
    const cy = area.y + Math.max(0, area.h / 2 - 36);
    out.push(box(`m:${block.id}`, cx, cy, cw, 72, INK, { label: wrap(block.title, 16), size: 22, color: PAPER }));
    const sides = [branches.filter((_, i) => i % 2 === 0), branches.filter((_, i) => i % 2 === 1)];
    sides.forEach((list, s) => {
      list.forEach((branch, i) => {
        const color = BRANCHES[branches.indexOf(branch) % BRANCHES.length];
        const kids = [];
        const walk = (id, depth) => { for (const k of block.items.filter((o) => o.parent === id)) { kids.push([k, depth]); walk(k.id, depth + 1); } };
        walk(branch.id, 0);
        const y = area.y + i * Math.max(80, area.h / Math.max(1, list.length));
        const bw = 190;
        const bx = s === 0 ? cx + cw + 60 : cx - 60 - bw;
        out.push(box(itemId(branch), bx, y, bw, 56, PAPER, { stroke: color, label: wrap(branch.text, 15), size: 19 }));
        out.push(line(`mt:${branch.id}`, [[s === 0 ? cx + cw : cx, cy + 36], [s === 0 ? bx : bx + bw, y + 28]], { color, width: 3 }));
        kids.forEach(([kid, depth], k) => {
          const kx = s === 0 ? bx + bw + 30 + depth * 18 : bx - 30 - depth * 18 - 170;
          out.push(text(itemId(kid), kx, y + k * 28, wrap(kid.text, 18).split('\n')[0], 17));
        });
      });
    });
  },
  stats(block, area, out) {
    const n = Math.max(1, block.items.length);
    const w = (area.w - (n - 1) * 12) / n;
    block.items.forEach((item, i) => {
      const x = area.x + i * (w + 12);
      out.push(box(itemId(item), x, area.y, w, 130, PAPER));
      out.push(text(`l:${item.id}`, x + 16, area.y + 12, wrap(item.text, fit(w - 32, 18)).split('\n')[0], 18, MUTED));
      out.push(text(`v:${item.id}`, x + 16, area.y + 40, item.value || '—', 44));
      const note = [item.trend === 'up' ? '▲' : item.trend === 'down' ? '▼' : '', item.note || '', item.target ? `target ${item.target}` : '']
        .filter(Boolean).join(' · ');
      if (note) out.push(text(`o:${item.id}`, x + 16, area.y + 98, note, 16, MUTED));
    });
  },
  funnel(block, area, out) {
    const values = block.items.map((i) => numberOf(i.value));
    const most = Math.max(1, ...values.filter((v) => v !== null));
    const labelW = Math.min(240, area.w * 0.28);
    const plot = area.w - labelW - 180;
    block.items.forEach((item, i) => {
      const y = area.y + i * 62;
      const w = Math.max(12, ((values[i] ?? 0) / most) * plot);
      out.push(text(`fl:${item.id}`, area.x, y + 14, wrap(item.text, fit(labelW - 10, 20)).split('\n')[0], 20));
      out.push(box(itemId(item), area.x + labelW + (plot - w) / 2, y, w, 50, STAGES[Math.min(STAGES.length - 1, i)], { round: false }));
      const before = i > 0 ? values[i - 1] : null;
      const said = values[i] === null ? '' : `${amount(values[i], block.unit)}${before && values[i] !== null ? ` (${Math.round((values[i] / before) * 100)}%)` : ''}`;
      if (said) out.push(text(`fv:${item.id}`, area.x + labelW + plot + 16, y + 14, said, 19));
    });
  },
  roadmap(block, area, out) {
    const placed = block.items.map((item) => ({ item, span: spanOf(item) })).filter((x) => x.span);
    if (!placed.length) return;
    const lo = Math.min(...placed.map((x) => x.span.from));
    const hi = Math.max(...placed.map((x) => x.span.to)) + 1;
    const lanes = [...new Set(placed.map((x) => x.item.lane || ''))];
    const labelW = lanes.some(Boolean) ? 170 : 0;
    const xOf = (day) => area.x + labelW + ((day - lo) / (hi - lo)) * (area.w - labelW);
    const first = new Date(lo * 86400000);
    for (let m = 0; m < 36; m++) {
      const at = Date.UTC(first.getUTCFullYear(), first.getUTCMonth() + m, 1) / 86400000;
      if (at > hi) break;
      if (at >= lo) out.push(text(`rt:${block.id}:${m}`, xOf(at), area.y, dayWords(at, { month: true }), 16, MUTED));
    }
    let y = area.y + 34;
    for (const [k, lane] of lanes.entries()) {
      const mine = placed.filter((x) => (x.item.lane || '') === lane).sort((a, b) => a.span.from - b.span.from);
      const rows = [];
      for (const x of mine) {
        const free = rows.findIndex((end) => end < x.span.from);
        x.row = free >= 0 ? free : rows.length;
        rows[x.row] = x.span.to;
      }
      if (lane) out.push(text(`rl:${block.id}:${k}`, area.x, y + 8, wrap(lane, fit(labelW - 10, 18)), 18));
      for (const x of mine) {
        const left = xOf(x.span.from);
        const width = Math.max(14, xOf(x.span.to + 1) - left);
        const fill = BAR_STATUS[x.item.status] || '#2a78d6';
        out.push(box(itemId(x.item), left, y + x.row * 46, width, 38, fill, { round: false }));
        out.push(text(`rx:${x.item.id}`, left + 8, y + x.row * 46 + 8, x.item.text, 18, fill === '#86b6ef' || width < x.item.text.length * 10 ? INK : PAPER));
      }
      y += rows.length * 46 + 16;
    }
  },
  tree(block, area, out) {
    const byId = new Map(block.items.map((i) => [i.id, i]));
    const kids = (id) => block.items.filter((i) => i.parent === id);
    const roots = block.items.filter((i) => !i.parent || !byId.has(i.parent));
    const leaves = (item) => (kids(item.id).length ? kids(item.id).reduce((sum, k) => sum + leaves(k), 0) : 1);
    const slot = area.w / Math.max(1, roots.reduce((sum, r) => sum + leaves(r), 0));
    const w = Math.min(220, slot - 16);
    const where = new Map();
    let cursor = 0;
    const place = (item, depth) => {
      const children = kids(item.id);
      const cx = children.length ? (() => { const c = children.map((k) => place(k, depth + 1)); return (c[0] + c.at(-1)) / 2; })()
        : (cursor++ + 0.5) * slot;
      where.set(item.id, { x: area.x + cx - w / 2, y: area.y + depth * 120 });
      return cx;
    };
    roots.forEach((r) => place(r, 0));
    for (const item of block.items) {
      const at = where.get(item.id);
      if (!at) continue;
      const root = !item.parent || !byId.has(item.parent);
      out.push(box(itemId(item), at.x, at.y, w, 72, root ? INK : PAPER,
        { label: wrap(`${item.text}${item.note ? `\n${item.note}` : ''}`, fit(w - 20, 18)), size: 18, color: root ? PAPER : INK }));
      const parent = where.get(item.parent);
      if (parent) {
        const mid = parent.y + 72 + 24;
        out.push(line(`tl:${item.id}`, [[parent.x + w / 2, parent.y + 72], [parent.x + w / 2, mid], [at.x + w / 2, mid], [at.x + w / 2, at.y]],
          { color: '#aab2bc', from: itemId({ id: item.parent }), to: itemId(item) }));
      }
    }
  },
  swimlane(block, area, out) {
    const lanes = [...new Set(block.items.map((i) => i.lane || ''))];
    const labelW = 150;
    const col = (area.w - labelW) / Math.max(1, block.items.length);
    const w = Math.min(200, col - 30);
    const laneH = 120;
    lanes.forEach((lane, k) => {
      out.push(box(`sl:${block.id}:${k}`, area.x, area.y + k * laneH, area.w, laneH - 6, k % 2 ? '#f8f9fa' : PAPER, { stroke: '#dfe3e8' }));
      if (lane) out.push(text(`sn:${block.id}:${k}`, area.x + 12, area.y + k * laneH + 14, wrap(lane, fit(labelW - 20, 18)), 18));
    });
    const at = new Map();
    block.items.forEach((item, i) => {
      const x = area.x + labelW + i * col + (col - w) / 2;
      const y = area.y + lanes.indexOf(item.lane || '') * laneH + 18;
      out.push(box(itemId(item), x, y, w, 78, item.shape === 'decision' ? '#fff4d6' : PAPER,
        { stroke: item.shape === 'decision' ? '#b07800' : '#c3c9d1', label: wrap(`${i + 1}. ${item.text}`, fit(w - 20, 18)), size: 18 }));
      at.set(item.id, { x, y, w, h: 78 });
    });
    for (let i = 1; i < block.items.length; i++) {
      const a = at.get(block.items[i - 1].id);
      const b = at.get(block.items[i].id);
      const mid = (a.x + a.w + b.x) / 2;
      out.push(line(`sf:${block.items[i].id}`, [[a.x + a.w, a.y + 39], [mid, a.y + 39], [mid, b.y + 39], [b.x, b.y + 39]],
        { arrow: true, from: itemId(block.items[i - 1]), to: itemId(block.items[i]) }));
    }
  },
  // A custom picture goes in as an image (files() holds its data), to be moved or traced over in Excalidraw.
  sketch(block, area, out) {
    if (!block.svg) return;
    const [, width, height] = /viewBox="[-\d.]+ [-\d.]+ ([\d.]+) ([\d.]+)"/.exec(block.svg) || [0, 1000, 520];
    // As on the board (sizes.mjs), no taller than 1.2 times its width, and inside its block.
    const scale = Math.min(area.w / width, Math.min(area.h, area.w * 1.2) / height, 1);
    out.push({ type: 'image', id: itemId(block), x: area.x, y: area.y, width: width * scale, height: height * scale, fileId: fileOf(block),
      status: 'saved' });
  },
};

// A chart's number as the notes picture writes it: with its money sign and size ("$4.6M") or "%"; a word unit is in the
// block's title line instead.
const amount = (v, unit) => {
  const text = v.toLocaleString('en-US');
  return /^(?:[$€£][kMB]?|%)$/.test(String(unit || '').trim()) ? withUnit(text, unit) : text;
};

// A whole and its parts (a donut or a pie): each part a row with its color, words, number and share, under one bar
// split by share, since Excalidraw has no arcs to draw a ring with.
function parts(block, area, out) {
  const series = (block.columns || [])[0];
  const list = block.items.map((item) => ({ item, v: series ? numberOf(item.cells?.[series.id]) : numberOf(item.value) }))
    .filter((p) => p.v !== null && p.v > 0);
  const total = list.reduce((sum, p) => sum + p.v, 0) || 1;
  let x = area.x;
  list.forEach((p, k) => {
    const w = (p.v / total) * area.w;
    out.push(box(`ps:${p.item.id}`, x, area.y, Math.max(2, w - 2), 36, BRANCHES[k % BRANCHES.length], { round: false }));
    x += w;
  });
  list.forEach((p, k) => {
    const y = area.y + 56 + k * 44;
    out.push(box(`pk:${p.item.id}`, area.x, y + 4, 18, 18, BRANCHES[k % BRANCHES.length], { round: false }));
    out.push(text(itemId(p.item), area.x + 30, y, `${p.item.text}: ${amount(p.v, block.unit)} (${Math.round((p.v / total) * 100)}%)`, 20));
  });
}

// A grid of numbers, each cell shaded by its size on one blue.
function heat(block, area, out) {
  const series = (block.columns || []).length ? block.columns : [{ id: '', name: block.title }];
  const valueOf = (item, s) => (s.id ? numberOf(item.cells?.[s.id]) : numberOf(item.value));
  const values = block.items.flatMap((i) => series.map((s) => valueOf(i, s))).filter((v) => v !== null);
  const lo = Math.min(...values);
  const hi = Math.max(...values);
  const first = Math.min(220, area.w * 0.3);
  const cw = (area.w - first) / series.length;
  series.forEach((s, k) => out.push(text(`hh:${block.id}:${k}`, area.x + first + k * cw + 8, area.y, s.name, 17, MUTED)));
  block.items.forEach((item, r) => {
    const y = area.y + 32 + r * 50;
    out.push(text(itemId(item), area.x, y + 12, wrap(item.text, fit(first - 10, 19)).split('\n')[0], 19));
    series.forEach((s, k) => {
      const v = valueOf(item, s);
      if (v === null) return;
      const step = hi > lo ? Math.round(((v - lo) / (hi - lo)) * (HEAT.length - 1)) : 3;
      out.push(box(`hc:${item.id}:${s.id}`, area.x + first + k * cw, y, cw - 4, 46, HEAT[step],
        { label: amount(v, block.unit), size: 18, color: step >= 3 ? PAPER : INK, round: false }));
    });
  });
}

const fileOf = (block) => `sketch-${block.id}`;

// The image files a board's scene uses: each custom picture, as the SVG the room kept (svg.mjs made it safe).
export function files(board) {
  const out = {};
  for (const block of board?.blocks || []) {
    if (block.type !== 'sketch' || !block.svg) continue;
    let bytes = '';
    for (const byte of new TextEncoder().encode(block.svg)) bytes += String.fromCharCode(byte);
    const dataURL = `data:image/svg+xml;base64,${btoa(bytes)}`;
    out[fileOf(block)] = { id: fileOf(block), mimeType: 'image/svg+xml', dataURL, created: 0 };
  }
  return out;
}

// The skeletons for `board`, with its title on top.
export function scene(board) {
  const out = [text('title', 0, 0, wrap(board?.title || 'Whiteboard', 40), 44)];
  const blocks = board?.blocks || [];
  if (!blocks.length) {
    out.push(text('hint', 0, TOP, 'Nothing was put on this board.', 26, MUTED));
    return out;
  }
  const { places } = arrange(blocks, { width: WIDTH, height: Infinity });
  places.forEach((place, i) => {
    const block = blocks[i];
    const [fill, tint] = block.type === 'list' ? TINTS[kindOf(block)] || TINTS.notes : [WASH, INK];
    const x = place.x;
    const y = TOP + place.y;
    out.push(box(`b:${block.id}`, x, y, place.w, place.h, fill));
    out.push(text(`bt:${block.id}`, x + PAD, y + 16, wrap(block.title, fit(place.w - 2 * PAD, 28)).split('\n')[0], 28, tint));
    const area = { x: x + PAD, y: y + 66, w: place.w - 2 * PAD, h: place.h - 66 - PAD };
    if (block.items.length || block.type === 'sketch') DRAW[block.type]?.(block, area, out);
  });
  return out;
}
