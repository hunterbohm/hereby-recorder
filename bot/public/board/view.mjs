// The board as a page: its blocks (blocks.mjs) side by side and in rows (arrange.mjs) in the room between the header
// and the status bar, all at one density, so a fuller board shrinks every block together rather than cutting one off.
// Used on the shared screen, on the link (on a phone the blocks stack, one a row) and for the picture filed in the
// notes (every block as tall as it needs).
//
// plan() is pure so tests can run it; render() puts a board in the page and animates what changed: a new block comes
// in where the arrangement puts it while the others glide aside, and inside each block only what changed moves.
import { arrange } from './arrange.mjs';
import { draw, put } from './blocks.mjs';
import { boardName } from './model.mjs';
import { need } from './sizes.mjs';

// How long the "just now" mark stays on what was changed.
export const NEW_MS = 6000;
// The densities a board tries, largest first, until its blocks fit. Below the last, a long list says "+3 more".
export const DENSITIES = [1, 0.9, 0.8, 0.72];
const GAP = 18;
const PHONE_DENSITY = 0.8;
// The row of folded blocks' names at the foot of a half (`fold`), and the space above it, at density 1.
export const FOLD_H = 58;

// Whether every block gets about the room it wants at this density.
// `whole`: a block must have all the height its contents want, not just its most (a block's most height keeps one long
// block from taking a whole board; beside another board, a block shown must show everything in it).
function fits(blocks, got, height, density, whole = false) {
  if (got.height > height + 1) return false;
  return got.places.every((place, i) => {
    const wants = need(blocks[i], density, { open: whole });
    return place.w >= wants.minW - 1 && place.h >= wants.h(place.w) - 6;
  });
}

// The largest density at which `blocks` all fit `width` by `height`, with their places; null when none does.
function fitting(blocks, width, height, previous) {
  for (const density of DENSITIES) {
    const got = arrange(blocks, { width, height, gap: Math.round(GAP * density), previous, density, whole: true });
    if (fits(blocks, got, height, density, true)) return { ...got, density };
  }
  return null;
}

// Where the blocks go in an area `width` by `height` (Infinity: as tall as they need), and at what density.
// `previous` is the last arrangement's rows, kept when they still fit about as well.
//
// `fold` (half the screen, beside another board): rather than shrink below the smallest density or cut blocks short, the
// board shows the blocks that fit, whole, and folds the rest into a row of their names at its foot. It takes the blocks
// changed most lately first (`recent`, ids, latest first), then the rest in the board's order, each one that still
// fits; those shown stay in the board's order. A block too big for the half even alone is folded too, never drawn cut
// short; when no block fits, every one is. `folded` lists the ids folded.
export function plan(blocks, { width, height = Infinity, previous = null, phone = false, fold = false, recent = [] } = {}) {
  const list = blocks || [];
  if (phone) {
    return { ...arrange(list, { width, height: Infinity, gap: 12, perRow: 1, density: PHONE_DENSITY }), density: PHONE_DENSITY,
      folded: [] };
  }
  if (!Number.isFinite(height)) return { ...arrange(list, { width, height, gap: GAP, previous }), density: 1, folded: [] };
  if (fold && list.length > 1) {
    const whole = fitting(list, width, height, previous);
    if (whole) return { ...whole, folded: [] };
    const order = [...new Set([...recent.map((id) => list.find((b) => b.id === id)).filter(Boolean), ...list])];
    const folded = (shown) => list.filter((b) => !shown.has(b)).map((b) => b.id);
    const keep = new Set();
    let best = null;
    for (const block of order) {
      const shown = list.filter((b) => keep.has(b) || b === block);
      const got = fitting(shown, width, height - FOLD_H, null);
      if (!got) continue;
      keep.add(block);
      best = got;
    }
    if (best) return { ...best, folded: folded(keep) };
    return { places: [], rows: [], height: 0, density: DENSITIES.at(-1), folded: folded(keep) };
  }
  let last = null;
  for (const density of DENSITIES) {
    const got = arrange(list, { width, height, gap: Math.round(GAP * density), previous, density });
    last = { ...got, density, folded: [] };
    if (fits(list, got, height, density)) return last;
  }
  // Still too tall at the smallest: the rows give up height to fit, rather than the last row running off the screen.
  if (last.height > height + 1) {
    last = { ...arrange(list, { width, height, gap: Math.round(GAP * last.density), previous, density: last.density, squeeze: true }),
      density: last.density };
  }
  return { ...last, folded: [] };
}

// The blocks folded at the foot of a half, each its name and how many items it holds: "Risks 2". One just changed is
// marked as any change is, so a change to a folded block still shows where it went.
// `every`: no block fits the half whole, so the row stands at the top and says how to see the board (`name`).
function foldRow(host, blocks, density, changed, who, { every = false, name = '' } = {}) {
  let row = host.querySelector(':scope > .folded');
  if (!blocks.length) return row?.remove();
  if (!row) {
    row = host.appendChild(document.createElement('div'));
    row.className = 'folded';
  }
  row.style.setProperty('--d', density);
  row.classList.toggle('every', every);
  const label = Object.assign(document.createElement('span'), { className: 'also',
    textContent: every ? `Too big for half the screen. Say “Hey Hermes, just ${name}” to see it.` : 'Also on this board' });
  row.replaceChildren(label, ...blocks.map((block) => {
    const chip = document.createElement('span');
    chip.className = 'fold';
    chip.dataset.block = block.id;
    chip.append(Object.assign(document.createElement('span'), { textContent: block.title || 'Notes' }),
      Object.assign(document.createElement('b'), { textContent: String(block.items?.length || 0) }));
    if (who && changed.some((id) => id === block.id || block.items?.some((i) => i.id === id))) {
      chip.style.setProperty('--who', who.color);
      chip.classList.add('new');
      setTimeout(() => chip.classList.remove('new'), NEW_MS);
    }
    return chip;
  }));
  // Names cut short: the label gives up its room to them.
  row.classList.remove('tight');
  row.classList.toggle('tight', [...row.querySelectorAll('.fold span')].some((name) => name.scrollWidth > name.clientWidth + 1));
}

// A person's color: the same for one id on every page.
const PEOPLE = ['#c2410c', '#0f766e', '#15803d', '#be185d', '#1d4ed8', '#a16207'];
export function personColor(id) {
  let hash = 0;
  for (const c of String(id)) hash = (hash * 31 + c.charCodeAt(0)) >>> 0;
  return PEOPLE[hash % PEOPLE.length];
}

// Marks what was just changed, with who changed it, for NEW_MS: a ring in their color, and on a list's row a tag.
const timers = new WeakMap();
function mark(node, who) {
  clearTimeout(timers.get(node));
  node.style.setProperty('--who', who.color);
  if (node.matches('.row')) {
    let tag = node.querySelector(':scope > .tag');
    if (!tag) tag = node.appendChild(Object.assign(document.createElement('span'), { className: 'tag' }));
    tag.textContent = `${who.name}, just now`;
  }
  node.classList.add('new');
  timers.set(node, setTimeout(() => node.classList.remove('new'), NEW_MS));
}

// Puts `board` in `host`. `changed` names the ids just changed, by `who` ({ name, color }), in the command `cmd`: a
// block that command made is marked whole, not again for each item it then gets. `link` says the page can
// change the board (each block gets "+ Add"); `print` draws every block as tall as it needs, for the notes' picture;
// `phone` stacks them; `fold` (half the screen) folds what does not fit into a row of names, keeping the blocks in
// `recent` (ids, changed latest first). Returns the elements of what changed, for a cursor to go to.
export function render(host, board, { changed = [], who = null, cmd = null, link = false, instant = false, print = false,
  phone = false, fold = false, recent = [] } = {}) {
  const all = board?.blocks || [];
  const width = host.clientWidth;
  const height = print || phone ? Infinity : host.clientHeight;
  const layout = plan(all, { width, height, previous: host.rows || null, phone, fold, recent });
  const folded = new Set(layout.folded);
  const blocks = all.filter((b) => !folded.has(b.id));
  foldRow(host, all.filter((b) => folded.has(b.id)), layout.density, changed, who,
    { every: Boolean(all.length) && folded.size === all.length, name: boardName(board) });
  host.rows = layout.rows;
  host.style.setProperty('--d', layout.density);
  host.style.height = Number.isFinite(height) ? '' : `${layout.height || 0}px`;
  const changes = new Set(changed);
  const where = new Map(layout.places.map((place) => [place.id, place]));
  const old = new Map([...host.querySelectorAll(':scope > .blk[data-key]')].map((node) => [node.dataset.key, node]));
  const hit = [];
  const quiet = new Set();
  for (const block of blocks) {
    // Key numbers keep their own height at the top of a taller row, rather than stretch into empty tiles.
    const spot = where.get(block.id);
    const place = block.type === 'stats' ? { ...spot, h: Math.min(spot.h, Math.round(need(block, layout.density).maxH)) } : spot;
    let node = old.get(block.id);
    const fresh = !node;
    if (fresh) {
      node = document.createElement('article');
      node.className = 'blk';
      node.dataset.key = block.id;
      if (!instant) {
        node.classList.add('entering');
        node.addEventListener('animationend', () => node.classList.remove('entering'), { once: true });
      }
      host.append(node);
    }
    old.delete(block.id);
    if (fresh || instant) node.style.transition = 'none';
    node.style.width = `${place.w}px`;
    node.style.height = `${place.h}px`;
    put(node, place.x, place.y);
    node.dataset.w = place.w;
    node.dataset.h = place.h;
    if (fresh || instant) {
      void node.offsetWidth;
      node.style.transition = '';
    }
    // A new block comes in whole; inside one already there, only what changed moves.
    const drawn = draw(node, block, { w: place.w, h: place.h, changed: changes, link, instant: instant || fresh || print,
      density: layout.density });
    if (changes.has(block.id)) {
      hit.push(node);
      node.dataset.cmd = cmd || '';
    } else {
      hit.push(...drawn.values());
      if (cmd && node.dataset.cmd === cmd && node.classList.contains('new')) for (const part of drawn.values()) quiet.add(part);
    }
  }
  for (const node of old.values()) {
    if (instant || matchMedia('(prefers-reduced-motion: reduce)').matches) node.remove();
    else {
      delete node.dataset.key;
      node.classList.add('leaving');
      setTimeout(() => node.remove(), 280);
    }
  }
  if (who && !print) for (const node of hit) if (!quiet.has(node)) mark(node, who);
  return hit;
}
