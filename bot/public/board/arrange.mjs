// Where each block goes on the board: rows of blocks, in the board's order, sized to what each one holds. Pure, so the
// tests run it alone and the page, the print page and the phone all place blocks the same way.
//
// Every way of cutting the blocks into rows (at most three blocks a row) is tried, and the one that gives every block
// closest to the room it wants wins; the rows of the last arrangement are kept when they fit about as well, so a new
// block slides in beside the others rather than shuffling the whole board.
import { need } from './sizes.mjs';

const MAX_PER_ROW = 3;

// All ways to cut n blocks, in order, into rows of at most `most`.
function cuts(n, most) {
  if (!n) return [[]];
  const out = [];
  for (let first = 1; first <= Math.min(most, n); first++) {
    for (const rest of cuts(n - first, most)) out.push([first, ...rest]);
  }
  return out;
}

const sameRows = (a, b) => Array.isArray(a) && Array.isArray(b) && a.length === b.length && a.every((n, i) => n === b[i]);

// One row of blocks in `width`: each gets a share of the width by what it wants, never under its least or over its most.
function widths(needs, width, gap) {
  const room = width - gap * (needs.length - 1);
  const want = needs.reduce((sum, n) => sum + n.idealW, 0);
  let given = needs.map((n) => Math.min(n.maxW, Math.max(n.minW, (n.idealW / want) * room)));
  // What one block could not take (it hit its most) goes to the others that can grow.
  for (let pass = 0; pass < 3; pass++) {
    const spare = room - given.reduce((a, b) => a + b, 0);
    if (spare <= 1) break;
    const growable = given.map((w, i) => (w < needs[i].maxW ? i : -1)).filter((i) => i >= 0);
    if (!growable.length) break;
    const weight = growable.reduce((sum, i) => sum + needs[i].idealW, 0);
    given = given.map((w, i) => (growable.includes(i) ? Math.min(needs[i].maxW, w + (spare * needs[i].idealW) / weight) : w));
  }
  // Still room left (every block at its most): they all grow alike, so a row always spans the board.
  const left = room - given.reduce((a, b) => a + b, 0);
  const total = given.reduce((a, b) => a + b, 0);
  if (left > 1 && total > 0) given = given.map((w) => w + (left * w) / total);
  // Too many for the row (or one block wider than a phone): all give way alike, so nothing runs off the board.
  const sum = given.reduce((a, b) => a + b, 0);
  if (sum > room) given = given.map((w) => (w * room) / sum);
  return given;
}

// The blocks' places in an area `width` by `height` (Infinity: as tall as they want, for the notes' picture and the
// phone): [{ id, x, y, w, h }], plus the rows used, to keep next time (`previous`). `squeeze`: rows give up height below
// their blocks' least when nothing else fits, so the board never runs off the screen (a long list then says "+3 more").
// `whole`: each block may be as tall as its contents want (beside another board, where a block is shown whole or not).
export function arrange(blocks, { width, height = Infinity, gap = 18, previous = null, density = 1, perRow = MAX_PER_ROW,
  squeeze = false, whole = false } = {}) {
  const list = blocks || [];
  if (!list.length) return { places: [], rows: [] };
  const needs = list.map((b) => need(b, density, { open: whole || !Number.isFinite(height) }));
  let best = null;
  for (const rows of cuts(list.length, Math.max(1, perRow))) {
    let at = 0;
    let penalty = 0.04 * rows.length;
    const plan = [];
    for (const count of rows) {
      const these = needs.slice(at, at + count);
      const ws = widths(these, width, gap);
      const hs = these.map((n, i) => n.h(ws[i]));
      const rowH = Math.max(...hs, ...these.map((n) => n.minH));
      these.forEach((n, i) => {
        const short = Math.max(0, n.idealW - ws[i]) / n.idealW;
        penalty += short * short;
        // Narrower than it can be drawn: its words would be cut, much worse than a block short of its best width.
        if (ws[i] < n.minW - 1) penalty += 10 * ((n.minW - ws[i]) / n.minW);
        // A block much wider than it can use leaves a wide empty panel.
        if (ws[i] > n.idealW * 1.8) penalty += 0.05;
      });
      plan.push({ start: at, count, ws, rowH, hs });
      at += count;
    }
    const total = plan.reduce((sum, r) => sum + r.rowH, 0) + gap * (plan.length - 1);
    let scale = 1;
    if (Number.isFinite(height) && total > height) {
      // Too tall: every row gives up height in proportion, down to its blocks' least; what is still over is a heavy
      // penalty, as something would be cut off.
      const least = plan.reduce((sum, r) => sum + Math.max(...needs.slice(r.start, r.start + r.count).map((n) => n.minH)), 0)
        + gap * (plan.length - 1);
      scale = Math.max(0, (height - gap * (plan.length - 1)) / (total - gap * (plan.length - 1)));
      if (least > height) penalty += 10 * ((least - height) / height);
      for (const r of plan) {
        const these = needs.slice(r.start, r.start + r.count);
        const floor = squeeze ? 0 : Math.max(...these.map((n) => n.minH));
        const squeezed = Math.max(floor, r.rowH * scale);
        r.hs.forEach((h) => { const lost = Math.max(0, h - squeezed) / h; penalty += lost * lost; });
        r.rowH = squeezed;
      }
    }
    if (!sameRows(rows, previous)) penalty += 0.12;
    if (!best || penalty < best.penalty - 1e-9) best = { penalty, plan, rows };
  }
  // Rows share out the height that is left, so blocks fill the board rather than huddle at the top, up to their most.
  if (Number.isFinite(height)) {
    const used = best.plan.reduce((sum, r) => sum + r.rowH, 0) + gap * (best.plan.length - 1);
    const spare = height - used;
    if (spare > 0) {
      // A whole block's most is no limit; spare height still stops at the usual most, so rows do not stretch empty.
      const most = list.map((b, i) => (whole ? need(b, density).maxH : needs[i].maxH));
      const tallest = best.plan.map((r) => Math.max(...most.slice(r.start, r.start + r.count)));
      const room = best.plan.map((r, i) => Math.max(0, tallest[i] - r.rowH));
      const all = room.reduce((a, b) => a + b, 0);
      if (all > 0) best.plan.forEach((r, i) => { r.rowH += Math.min(room[i], (spare * room[i]) / all); });
    }
  }
  const places = [];
  let y = 0;
  for (const r of best.plan) {
    let x = 0;
    for (let i = 0; i < r.count; i++) {
      const block = list[r.start + i];
      places.push({ id: block.id, x: Math.round(x), y: Math.round(y), w: Math.round(r.ws[i]), h: Math.round(r.rowH) });
      x += r.ws[i] + gap;
    }
    y += r.rowH + gap;
  }
  return { places, rows: best.rows, height: Math.round(y - gap) };
}
