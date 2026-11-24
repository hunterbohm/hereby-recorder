// The meeting board's layout rules and drawing helpers, which need no page: where blocks go (arrange.mjs), how much
// room each wants (sizes.mjs), the density a full board drops to and what folds beside another board (view.mjs), which
// boards a page shows and its tabs (views.mjs), numbers and gridlines (blocks.mjs), and the .excalidraw file kept in the
// notes (scene.mjs). Run: node --test bot/test/
import test from 'node:test';
import assert from 'node:assert/strict';
import { arrange } from '../public/board/arrange.mjs';
import { ask, inOrder, shown, ticks, toTarget } from '../public/board/blocks.mjs';
import { boardName, fitView, numberOf, spanOf, withUnit } from '../public/board/model.mjs';
import { files, scene, wrap } from '../public/board/scene.mjs';
import { need } from '../public/board/sizes.mjs';
import { DENSITIES, FOLD_H, personColor, plan } from '../public/board/view.mjs';
import { grid, pageView, tabStates } from '../public/board/views.mjs';

// The room the shared screen gives the blocks, at 1280 by 720.
const SCREEN = { width: 1232, height: 556 };
const items = (n, extra = () => ({})) => Array.from({ length: n }, (_, i) => ({ id: `i${i}`, text: `Item number ${i}`, ...extra(i) }));
const list = (id, n = 2, kind = 'goals') => ({ id, type: 'list', title: id, kind, items: items(n).map((i) => ({ ...i, id: `${id}${i.id}` })) });
const chart = (id, n = 4) => ({ id, type: 'chart', title: id, items: items(n, (i) => ({ value: 100 + i * 50 })).map((i) => ({ ...i, id: `${id}${i.id}` })) });
const flow = (id, n = 5) => ({ id, type: 'flow', title: id, items: items(n).map((i) => ({ ...i, id: `${id}${i.id}` })) });

function overlap(a, b) {
  return a.x < b.x + b.w - 0.5 && b.x < a.x + a.w - 0.5 && a.y < b.y + b.h - 0.5 && b.y < a.y + a.h - 0.5;
}

test('blocks go in rows in the board order, at most three a row, each row spanning the board, none overlapping', () => {
  assert.deepEqual(arrange([], { width: 1000 }), { places: [], rows: [] });
  const one = arrange([list('goals')], SCREEN).places[0];
  assert.deepEqual([one.x, one.y, Math.round(one.w)], [0, 0, SCREEN.width], 'a lone block takes the whole width');
  const blocks = [flow('f'), list('g'), chart('c'), list('r', 2, 'risks'), list('a', 3, 'actions')];
  const got = arrange(blocks, { ...SCREEN, gap: 18 });
  assert.deepEqual(got.places.map((p) => p.id), ['f', 'g', 'c', 'r', 'a']);
  assert.ok(got.rows.every((n) => n >= 1 && n <= 3));
  assert.equal(got.rows.reduce((a, b) => a + b, 0), blocks.length);
  let at = 0;
  for (const count of got.rows) {
    const row = got.places.slice(at, at + count);
    const right = row.at(-1).x + row.at(-1).w;
    assert.ok(Math.abs(right - SCREEN.width) < 1.5, `a row ends at the board's edge, not ${right}`);
    assert.ok(row.every((p) => p.y === row[0].y), 'a row shares its top');
    at += count;
  }
  for (const a of got.places) for (const b of got.places) if (a !== b) assert.ok(!overlap(a, b), `${a.id} and ${b.id} overlap`);
});

test('a new block slides in beside the others: the last rows are kept when they still fit about as well', () => {
  const blocks = [list('g'), chart('c')];
  const first = arrange(blocks, SCREEN);
  const next = arrange([...blocks, list('r', 1, 'risks')], { ...SCREEN, previous: [...first.rows, 1] });
  assert.deepEqual(next.places.slice(0, 2).map((p) => p.y), first.places.map((p) => p.y).map(() => next.places[0].y));
  // A board that would cut a block off gives up its old rows.
  const crowded = [flow('f', 6), chart('c', 6), list('g', 4)];
  const kept = arrange(crowded, { ...SCREEN, previous: [3] });
  assert.ok(kept.places.every((p) => p.w >= need(crowded[kept.places.indexOf(p)]).minW * 0.72 - 1));
});

test('a fuller board draws every block a little smaller rather than cutting one off', () => {
  const light = plan([list('g')], SCREEN);
  assert.equal(light.density, 1);
  const full = plan([flow('f', 7), list('g', 4), chart('c', 5), list('r', 3, 'risks'), list('a', 4, 'actions'),
    { id: 's', type: 'stats', title: 'Numbers', items: items(3, () => ({ value: '340' })) }], SCREEN);
  assert.ok(DENSITIES.includes(full.density) && full.density < 1, `density ${full.density}`);
  assert.ok(full.height <= SCREEN.height + 1);
  // On a phone the blocks stack, one a row, as tall as they need; for the notes' picture, nothing is shrunk.
  const phone = plan([list('g'), chart('c')], { width: 360, height: 600, phone: true });
  assert.deepEqual(phone.rows, [1, 1]);
  assert.equal(phone.density, 0.8);
  assert.equal(plan([flow('f', 7), list('g', 9)], { width: 1208, height: Infinity }).density, 1);
});

test('the notes\' picture and a phone show every item: a block there is as tall as it needs; a full old board fits the screen', () => {
  const long = { id: 'l', type: 'list', title: 'Long', kind: 'notes',
    items: items(12, () => ({ text: 'a long note '.repeat(8).slice(0, 90) })) }; // 12 items of 90 characters, the most
  const printed = plan([long], { width: 1208, height: Infinity }).places[0];
  assert.ok(printed.h > need(long).maxH, `printed ${printed.h}, screen most ${need(long).maxH}`);
  assert.equal(printed.h, Math.round(need(long, 1, { open: true }).h(printed.w)));
  const phone = plan([long], { width: 360, height: 600, phone: true }).places[0];
  assert.ok(phone.h > need(long, 0.8).maxH);
  // On the shared screen it is cut to fit (the list then says "+N more"); a board from before blocks, with all 8
  // sections, still fits the screen, nothing overlapping.
  assert.ok(plan([long], SCREEN).height <= SCREEN.height + 1);
  const eight = plan(Array.from({ length: 8 }, (_, i) => list(`s${i}`, 4)), SCREEN);
  assert.ok(eight.height <= SCREEN.height + 1, `height ${eight.height}`);
  for (const a of eight.places) for (const b of eight.places) if (a !== b) assert.ok(!overlap(a, b), `${a.id} and ${b.id} overlap`);
});

test("items stand in the board's order on the page: one added at the top, or moved, shows there", () => {
  // Elements in a parent, as far as inOrder() needs: their place, and after().
  const kids = [];
  let moves = 0;
  const node = (key) => ({ key,
    compareDocumentPosition(other) { return kids.indexOf(other) < kids.indexOf(this) ? 2 : 4; },
    after(other) { moves += 1; kids.splice(kids.indexOf(other), 1); kids.splice(kids.indexOf(this) + 1, 0, other); } });
  const [a, b, top, leaving] = ['a', 'b', 'top', 'leaving'].map(node);
  // A new row is made at the end; one fading out is still there.
  kids.push(a, leaving, b, top);
  inOrder([top, a, b]);
  assert.deepEqual(kids.filter((k) => k !== leaving).map((k) => k.key), ['top', 'a', 'b']);
  inOrder([b, top, a]);
  assert.deepEqual(kids.filter((k) => k !== leaving).map((k) => k.key), ['b', 'top', 'a']);
  moves = 0;
  inOrder([b, top, a]);
  assert.equal(moves, 0, 'rows already in order are left alone');
});

test('each block wants room by what it holds', () => {
  const empty = need({ id: 'e', type: 'list', title: 'Goals', items: [] });
  const long = need(list('g', 9));
  assert.ok(long.h(600) > empty.h(600), 'a longer list wants to be taller');
  assert.ok(long.h(380) > long.h(1000), 'a list set in columns when wide is shorter');
  assert.ok(need(flow('f', 8)).idealW > need(flow('f', 3)).idealW, 'a longer flow wants more width');
  const half = need(list('g', 6), 0.5);
  assert.equal(half.minW, need(list('g', 6)).minW * 0.5, 'a density scales every size');
});

test('numbers read the way they were said and show the way a board says them; gridlines fall on round steps', () => {
  assert.deepEqual(['1,200', '$1.2k', '38%', '1.5M', '-4', 'many', '', 12].map(numberOf), [1200, 1200, 38, 1500000, -4, null, null, 12]);
  assert.deepEqual([shown(1200), shown(1250000, '$'), shown(38, '%'), shown(2.25), shown(140000), shown('x')],
    ['1,200', '$1.25M', '38%', '2.25', '140k', '—']);
  // A money unit with a size the numbers leave out puts both on each number, never twice.
  assert.deepEqual([shown(4.6, '$M'), shown(1900000, '$M'), shown(250, '$k'), shown(-2, '$k'), shown(340, 'leads'), shown(0, '$M')],
    ['$4.6M', '$1.9M', '$250k', '-$2k', '340', '$0']);
  assert.deepEqual([withUnit('4.6', '$M'), withUnit('340', 'leads'), withUnit('12', '%'), withUnit('7', '')],
    ['$4.6M', '340 leads', '12%', '7']);
  assert.deepEqual(ticks(0, 340), [0, 100, 200, 300, 400]);
  assert.deepEqual(ticks(0, 9), [0, 2, 4, 6, 8, 10]);
  assert.deepEqual(ticks(5, 5).slice(0, 2), [5, 5.2]);
});

test('an empty block says what to say to fill it', () => {
  assert.equal(ask({ type: 'list', kind: 'risks', title: 'Risks' }), 'Hey Hermes, add a risk: …');
  assert.match(ask({ type: 'chart', title: 'Signups' }), /^Hey Hermes, /);
});

test("a person's color is the same on every page", () => {
  assert.equal(personColor('abc'), personColor('abc'));
  assert.match(personColor('xyz'), /^#[0-9a-f]{6}$/);
});

test('the file kept in the notes draws every block, with ids unique, and a link to the next step on its own arrow', () => {
  assert.equal(wrap('one two three four', 9), 'one two\nthree\nfour');
  const board = { v: 2, title: 'Refunds', blocks: [
    { id: 'f', type: 'flow', title: 'Process', items: [{ id: 'a', text: 'Ask', shape: 'start' }, { id: 'b', text: 'Under $50?', shape: 'decision' },
      { id: 'c', text: 'Manager approves' }, { id: 'd', text: 'Pay' }],
    links: [{ from: 'b', to: 'c', label: 'No' }, { from: 'b', to: 'd', label: 'Yes' }] },
    { id: 't', type: 'timeline', title: 'Plan', items: [{ id: 'm', text: 'Beta', when: 'Jan 15', status: 'done' }] },
    chart('c'), list('g'),
    { id: 'tb', type: 'table', title: 'Candidates', columns: [{ id: 'p', name: 'Priya' }], pick: 'p', items: [{ id: 'cr', text: 'Craft', cells: { p: 5 } }] },
    { id: 'x', type: 'matrix', title: 'Fixes', x: { low: 'Low effort', high: 'High effort' }, y: { low: 'Low impact', high: 'High impact' },
      items: [{ id: 'q', text: 'Auto-approve', quadrant: 'tl' }] }] };
  const elements = scene(board);
  const ids = elements.map((e) => e.id).filter(Boolean);
  assert.equal(new Set(ids).size, ids.length, 'ids are unique');
  // Every item's box sits inside its block's, and no two overlap.
  const boxes = elements.filter((e) => e.type === 'rectangle' && e.id.startsWith('n:'));
  const blockOf = new Map(board.blocks.flatMap((b) => b.items.map((i) => [i.id, b.id])));
  for (const item of boxes) {
    const area = elements.find((e) => e.id === `b:${blockOf.get(item.id.split(':')[1])}`);
    assert.ok(item.x >= area.x && item.y >= area.y && item.x + item.width <= area.x + area.width
      && item.y + item.height <= area.y + area.height, `${item.id} inside its block`);
    for (const other of boxes) {
      if (other !== item) assert.ok(!overlap({ x: item.x, y: item.y, w: item.width, h: item.height }, { x: other.x, y: other.y, w: other.width, h: other.height }), `${item.id} and ${other.id}`);
    }
  }
  const said = JSON.stringify(elements);
  for (const words of ['Refunds', 'Process', 'Under $50?', 'Beta', 'Priya', 'Auto-approve', 'Low effort']) assert.ok(said.includes(words), words);
  // "No" rides the arrow from the decision to the next step; "Yes" is an arrow of its own.
  const order = elements.find((e) => e.id === 'f:c');
  assert.equal(order.label?.text, 'No');
  assert.ok(elements.some((e) => e.id === 'l:b>d' && e.label?.text === 'Yes'));
  assert.ok(!elements.some((e) => e.id === 'l:b>c'));
  assert.match(JSON.stringify(scene({ v: 2, title: 'Empty', blocks: [] })), /Nothing was put on this board/);
});

test('the richer pictures each want room by what they hold, and go into the notes file too', () => {
  const funnel = (n) => ({ id: 'fu', type: 'funnel', title: 'Pipeline', items: items(n, (i) => ({ value: 1000 - i * 200 })) });
  assert.ok(need(funnel(5)).h(800) > need(funnel(2)).h(800), 'more stages, taller');
  const donut = { id: 'd', type: 'chart', style: 'donut', title: 'Revenue', items: items(4, (i) => ({ value: 10 + i })) };
  assert.ok(need(donut).idealW >= 600, 'a donut wants room for its parts beside it');
  const heat = { id: 'h', type: 'chart', style: 'heatmap', title: 'By region', columns: [1, 2, 3, 4].map((q) => ({ id: `q${q}`, name: `Q${q}` })),
    items: items(4, () => ({ cells: { q1: 1, q2: 2, q3: 3, q4: 4 } })) };
  const roadmap = (lanes) => ({ id: 'r', type: 'roadmap', title: 'Plan', items: items(4, (i) => ({ lane: lanes ? `Team ${i % 2}` : '',
    start: '2027-01', end: '2027-03' })) });
  assert.ok(need(roadmap(false)).h(1000) > need(roadmap(true)).h(1000) - 80, 'bars that overlap stack in their lane');
  const tree = { id: 't', type: 'tree', title: 'Team', items: [{ id: 'a', text: 'Priya', note: 'Design lead' },
    ...items(8, () => ({ parent: 'a' })).map((i) => ({ ...i, id: `k${i.id}` }))] };
  assert.ok(need(tree).h(500) > need(tree).h(1600), 'a narrow org chart stacks its leaves, taller');
  const swim = { id: 's', type: 'swimlane', title: 'Refunds', items: items(4, (i) => ({ lane: ['Support', 'Finance'][i % 2] })) };
  const sketch = { id: 'k', type: 'sketch', title: 'Stripe', items: [], brief: 'x',
    svg: '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 800 600"><rect width="5" height="5"/></svg>' };
  assert.ok(Math.abs(need(sketch).h(600) - (56 + 40 + 560 * 0.75)) < 1, 'a picture keeps its own shape');
  assert.ok(need({ ...sketch, svg: undefined }).h(1000) > 400, 'a picture still being drawn has its room ready');
  const wide = { ...sketch, svg: '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1000 520"></svg>' };
  assert.equal(plan([wide], SCREEN).density, 1, 'a lone wide picture leaves the board at full size');
  const scorecard = { id: 'k2', type: 'stats', title: 'KPIs', items: [{ id: 'n', text: 'NRR', value: '112%', target: '115%', points: [1, 2, 3] }] };
  assert.ok(need(scorecard).h(600) > need({ ...scorecard, items: [{ id: 'n', text: 'NRR', value: '112%' }] }).h(600));
  const board = { v: 2, title: 'QBR', blocks: [funnel(3), donut, heat, roadmap(true), tree, swim, sketch,
    { id: 'st', type: 'chart', style: 'stacked', title: 'Mix', columns: [{ id: 'a', name: 'A' }, { id: 'b', name: 'B' }],
      items: items(2, () => ({ cells: { a: 3, b: 4 } })).map((i) => ({ ...i, id: `st${i.id}` })) }] };
  // Ids made unique across the board, as the room keeps them.
  board.blocks.forEach((b, k) => { b.items = b.items.map((i) => ({ ...i, id: `${k}${i.id}`, ...(i.parent ? { parent: `${k}${i.parent}` } : {}) })); });
  const elements = scene(board);
  const ids = elements.map((e) => e.id).filter(Boolean);
  assert.equal(new Set(ids).size, ids.length, 'ids are unique');
  const image = elements.find((e) => e.type === 'image');
  assert.equal(image.fileId, 'sketch-k');
  const file = files(board)['sketch-k'];
  assert.equal(file.mimeType, 'image/svg+xml');
  assert.match(Buffer.from(file.dataURL.split(',')[1], 'base64').toString(), /viewBox="0 0 800 600"/);
  const said = JSON.stringify(elements);
  for (const words of ['Pipeline', 'Team 0', 'Priya', 'Support', 'Q4']) assert.ok(said.includes(words), words);
});

test('a key number says how far it is from its target, never a percent of a percent', () => {
  const said = (value, target) => toTarget(value, target).words;
  assert.equal(said('$4.2M', '$4.5M'), '93% of target $4.5M');
  assert.equal(said('4.49', '4.5'), '99.7% of target 4.5');
  assert.equal(said('99.95%', '99.99%'), '0.04 below target 99.99%');
  assert.equal(said('98%', '99%'), '1 below target 99%');
  assert.equal(said('112%', '110%'), 'Target 110% met');
  assert.equal(said('soon', '110%'), 'Target 110%');
  assert.equal(toTarget('soon', '110%').share, null);
});

test('a roadmap end with no year of its own falls on or after the start', () => {
  const today = new Date(Date.UTC(2026, 10, 22));
  const days = (item) => {
    const { from, to } = spanOf(item, today);
    return [from, to].map((d) => new Date(d * 86400000).toISOString().slice(0, 10));
  };
  assert.deepEqual(days({ start: '2027-01', end: 'December' }), ['2027-01-01', '2027-12-31']);
  assert.deepEqual(days({ start: 'Nov', end: 'Feb' }), ['2026-11-01', '2027-02-28']);
  assert.deepEqual(days({ start: 'Jan', end: 'March' }), ['2027-01-01', '2027-03-31']);
  assert.deepEqual(days({ start: 'Mar 15 2027', end: 'March' }), ['2027-03-15', '2027-03-31']);
  assert.deepEqual(days({ start: 'Q2 2027', end: 'Q1' }), ['2027-04-01', '2028-03-31']);
  assert.deepEqual(days({ start: 'Jan', end: 'March 2028' }), ['2027-01-01', '2028-03-31']);
  assert.deepEqual(days({ start: 'Jan' }), ['2027-01-01', '2027-01-31']);
});

// Half the shared screen, beside another board.
const HALF = { width: 590, height: 494 };
const whole = (blocks, got) => got.places.every((place) => {
  const block = blocks.find((b) => b.id === place.id);
  return place.h >= need(block, got.density, { open: true }).h(place.w) - 6;
});

test('beside another board, blocks that do not fit whole fold into a row of names, rather than shrink or get cut', () => {
  const blocks = [flow('f', 6), chart('c'), list('g', 3), list('r', 2, 'risks')];
  const got = plan(blocks, { ...HALF, fold: true });
  assert.ok(got.folded.length > 0 && got.folded.length < blocks.length);
  const shown = blocks.filter((b) => !got.folded.includes(b.id));
  assert.equal(got.places.length, shown.length);
  assert.ok(got.density >= DENSITIES.at(-1));
  assert.ok(got.height <= HALF.height - FOLD_H + 1, 'room is left for the row of names');
  assert.ok(whole(shown, got), 'every block shown is drawn whole');
  // Those shown stay in the board's order.
  assert.deepEqual(got.places.map((p) => p.id), shown.map((b) => b.id));
  // A board that fits folds nothing; alone on screen, nothing ever folds.
  assert.deepEqual(plan([list('g'), list('r', 1, 'risks')], { ...HALF, fold: true }).folded, []);
  assert.deepEqual(plan(blocks, { width: 1232, height: 556 }).folded, []);
});

test('beside another board, the block changed last stays in view; one too big for the half folds, never cut short', () => {
  const blocks = [flow('f', 6), chart('c'), list('g', 3), list('r', 2, 'risks')];
  const first = plan(blocks, { ...HALF, fold: true });
  const last = first.folded.at(-1);
  const got = plan(blocks, { ...HALF, fold: true, recent: [last] });
  assert.ok(!got.folded.includes(last));
  assert.ok(whole(blocks.filter((b) => !got.folded.includes(b.id)), got));
  // Changed last, but too tall for the half even alone: it folds, and the block that fits is shown whole.
  const long = { id: 'long', type: 'list', title: 'Long', kind: 'notes', items: items(12).map((i) => ({ ...i, text: `${i.text} `.repeat(6) })) };
  const folded = plan([long, list('g')], { ...HALF, fold: true, recent: ['long'] });
  assert.deepEqual([folded.places.map((p) => p.id), folded.folded], [['g'], ['long']]);
  assert.ok(whole([list('g')], folded));
  // Nothing fits: every block folds, and none is drawn.
  const none = plan([long, { ...long, id: 'long2' }], { ...HALF, fold: true });
  assert.deepEqual([none.places, none.folded], [[], ['long', 'long2']]);
});

test("a board's name is its title, or what its first block is called until it has one", () => {
  assert.equal(boardName({ title: 'Pricing', blocks: [] }), 'Pricing');
  assert.equal(boardName({ title: 'Whiteboard', blocks: [{ title: '' }, { title: 'Launch plan' }] }), 'Launch plan');
  assert.equal(boardName({ title: 'Whiteboard', blocks: [] }), 'New board');
  assert.equal(boardName(null), 'New board');
});

test('the screen shows one board, two side by side, or all of them; anything else is one board', () => {
  assert.deepEqual(fitView({ mode: 'split', boards: [3, 1] }, 3), { mode: 'split', boards: [3, 1] });
  assert.deepEqual(fitView({ mode: 'split', boards: ['2', '1'] }, 2), { mode: 'split', boards: [2, 1] });
  for (const view of [{ mode: 'split', boards: [1, 1] }, { mode: 'split', boards: [1, 4] }, { mode: 'split', boards: [1, 2, 3] },
    { mode: 'split' }, { mode: 'all' }, { mode: 'grid' }, null]) assert.deepEqual(fitView(view, 1), { mode: 'one' }, JSON.stringify(view));
  assert.deepEqual(fitView({ mode: 'all' }, 2), { mode: 'all' });
});

test('a page shows what the room has on screen; on the link, a tab picked there wins until the next change of view', () => {
  const split = { mode: 'split', boards: [1, 3] };
  assert.deepEqual(pageView({ count: 3, current: 3, view: split, follows: true }), { mode: 'split', boards: [1, 3], target: 3 });
  assert.deepEqual(pageView({ count: 3, current: 2, view: split, follows: true }).target, 1, 'a target off screen is the left board');
  assert.deepEqual(pageView({ count: 3, current: 2, view: { mode: 'all' }, follows: true }), { mode: 'all', boards: [1, 2, 3], target: 2 });
  assert.deepEqual(pageView({ count: 3, current: 2, view: split, viewing: 3 }), { mode: 'one', boards: [3], target: 3 });
  assert.deepEqual(pageView({ count: 3, current: 2, view: split, viewing: 3, follows: true }).mode, 'split', 'the screen never picks');
  // Nothing on screen: the shared screen shows nothing, the link the board shown last.
  assert.deepEqual(pageView({ count: 2, current: null, last: 2, follows: true }), { mode: 'none', boards: [], target: null });
  assert.deepEqual(pageView({ count: 2, current: null, last: 2 }), { mode: 'one', boards: [2], target: 2 });
  assert.deepEqual(pageView({ count: 0 }), { mode: 'none', boards: [], target: null });
});

test('every board at once fills the stage with the biggest pictures; the tabs mark the boards on screen and the target', () => {
  const stage = { width: 1208, height: 548, aspect: 1208 / 548 };
  assert.deepEqual([2, 4, 6, 9].map((n) => { const g = grid(n, stage); return [g.columns, g.rows]; }), [[2, 1], [2, 2], [3, 2], [3, 3]]);
  assert.deepEqual(tabStates(3, { mode: 'split', boards: [3, 1], target: 1 }), [
    { n: 1, on: true, target: true, side: 'right' }, { n: 2, on: false, target: false, side: null },
    { n: 3, on: true, target: false, side: 'left' }]);
  assert.deepEqual(tabStates(2, { mode: 'all', boards: [1, 2], target: 2 }).map((t) => t.on), [false, false]);
  assert.deepEqual(tabStates(2, { mode: 'one', boards: [2], target: 2 }).map((t) => [t.on, t.target]), [[false, false], [true, false]]);
});
