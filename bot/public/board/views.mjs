// Which boards a page shows, and how: one board, two side by side, or every board small at once. Pure, so the tests run
// it alone; board.mjs draws what it says.
//
// The shared screen shows what the room says (its `current` and `view`, model.mjs fitView). The board link shows the
// same, except that someone on it can pick a board from the tabs (`viewing`), which they then see alone until Hermes
// puts another view on screen. With nothing on screen, the link shows the board last on screen.
import { fitView } from './model.mjs';

// { mode: 'none' | 'one' | 'split' | 'all', boards: [n] (left to right; every board for 'all'), target: n }, where
// `target` is the board the next change goes to: the one alone, or of two side by side the one changed last.
export function pageView({ count, current = null, last = null, view = null, viewing = null, follows = false }) {
  const none = { mode: 'none', boards: [], target: null };
  const ok = (n) => Number.isInteger(n) && n >= 1 && n <= count;
  if (!follows && ok(viewing)) return { mode: 'one', boards: [viewing], target: viewing };
  if (!ok(current)) {
    // The shared screen with nothing on it shows nothing; the link shows the board last shown.
    const n = follows ? null : ok(last) ? last : null;
    return n ? { mode: 'one', boards: [n], target: n } : none;
  }
  const fitted = fitView(view, count);
  if (fitted.mode === 'split') {
    return { mode: 'split', boards: fitted.boards, target: fitted.boards.includes(current) ? current : fitted.boards[0] };
  }
  if (fitted.mode === 'all') return { mode: 'all', boards: Array.from({ length: count }, (_, i) => i + 1), target: current };
  return { mode: 'one', boards: [current], target: current };
}

// The grid for every board at once, in an area `width` by `height`: as many columns as keep each board's picture
// biggest (pictures are `aspect` wide for 1 tall, the board's own shape). Returns { columns, rows, w, h } with each
// cell's size, `gap` apart.
export function grid(count, { width, height, gap = 20, aspect = 16 / 9, head = 40 } = {}) {
  let best = null;
  for (let columns = 1; columns <= Math.max(1, count); columns++) {
    const rows = Math.ceil(count / columns);
    const w = (width - gap * (columns - 1)) / columns;
    const h = (height - gap * (rows - 1)) / rows;
    // The picture's scale in this cell, below its name.
    const scale = Math.min(w / aspect, h - head);
    if (!best || scale > best.scale + 0.5) best = { columns, rows, w: Math.floor(w), h: Math.floor(h), scale };
  }
  const { columns, rows, w, h } = best;
  return { columns, rows, w, h };
}

// The tabs, one a board in the board's order: { n, on, target, side } where `on` is a board on screen (two are, side by
// side; none is with every board at once), `target` the one the next change goes to while two are on screen, and `side`
// which half it is on.
export function tabStates(count, shown) {
  return Array.from({ length: count }, (_, i) => {
    const n = i + 1;
    const at = shown.mode === 'all' ? -1 : shown.boards.indexOf(n);
    return { n, on: at >= 0, target: shown.mode === 'split' && n === shown.target,
      side: shown.mode === 'split' && at >= 0 ? (at === 0 ? 'left' : 'right') : null };
  });
}
