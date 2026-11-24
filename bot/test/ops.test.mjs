// Edits to a whiteboard, as the board room applies them one at a time. Run: node --test bot/test/
import test from 'node:test';
import assert from 'node:assert/strict';
import { apply, clean, emptyBoard, guessKind, LIMITS, recap, recapText } from '../src/ops.js';

// A board after edits that must all be accepted.
function after(board, ...ops) {
  for (const op of ops) {
    const result = apply(board, op);
    assert.ok(!result.error, `${op.op} ${op.id || ''}: ${result.error}`);
    board = result.board;
  }
  return board;
}

const launch = () => after(emptyBoard('Launch'),
  { op: 'block', id: 'goals', type: 'list', title: 'Goals' },
  { op: 'item', id: 'g1', block: 'goals', text: 'Ten paying pilots' },
  { op: 'block', id: 'signups', type: 'chart', title: 'Signups', unit: 'signups' },
  { op: 'item', id: 'oct', block: 'signups', text: 'October', value: 120 },
  { op: 'item', id: 'nov', block: 'signups', text: 'November', value: '180' });

test('a board starts empty and grows block by block; each edit builds on what is there and says what it did', () => {
  assert.deepEqual(emptyBoard('Launch'), { v: 2, title: 'Launch', blocks: [] });
  const board = launch();
  assert.deepEqual(board.blocks.map((b) => [b.id, b.type, b.items.map((i) => i.id)]),
    [['goals', 'list', ['g1']], ['signups', 'chart', ['oct', 'nov']]]);
  assert.equal(board.blocks[0].kind, 'goals');
  assert.equal(board.blocks[1].items[1].value, 180);
  // "Add January": one more bar on the same chart, and the board it was given is never changed.
  const more = apply(board, { op: 'item', id: 'jan', block: 'signups', text: 'January', value: '340' });
  assert.deepEqual(more.changed, ['jan']);
  assert.equal(more.what, 'Added “January” to Signups, 340 signups');
  assert.equal(more.added, 'Signups');
  assert.deepEqual(more.board.blocks[1].items.map((i) => i.value), [120, 180, 340]);
  assert.equal(board.blocks[1].items.length, 2);
  // A new block goes after the last unless told where; its result names it.
  const timeline = apply(board, { op: 'block', id: 'plan', type: 'timeline', title: 'Launch plan', after: 'first' });
  assert.equal(timeline.what, 'Added the timeline “Launch plan”');
  assert.equal(timeline.block, 'Launch plan');
  assert.deepEqual(timeline.board.blocks.map((b) => b.id), ['plan', 'goals', 'signups']);
  // An item goes where it is told in its block, and moves between blocks, keeping only the fields its new block uses.
  const placed = after(board, { op: 'item', id: 'sep', block: 'signups', text: 'September', value: 90, after: 'first' },
    { op: 'item', id: 'g2', block: 'goals', text: 'Churn under 3%', after: 'first' });
  assert.deepEqual(placed.blocks.map((b) => b.items.map((i) => i.id)), [['g2', 'g1'], ['sep', 'oct', 'nov']]);
  const moved = apply(placed, { op: 'item', id: 'oct', block: 'goals' });
  assert.deepEqual(moved.board.blocks[0].items.at(-1), { id: 'oct', text: 'October' });
  assert.equal(moved.what, 'Changed “October”: moved to Goals');
});

test('each block type keeps its own fields, checked', () => {
  const board = after(emptyBoard(),
    { op: 'block', id: 'f', type: 'flow', title: 'Refunds' },
    { op: 'item', id: 's1', block: 'f', text: 'Customer asks', shape: 'start' },
    { op: 'item', id: 's2', block: 'f', text: 'Under $50?', shape: 'decision' },
    { op: 'item', id: 's3', block: 'f', text: 'Manager approves', shape: 'step' },
    { op: 'link', from: 's2', to: 's3', label: 'No' },
    { op: 'block', id: 't', type: 'timeline' },
    { op: 'item', id: 'm1', block: 't', text: 'Beta', when: 'Jan 15', status: 'NOW' },
    { op: 'block', id: 'c', type: 'table', title: 'Candidates', columns: [{ id: 'priya', name: 'Priya' }, { id: 'sam', name: 'Sam' }] },
    { op: 'item', id: 'craft', block: 'c', text: 'Craft', cells: { priya: 5, sam: 'Strong' } },
    { op: 'block', id: 'x', type: 'matrix', x: { low: 'Low effort', high: 'High effort' }, quadrants: { tl: 'Quick wins' } },
    { op: 'item', id: 'auto', block: 'x', text: 'Auto-approve small refunds', quadrant: 'tl' },
    { op: 'block', id: 'mm', type: 'mindmap', title: 'Ideas' },
    { op: 'item', id: 'b1', block: 'mm', text: 'Pricing' },
    { op: 'item', id: 'b2', block: 'mm', text: 'Annual plan', parent: 'b1' },
    { op: 'block', id: 'k', type: 'stats', title: 'Numbers' },
    { op: 'item', id: 'k1', block: 'k', text: 'Refunds last month', value: '340', note: 'up from 290', trend: 'up' });
  const byId = Object.fromEntries(board.blocks.map((b) => [b.id, b]));
  assert.deepEqual(byId.f.items.map((i) => i.shape), ['start', 'decision', undefined]);
  assert.deepEqual(byId.f.links, [{ from: 's2', to: 's3', label: 'No' }]);
  assert.equal(byId.t.title, 'Timeline');
  assert.deepEqual(byId.t.items[0], { id: 'm1', text: 'Beta', when: 'Jan 15', status: 'now' });
  assert.deepEqual(byId.c.items[0].cells, { priya: 5, sam: 'Strong' });
  assert.deepEqual(byId.x.x, { low: 'Low effort', high: 'High effort' });
  assert.equal(byId.x.items[0].quadrant, 'tl');
  assert.equal(byId.mm.items[1].parent, 'b1');
  assert.deepEqual(byId.k.items[0], { id: 'k1', text: 'Refunds last month', value: '340', note: 'up from 290', trend: 'up' });
  // A field another type uses is not kept.
  assert.equal(after(board, { op: 'item', id: 'g', block: 'k', text: 'x', owner: 'Lee', quadrant: 'tl' }).blocks.at(-1).items.at(-1).owner,
    undefined);
  // A comparison's pick names one of its options, and says so.
  const picked = apply(board, { op: 'block', id: 'c', pick: 'priya' });
  assert.equal(picked.board.blocks[2].pick, 'priya');
  assert.equal(picked.what, 'Picked “Priya” in Candidates');
  assert.equal(apply(board, { op: 'block', id: 'c', columns: [{ id: 'alex', name: 'Alex' }] }).what, 'Added “Alex” to Candidates');
});

test('an edit that cannot be done is refused and leaves the board as it was', () => {
  const board = launch();
  const refusals = [
    [{ op: 'block', id: 'b', type: 'spiral' }, /type must be one of/],
    [{ op: 'block', id: '' }, /needs an id/],
    [{ op: 'block', id: 'g1', type: 'list' }, /already used/],
    [{ op: 'block', id: 'goals', kind: 'scary' }, /kind must be/],
    [{ op: 'block', id: 'signups', style: 'spiral' }, /style must be/],
    [{ op: 'block', id: 'n', type: 'list', after: 'nowhere' }, /no block nowhere/],
    [{ op: 'item', id: 'x', block: 'nowhere', text: 'x' }, /no block nowhere/],
    [{ op: 'item', id: 'x', block: 'goals', text: '   ' }, /needs words/],
    [{ op: 'item', id: 'goals', block: 'goals', text: 'x' }, /already used/],
    [{ op: 'item', id: 'x', block: 'signups', text: 'x', value: 'lots' }, /needs a number/],
    [{ op: 'item', id: 'x', block: 'goals', text: 'x', after: 'oct' }, /no item oct in Goals/],
    [{ op: 'link', from: 'g1', to: 'oct' }, /two different items of one block/],
    [{ op: 'link', from: 'oct', to: 'nov' }, /links join the steps of a flow/],
    [{ op: 'remove', id: 'ghost' }, /nothing called ghost/],
    [{ op: 'title', text: '' }, /needs words/],
    [{ op: 'send_email' }, /unknown edit/],
    [{ op: '__proto__' }, /unknown edit/],
  ];
  for (const [op, error] of refusals) {
    const result = apply(board, op);
    assert.match(result.error || '', error, JSON.stringify(op));
    assert.equal(result.board, undefined);
  }
  const mind = after(emptyBoard(), { op: 'block', id: 'm', type: 'mindmap' }, { op: 'item', id: 'a', block: 'm', text: 'A' },
    { op: 'item', id: 'b', block: 'm', text: 'B', parent: 'a' });
  assert.match(apply(mind, { op: 'item', id: 'a', parent: 'b' }).error, /cannot hang from itself/);
});

test('the limits hold: blocks, items per block, items in all, columns and links', () => {
  let board = emptyBoard();
  for (let b = 0; b < LIMITS.blocks; b++) board = after(board, { op: 'block', id: `b${b}`, type: 'list', title: `B${b}` });
  assert.match(apply(board, { op: 'block', id: 'more', type: 'list' }).error, /at most 6 blocks/);
  for (let i = 0; i < LIMITS.items; i++) board = after(board, { op: 'item', id: `a${i}`, block: 'b0', text: 'x' });
  assert.match(apply(board, { op: 'item', id: 'more', block: 'b0', text: 'x' }).error, /at most 12 items/);
  for (let b = 1; b < 4; b++) {
    for (let i = 0; i < LIMITS.items; i++) board = after(board, { op: 'item', id: `n${b}-${i}`, block: `b${b}`, text: 'x' });
  }
  assert.match(apply(board, { op: 'item', id: 'one-more', block: 'b4', text: 'x' }).error, /at most 48 items/);
  let table = after(emptyBoard(), { op: 'block', id: 't', type: 'table' });
  for (let c = 0; c < LIMITS.columns; c++) table = after(table, { op: 'block', id: 't', columns: [{ id: `c${c}`, name: `C${c}` }] });
  assert.match(apply(table, { op: 'block', id: 't', columns: [{ id: 'c9', name: 'C9' }] }).error, /at most 5 columns/);
  let flow = after(emptyBoard(), { op: 'block', id: 'f', type: 'flow' });
  for (let i = 0; i < LIMITS.items; i++) flow = after(flow, { op: 'item', id: `s${i}`, block: 'f', text: 'x' });
  for (let i = 0; i < LIMITS.links; i++) flow = after(flow, { op: 'link', from: `s${i}`, to: `s${(i + 2) % LIMITS.items}` });
  assert.match(apply(flow, { op: 'link', from: 's0', to: 's5' }).error, /at most 12 links/);
});

test('a board from before blocks keeps every section and note, up to the old limits; edits still add blocks only to six', () => {
  // The most a board held before blocks: 8 sections, 40 notes in all, 10 in one.
  const sections = Array.from({ length: 8 }, (_, s) => ({ id: `s${s}`, title: `Section ${s}`,
    notes: Array.from({ length: s ? 4 : 10 }, (_, n) => ({ id: `s${s}n${n}`, text: `Note ${n} of ${s}` })) }));
  const old = clean({ title: 'Big retro', layout: 'columns', sections, arrows: [] });
  assert.equal(old.blocks.length, LIMITS.kept);
  assert.deepEqual(old.blocks.map((b) => b.items.length), sections.map((s) => s.notes.length));
  assert.equal(old.blocks.flatMap((b) => b.items).length, sections.flatMap((s) => s.notes).length);
  assert.deepEqual(clean(old), old, 'cleaned again, nothing goes');
  assert.match(apply(old, { op: 'block', id: 'more', type: 'list' }).error, /at most 6 blocks/);
  assert.ok(!apply(old, { op: 'item', id: 'x', block: 's7', text: 'One more' }).error, 'its blocks still take items');
});

test('rearranging moves one item or block at a time, so every item is still there, once', () => {
  let board = after(emptyBoard(), { op: 'block', id: 'now', type: 'list', title: 'Now' }, { op: 'block', id: 'later', type: 'list', title: 'Later' },
    ...['a', 'b', 'c'].map((id) => ({ op: 'item', id, block: 'now', text: id.toUpperCase() })),
    { op: 'item', id: 'd', block: 'later', text: 'D' });
  board = after(board, { op: 'item', id: 'c', after: 'first' }, { op: 'item', id: 'a', block: 'later', after: 'first' },
    { op: 'block', id: 'later', after: 'first' });
  assert.deepEqual(board.blocks.map((b) => [b.id, b.items.map((i) => i.id)]), [['later', ['a', 'd']], ['now', ['c', 'b']]]);
  const ids = board.blocks.flatMap((b) => b.items.map((i) => i.id));
  assert.deepEqual(ids.toSorted(), ['a', 'b', 'c', 'd']);
  // A move that cannot be done leaves everything where it was.
  assert.match(apply(board, { op: 'item', id: 'b', block: 'nowhere' }).error, /no block/);
});

test('texts are cut to size and ids keep only safe characters', () => {
  const board = after(emptyBoard(), { op: 'block', id: 'a b<script>', type: 'list', title: 'x'.repeat(100) },
    { op: 'item', id: 'n"1', block: 'abscript', text: 'word '.repeat(50) });
  assert.equal(board.blocks[0].id, 'abscript');
  assert.equal(board.blocks[0].title.length, 40);
  assert.equal(board.blocks[0].items[0].id, 'n1');
  assert.ok(board.blocks[0].items[0].text.length <= 90);
});

test('removing takes what hangs from it: a block its items, a step its links, a branch its twigs, a column its cells', () => {
  const board = after(emptyBoard(),
    { op: 'block', id: 'f', type: 'flow' }, { op: 'item', id: 'a', block: 'f', text: 'A' },
    { op: 'item', id: 'b', block: 'f', text: 'B' }, { op: 'item', id: 'c', block: 'f', text: 'C' },
    { op: 'link', from: 'a', to: 'c', label: 'Yes' },
    { op: 'block', id: 'm', type: 'mindmap', title: 'Ideas' }, { op: 'item', id: 'p', block: 'm', text: 'Pricing' },
    { op: 'item', id: 'q', block: 'm', text: 'Annual', parent: 'p' }, { op: 'item', id: 'r', block: 'm', text: 'Promo', parent: 'q' },
    { op: 'item', id: 's', block: 'm', text: 'Hiring' },
    { op: 'block', id: 't', type: 'table', title: 'Vendors', columns: [{ id: 'v1', name: 'Acme' }, { id: 'v2', name: 'Bolt' }], pick: 'v1' },
    { op: 'item', id: 'cost', block: 't', text: 'Cost', cells: { v1: 3, v2: 4 } });
  const step = apply(board, { op: 'remove', id: 'c' });
  assert.equal(step.board.blocks[0].links, undefined);
  const branch = apply(board, { op: 'remove', id: 'p' });
  assert.deepEqual(branch.board.blocks[1].items.map((i) => i.id), ['s']);
  assert.equal(branch.what, 'Removed “Pricing” from Ideas and 2 items under it');
  const column = apply(board, { op: 'remove', id: 'v1' });
  assert.deepEqual(column.board.blocks[2].columns, [{ id: 'v2', name: 'Bolt' }]);
  assert.equal(column.board.blocks[2].pick, undefined);
  assert.deepEqual(column.board.blocks[2].items[0].cells, { v2: 4 });
  const block = apply(board, { op: 'remove', id: 'f' });
  assert.deepEqual(block.board.blocks.map((b) => b.id), ['m', 't']);
  assert.equal(block.what, 'Removed “Steps” and its 3 items');
  assert.deepEqual(apply(board, { op: 'clear' }).board.blocks, []);
});

test('a change says only what it changed', () => {
  const board = after(emptyBoard(),
    { op: 'block', id: 't', type: 'timeline', title: 'Plan' },
    { op: 'item', id: 'beta', block: 't', text: 'Private beta', when: 'Jan 15', status: 'next' },
    { op: 'block', id: 'c', type: 'table', title: 'Candidates', columns: [{ id: 'priya', name: 'Priya' }, { id: 'sam', name: 'Sam' }] },
    { op: 'item', id: 'craft', block: 'c', text: 'Craft', cells: { sam: 3 } },
    { op: 'block', id: 'a', type: 'list', title: 'Owners', kind: 'actions' },
    { op: 'item', id: 'h', block: 'a', text: 'Hire a designer', owner: 'Lee' },
    { op: 'block', id: 'f', type: 'flow' }, { op: 'item', id: 's1', block: 'f', text: 'Ask' }, { op: 'item', id: 's2', block: 'f', text: 'Pay' });
  assert.equal(apply(board, { op: 'item', id: 'beta', status: 'done' }).what, 'Changed “Private beta”: done');
  assert.equal(apply(board, { op: 'item', id: 'craft', cells: { priya: 5 } }).what, 'Changed “Craft”: Priya 5');
  assert.equal(apply(board, { op: 'item', id: 'h', owner: '' }).what, 'Changed “Hire a designer”: no owner yet');
  assert.equal(apply(board, { op: 'item', id: 'h', text: 'Hire two designers' }).what, 'Changed “Hire a designer”: now “Hire two designers”');
  assert.equal(apply(board, { op: 'item', id: 'h', due: 'Fri Dec 5' }).what, 'Changed “Hire a designer”: due Fri Dec 5');
  assert.equal(apply(board, { op: 'block', id: 't', title: 'Launch plan' }).what, 'Renamed “Plan” to “Launch plan”');
  assert.equal(apply(board, { op: 'block', id: 't', type: 'list' }).what, 'Made “Plan” a list');
  const linked = apply(board, { op: 'link', from: 's2', to: 's1', label: 'Retry' });
  assert.equal(linked.what, 'Joined “Pay” to “Ask” (Retry)');
  assert.equal(linked.joined, 'Steps');
  assert.equal(apply(linked.board, { op: 'unlink', from: 's2', to: 's1' }).what, 'Took away the link from “Pay” to “Ask”');
  assert.equal(apply(board, { op: 'title', text: 'Q1 launch' }).what, 'Named the board “Q1 launch”');
});

test('a list has a kind, given or taken from its title, and its items carry owners, due dates and risk levels', () => {
  assert.deepEqual(['Goals', 'Open risks', 'Next steps', 'What we decided', 'Pros', 'Cons', 'Went well', 'Ideas']
    .map(guessKind), ['goals', 'risks', 'actions', 'decisions', 'pros', 'cons', 'pros', 'notes']);
  const board = after(emptyBoard('Launch'), { op: 'block', id: 'a', type: 'list', title: 'Owners', kind: 'actions' },
    { op: 'block', id: 'r', type: 'list', title: 'Risks' });
  assert.deepEqual(board.blocks.map((b) => b.kind), ['actions', 'risks']);
  const added = apply(board, { op: 'item', id: 'h', block: 'a', text: 'Hire a contract designer', owner: 'Lee', due: 'Fri Dec 5' });
  assert.deepEqual(added.board.blocks[0].items, [{ id: 'h', text: 'Hire a contract designer', owner: 'Lee', due: 'Fri Dec 5' }]);
  assert.equal(added.what, 'Added “Hire a contract designer” to Owners, owner Lee, due Fri Dec 5');
  assert.equal(apply(board, { op: 'item', id: 'b', block: 'a', text: 'Book the call' }).what, 'Added “Book the call” to Owners, no owner yet');
  const risk = apply(board, { op: 'item', id: 'd', block: 'r', text: 'Only one designer', level: 'HIGH' });
  assert.equal(risk.board.blocks[1].items[0].level, 'high');
  assert.match(apply(board, { op: 'item', id: 'd', block: 'r', text: 'x', level: 'extreme' }).error, /level must be/);
  assert.equal(apply(risk.board, { op: 'remove', id: 'r' }).what, 'Removed “Risks” and its 1 item');
});

test('a board from anywhere is cleaned to what the page can draw, and one from before blocks becomes lists', () => {
  const board = clean({ v: 2, title: '  Launch   plan ', blocks: [
    { id: 'risks list', type: 'list', title: 'Risks', items: [{ id: 'r1', text: 'Vendor slips', level: 'high', value: 3 },
      { id: 'r1', text: 'Dupe' }, { id: 'r3', text: '' }, null] },
    { id: 'c', type: 'chart', title: 'Signups', items: [{ id: 'm', text: 'May', value: '1.2k' }, { id: 'j', text: 'June', value: 'many' }] },
    { id: 'f', type: 'flow', items: [{ id: 'a', text: 'A' }, { id: 'b', text: 'B' }], links: [{ from: 'a', to: 'b' }, { from: 'a', to: 'z' }] },
    { id: 'w', type: 'spiral', items: [] }, 'not a block'] });
  assert.deepEqual(board, { v: 2, title: 'Launch plan', blocks: [
    // A second item with an id already used changes the first, as a second edit would.
    { id: 'riskslist', type: 'list', title: 'Risks', kind: 'risks', items: [{ id: 'r1', text: 'Dupe', level: 'high' }] },
    { id: 'c', type: 'chart', title: 'Signups', items: [{ id: 'm', text: 'May', value: 1200 }] },
    { id: 'f', type: 'flow', title: 'Steps', items: [{ id: 'a', text: 'A' }, { id: 'b', text: 'B' }], links: [{ from: 'a', to: 'b' }] }] });
  assert.deepEqual(clean(null), emptyBoard());
  // Cleaning a clean board changes nothing.
  assert.deepEqual(clean(board), board);
  // A board from before blocks, as a call under way when this changed still has it.
  const old = clean({ title: 'Retro', layout: 'columns', sections: [
    { id: 'w', title: 'Went well', notes: [{ id: 'n1', text: 'Shipped on time', color: 'green' }] },
    { id: 'a', title: 'Action items', notes: [{ id: 'n2', text: 'Fix the build', owner: 'Kim' }] }], arrows: [] });
  assert.deepEqual(old.blocks.map((b) => [b.type, b.kind, b.items]),
    [['list', 'pros', [{ id: 'n1', text: 'Shipped on time' }]], ['list', 'actions', [{ id: 'n2', text: 'Fix the build', owner: 'Kim' }]]]);
  // ...and an edit from before blocks still lands: a section is a list, a note its item.
  const edited = after(old, { op: 'section', id: 'r', title: 'Risks' }, { op: 'note', id: 'n3', section: 'r', text: 'Flaky CI' });
  assert.deepEqual(edited.blocks.at(-1), { id: 'r', type: 'list', title: 'Risks', kind: 'risks', items: [{ id: 'n3', text: 'Flaky CI' }] });
});

test("the recap gathers every board's action items, decisions and open risks, and leaves out an earlier recap", () => {
  const one = after(emptyBoard('Launch'), { op: 'block', id: 'a', type: 'list', title: 'Action items' },
    { op: 'block', id: 'r', type: 'list', title: 'Risks' }, { op: 'block', id: 'g', type: 'list', title: 'Goals' },
    { op: 'block', id: 'c', type: 'chart', title: 'Signups' }, { op: 'item', id: 'may', block: 'c', text: 'May', value: 3 },
    { op: 'item', id: 'h', block: 'a', text: 'Hire a designer', owner: 'Lee', due: 'Fri Dec 5' },
    { op: 'item', id: 'b', block: 'a', text: 'Book the review' }, { op: 'item', id: 'x', block: 'r', text: 'One designer', level: 'high' },
    { op: 'item', id: 'y', block: 'g', text: '10 pilots' });
  const two = after(emptyBoard('Pricing'), { op: 'block', id: 'd', type: 'list', title: 'Decisions' },
    { op: 'item', id: 'w', block: 'd', text: 'Web first' });
  const made = recap([one, two, { ...one, recap: true }]);
  assert.equal(made.recap, true);
  assert.deepEqual(made.blocks.map((b) => [b.title, b.kind, b.items.map((n) => n.text)]),
    [['Action items', 'actions', ['Hire a designer', 'Book the review']], ['Open risks', 'risks', ['One designer']],
      ['Decisions', 'decisions', ['Web first']]]);
  assert.deepEqual(made.blocks[0].items[0], { id: 'a1', text: 'Hire a designer', owner: 'Lee', due: 'Fri Dec 5' });
  assert.equal(recapText(made), 'Recap. Action items: Hire a designer (Lee, due Fri Dec 5); Book the review (no owner). '
    + 'Open risks: One designer (high). Decided: Web first.');
  assert.equal(recapText(made, 40).length, 40);
  assert.equal(recap([emptyBoard('Nothing')]), null);
  // An item added to the recap by hand stays when it is made again; one from a board is not doubled.
  const added = after(made, { op: 'item', id: 'x1', block: 'actions', text: 'Send the deck' },
    { op: 'item', id: 'x2', block: 'actions', text: 'Hire a designer' });
  assert.deepEqual(recap([one, two], added).blocks[0].items.map((n) => n.text),
    ['Hire a designer', 'Book the review', 'Send the deck']);
  // A change made on the recap stays when it is made again; a copy whose board dropped it goes.
  const assigned = after(made, { op: 'item', id: 'a2', owner: 'Kim', due: 'Mon' });
  const dropped = after(two, { op: 'remove', id: 'w' });
  const again = recap([one, dropped], assigned);
  assert.deepEqual(again.blocks[0].items[1], { id: 'a2', text: 'Book the review', owner: 'Kim', due: 'Mon' });
  assert.deepEqual(again.blocks[2].items, []);
  // ...and still stays when the recap is made again and again, as does an item added on it.
  const twice = recap([one, dropped], after(again, { op: 'item', id: 'x9', block: 'risks', text: 'Budget' }));
  const thrice = recap([one, dropped], twice);
  assert.deepEqual(thrice.blocks[0].items[1], { id: 'a2', text: 'Book the review', owner: 'Kim', due: 'Mon' });
  assert.deepEqual(thrice.blocks[1].items.map((n) => n.text), ['One designer', 'Budget']);
  // A copy taken off the recap stays off, until its board changes it.
  const cut = after(thrice, { op: 'remove', id: 'a1' });
  assert.deepEqual(recap([one, dropped], recap([one, dropped], cut)).blocks[0].items.map((n) => n.text), ['Book the review']);
  const redone = after(one, { op: 'item', id: 'h', due: 'Mon Dec 8' });
  assert.equal(recap([redone, dropped], cut).blocks[0].items[0].due, 'Mon Dec 8');
  // Two boards with the same task, both copies taken off: both stay off.
  const same = after(emptyBoard('Same'), { op: 'block', id: 'a', type: 'list', title: 'Action items' },
    { op: 'item', id: 'h', block: 'a', text: 'Hire a designer', owner: 'Lee', due: 'Fri Dec 5' });
  const both = recap([one, same]);
  const neither = after(both, { op: 'remove', id: 'a1' }, { op: 'remove', id: 'a3' });
  assert.deepEqual(recap([one, same], recap([one, same], neither)).blocks[0].items.map((n) => n.text), ['Book the review']);
  // A copy nobody touched follows its board's changes; the memory of what was copied survives a trip through clean().
  const moved = after(one, { op: 'item', id: 'h', owner: 'Ana' });
  assert.equal(recap([moved, two], clean(made)).blocks[0].items[0].owner, 'Ana');
  // More than a list holds: the last line says how many more.
  const many = after(emptyBoard('Lots'), { op: 'block', id: 'a', type: 'list', title: 'Action items' },
    ...Array.from({ length: 12 }, (_, i) => ({ op: 'item', id: `t${i}`, block: 'a', text: `Task ${i}` })));
  const big = recap([many, one]).blocks[0].items;
  assert.deepEqual([big.length, big.at(-1).text], [12, '+3 more on the boards']);
  // A recap from before blocks (sections) is made again as blocks, keeping what was changed on it.
  const oldRecap = { title: 'Recap', recap: true, copied: { a1: { text: 'Hire a designer', owner: 'Lee', due: 'Fri Dec 5' } },
    sections: [{ id: 'actions', title: 'Action items', kind: 'actions', notes: [{ id: 'a1', text: 'Hire a designer', owner: 'Max' }] }] };
  assert.equal(recap([one], oldRecap).blocks[0].items[0].owner, 'Max');
});

test('the richer pictures keep their own fields: a funnel its counts, a roadmap its dates and lanes, a tree its parents', () => {
  let board = after(emptyBoard('QBR'),
    { op: 'block', id: 'fun', type: 'funnel', title: 'Pipeline', unit: 'deals' },
    { op: 'item', id: 'leads', block: 'fun', text: 'Leads', value: '1,800' },
    { op: 'item', id: 'won', block: 'fun', text: 'Won', value: 240 },
    { op: 'block', id: 'rm', type: 'roadmap', title: 'Roadmap' },
    { op: 'item', id: 'pay', block: 'rm', text: 'Payments', lane: 'Platform', start: 'Q1 2027', end: 'March 2027', status: 'now' },
    { op: 'block', id: 'org', type: 'tree', title: 'Team' },
    { op: 'item', id: 'pri', block: 'org', text: 'Priya', note: 'Head of design' },
    { op: 'item', id: 'sam', block: 'org', text: 'Sam', parent: 'pri' },
    { op: 'block', id: 'sw', type: 'swimlane', title: 'Refunds' },
    { op: 'item', id: 's1', block: 'sw', text: 'Takes the request', lane: 'Support' },
    { op: 'item', id: 's2', block: 'sw', text: 'Approves it', lane: 'Finance', shape: 'decision' },
    { op: 'link', from: 's2', to: 's1', label: 'No' },
    { op: 'block', id: 'kpi', type: 'stats', title: 'Key numbers' },
    { op: 'item', id: 'nrr', block: 'kpi', text: 'Net retention', value: '112%', target: '115%', points: '104, 108, 110, 112' });
  const [fun, rm, org, sw, kpi] = board.blocks;
  assert.deepEqual(fun.items.map((i) => i.value), [1800, 240]);
  assert.equal(fun.unit, 'deals');
  assert.deepEqual([rm.items[0].lane, rm.items[0].start, rm.items[0].end, rm.items[0].status], ['Platform', 'Q1 2027', 'March 2027', 'now']);
  assert.equal(org.items[1].parent, 'pri');
  assert.equal(org.items[0].note, 'Head of design');
  assert.deepEqual(sw.links, [{ from: 's2', to: 's1', label: 'No' }]);
  assert.deepEqual(kpi.items[0].points, [104, 108, 110, 112]);
  assert.equal(kpi.items[0].target, '115%');
  // Only fields the type takes, each checked.
  assert.match(apply(board, { op: 'item', id: 'x', block: 'rm', text: 'x', start: 'whenever' }).error, /start must be a date/);
  assert.match(apply(board, { op: 'item', id: 'x', block: 'fun', text: 'x', value: 'lots' }).error, /needs a number/);
  assert.match(apply(board, { op: 'item', id: 'nrr', points: 'up, then down' }).error, /points must be numbers/);
  const many = after(board, { op: 'item', id: 'nrr', points: Array.from({ length: 20 }, (_, i) => i) });
  assert.equal(many.blocks[4].items[0].points.length, LIMITS.points, 'only the last few values are kept');
  assert.equal(after(board, { op: 'item', id: 'sam', lane: 'Nowhere' }).blocks[2].items[1].lane, undefined);
  // The sentence under the board says each thing once, with money as the board shows it.
  assert.equal(apply(board, { op: 'item', id: 'audit', block: 'rm', text: 'Security audit', lane: 'Platform', start: 'June', end: 'June' }).what,
    'Added “Security audit” to Roadmap, Platform, June');
  const money = after(emptyBoard(), { op: 'block', id: 'r', type: 'chart', title: 'Revenue', unit: '$M' });
  assert.equal(apply(money, { op: 'item', id: 'q4', block: 'r', text: 'Q4 forecast', value: 4.6 }).what, 'Added “Q4 forecast” to Revenue, $4.6M');
});

test('a block is drawn another way with one edit, its items kept: a chart as a donut, a timeline as a roadmap, a flow as a swimlane', () => {
  const board = launch();
  const donut = apply(board, { op: 'block', id: 'signups', style: 'donut' });
  assert.equal(donut.what, 'Made “Signups” a donut chart');
  assert.deepEqual(donut.board.blocks[1].items.map((i) => i.value), [120, 180]);
  const funnel = apply(board, { op: 'block', id: 'signups', type: 'funnel' });
  assert.equal(funnel.what, 'Made “Signups” a funnel');
  assert.deepEqual(funnel.board.blocks[1].items.map((i) => i.value), [120, 180]);
  const plan = after(emptyBoard(), { op: 'block', id: 't', type: 'timeline' },
    { op: 'item', id: 'a', block: 't', text: 'Beta', when: 'March 2027', status: 'done' },
    { op: 'item', id: 'b', block: 't', text: 'Launch', when: 'someday' });
  const roadmap = after(plan, { op: 'block', id: 't', type: 'roadmap' }).blocks[0];
  assert.deepEqual(roadmap.items.map((i) => [i.start, i.status]), [['March 2027', 'done'], [undefined, undefined]]);
  const flow = after(emptyBoard(), { op: 'block', id: 'f', type: 'flow' }, { op: 'item', id: 'a', block: 'f', text: 'Ask' },
    { op: 'item', id: 'b', block: 'f', text: 'Check', shape: 'decision' }, { op: 'link', from: 'b', to: 'a', label: 'No' });
  const lanes = after(flow, { op: 'block', id: 'f', type: 'swimlane' }, { op: 'item', id: 'a', lane: 'Support' }).blocks[0];
  assert.deepEqual([lanes.links, lanes.items[1].shape, lanes.items[0].lane], [[{ from: 'b', to: 'a', label: 'No' }], 'decision', 'Support']);
  // A chart with series as a donut takes its first series; as a funnel, each stage that series' number.
  const series = after(emptyBoard(), { op: 'block', id: 'c', type: 'chart', columns: [{ id: 'a', name: 'Actual' }, { id: 't', name: 'Target' }] },
    { op: 'item', id: 'q1', block: 'c', text: 'Q1', cells: { a: 10, t: 12 } });
  assert.equal(after(series, { op: 'block', id: 'c', type: 'funnel' }).blocks[0].items[0].value, 10);
});

test("a custom picture is Hermes's: drawn in the background into its block, only by the drawing it waits for, and only safe SVG", () => {
  const svg = '<svg viewBox="0 0 1000 520"><rect x="10" y="10" width="200" height="80" fill="#ffffff"/><text x="20" y="50">API</text></svg>';
  let board = after(launch(), { op: 'block', id: 'arch', type: 'sketch', title: 'How we talk to Stripe', brief: 'App, API, Stripe', drawing: 'd1' });
  assert.equal(board.blocks[2].drawing, 'd1');
  assert.match(apply(board, { op: 'item', id: 'x', block: 'arch', text: 'x' }).error, /picture has no items/);
  assert.match(apply(board, { op: 'block', id: 'arch', type: 'list' }).error, /drawn new/);
  assert.match(apply(board, { op: 'block', id: 'goals', type: 'sketch' }).error, /drawn new/);
  assert.match(apply(board, { op: 'sketch', id: 'arch', drawing: 'old', svg }).error, /asked for again/);
  assert.match(apply(board, { op: 'sketch', id: 'arch', drawing: 'd1', svg: '<p>hi</p>' }).error, /not one the board can show/);
  // Partly drawn, then done.
  const part = apply(board, { op: 'sketch', id: 'arch', drawing: 'd1', svg: svg.slice(0, 90) });
  assert.deepEqual([part.changed, part.board.blocks[2].drawing], [[], 'd1']);
  assert.match(part.board.blocks[2].svg, /<\/svg>$/, 'a picture cut short is closed');
  const done = apply(part.board, { op: 'sketch', id: 'arch', drawing: 'd1', svg: svg.replace('<rect', '<script>x</script><rect onload="x()"'), done: true });
  assert.deepEqual([done.what, done.changed, done.board.blocks[2].drawing], ['Drew “How we talk to Stripe”', ['arch'], undefined]);
  assert.doesNotMatch(done.board.blocks[2].svg, /script|onload/);
  assert.match(apply(done.board, { op: 'sketch', id: 'arch', drawing: 'd1', svg }).error, /asked for again/, 'a finished drawing is closed');
  // Asked for again: the old picture stays up while the new one is drawn; a failure keeps it and says why.
  board = after(done.board, { op: 'block', id: 'arch', brief: 'Add a fraud check', drawing: 'd2' });
  assert.equal(apply(done.board, { op: 'block', id: 'arch', brief: 'x', drawing: 'd2' }).what, 'Redrawing “How we talk to Stripe”');
  const failed = after(board, { op: 'sketch', id: 'arch', drawing: 'd2', failed: 'the model did not answer' }).blocks[2];
  assert.deepEqual([failed.failed, failed.drawing, Boolean(failed.svg)], ['the model did not answer', undefined, true]);
  // At most two to a board.
  board = after(board, { op: 'block', id: 'two', type: 'sketch', brief: 'x', drawing: 'd3' });
  assert.match(apply(board, { op: 'block', id: 'three', type: 'sketch', brief: 'x' }).error, /at most 2 custom pictures/);
  // A board from anywhere keeps a picture only as safe SVG.
  const kept = clean({ v: 2, title: 'x', blocks: [{ id: 's', type: 'sketch', title: 'S', items: [], svg: `${svg}<script>`, drawing: 'd9' },
    { id: 'z', type: 'sketch', title: 'Z', items: [], svg: '<html><script>alert(1)</script></html>' }] });
  assert.equal(kept.blocks[0].drawing, 'd9');
  assert.doesNotMatch(kept.blocks[0].svg, /script/);
  assert.equal(kept.blocks[1].svg, undefined);
});

test('a one-series chart that gets a second series keeps its numbers in the first', () => {
  const board = after(launch(), { op: 'block', id: 'signups', columns: [{ id: 'actual', name: 'Actual' }, { id: 'plan', name: 'Plan' }] },
    { op: 'item', id: 'nov', cells: { plan: 200 } });
  assert.deepEqual(board.blocks[1].items.map((i) => [i.value, i.cells]), [[undefined, { actual: 120 }], [undefined, { actual: 180, plan: 200 }]]);
});

test('a block sent again as it is changes nothing and says nothing; any real change to it still says so', () => {
  const board = launch();
  const same = apply(board, { op: 'block', id: 'signups', type: 'chart', title: 'Signups', unit: 'signups' });
  assert.deepEqual([same.same, same.changed, same.what], [true, [], '']);
  assert.equal(apply(board, { op: 'block', id: 'signups' }).same, true);
  const restyled = apply(board, { op: 'block', id: 'signups', style: 'line' });
  assert.equal(restyled.same, undefined);
  assert.equal(restyled.what, 'Made “Signups” a line chart');
  assert.equal(apply(board, { op: 'block', id: 'signups', after: 'first' }).same, undefined);
});
