// Edits to a whiteboard, one at a time. The board room applies each edit as it arrives (from Hermes as the model makes
// it, or from someone editing the board link) and sends everyone the board that results. Pure, so tests run it alone.
//
// A board is a title and a few visual blocks (public/board/model.mjs): lists of a kind, flows, timelines, charts,
// comparison tables, 2x2s, mind maps and key numbers. An edit adds to a block or changes one thing in it, so every later
// "add this" builds on what is there: nothing is redrawn or started over. A recap board (recap()) gathers every board's
// action items, decisions and open risks for the end of the call.
//
// The edits: title, block, item, link, unlink, remove, clear, and sketch (Hermes's custom picture, as it is drawn).
// Boards and edits from before blocks (sections of notes: section, note, arrow, unarrow) are taken as lists and their
// items, so a Hermes or a page that has not caught up still works.
import { CHARS, dayOf, emptyBoard, FIELDS, ident, index, isBoard, LEVELS, LIMITS, numberOf, QUADRANTS, SHAPES, STATUSES,
  STYLES, TRENDS, TYPE_TITLES, TYPES, upgrade, withUnit, words } from '../public/board/model.mjs';
import { guessKind, KINDS, kindOf } from '../public/board/kinds.mjs';
import { cleanSvg } from '../public/board/svg.mjs';

export { emptyBoard, guessKind, KINDS, kindOf, LEVELS, LIMITS, TYPES };

class Refused extends Error {}

const quote = (text) => `“${text}”`;
const count = (n, one) => `${n} ${one}${n === 1 ? '' : 's'}`;
const said = (changed, what, more = {}) => ({ changed, what, ...more });
const given = (value) => value !== undefined && value !== null;
const allItems = (board) => board.blocks.flatMap((b) => b.items);
const TYPE_WORDS = { list: 'list', flow: 'flow', timeline: 'timeline', chart: 'chart', table: 'comparison', matrix: '2x2',
  mindmap: 'mind map', stats: 'key numbers', funnel: 'funnel', roadmap: 'roadmap', tree: 'org chart', swimlane: 'swimlane',
  sketch: 'picture' };
const STYLE_WORDS = { bar: 'bar chart', line: 'line chart', stacked: 'stacked bar chart', donut: 'donut chart',
  pie: 'pie chart', heatmap: 'heatmap' };
// The fields Hermes alone may set: a custom picture is drawn only by Hermes's model, never sent from a board link. The
// type is read as the edit reads it (oneOf), so "Sketch" is a picture too; what one shows (`brief`) is Hermes's alone.
export const HERMES_ONLY = (op) => op?.op === 'sketch' || (op?.op === 'block'
  && (String(op.type ?? '').toLowerCase() === 'sketch' || op.drawing !== undefined || op.brief !== undefined));
const NUMBERED = ['chart', 'funnel'];
const LEVEL_WORDS = { high: 'high risk', medium: 'medium risk', low: 'low risk' };
const STATUS_WORDS = { done: 'done', now: 'under way', next: 'next', late: 'late' };
const QUADRANT_WORDS = { tl: 'top left', tr: 'top right', bl: 'bottom left', br: 'bottom right' };

function taken(board, id) {
  const { blocks, items, columns } = index(board);
  return blocks.has(id) || items.has(id) || columns.has(id);
}

// Where something new goes in a list: after the one named (or first, for "first"), else at the end.
function place(list, thing, after) {
  const at = after === 'first' ? 0 : after ? list.findIndex((x) => x.id === after) + 1 : 0;
  if (after && at > 0) list.splice(at, 0, thing);
  else if (after === 'first') list.unshift(thing);
  else list.push(thing);
}

function oneOf(value, allowed, name) {
  const v = String(value).toLowerCase();
  if (!allowed.includes(v)) throw new Refused(`${name} must be one of ${allowed.join(', ')}`);
  return v;
}

// A block's own settings from an edit, checked: its kind, a chart's unit and style, a table's pick and scale, a 2x2's
// axes and quadrant names. Columns are added or renamed one by one (merged by id).
function settle(board, block, op) {
  const type = block.type;
  const allowed = FIELDS.block[type];
  if (allowed.includes('kind') && given(op.kind) && op.kind !== '') block.kind = oneOf(op.kind, KINDS, 'kind');
  if (allowed.includes('unit') && given(op.unit)) {
    const unit = words(op.unit, CHARS.unit);
    if (unit) block.unit = unit;
    else delete block.unit;
  }
  if (allowed.includes('style') && given(op.style) && op.style !== '') block.style = oneOf(op.style, STYLES, 'style');
  if (allowed.includes('brief') && given(op.brief)) {
    const brief = words(op.brief, CHARS.brief);
    if (brief) block.brief = brief;
  }
  // A picture being drawn carries the drawing's mark until it is done; only that drawing may fill it in (sketch()).
  if (type === 'sketch' && given(op.drawing)) {
    const drawing = ident(op.drawing);
    if (drawing) {
      block.drawing = drawing;
      delete block.failed;
    } else delete block.drawing;
  }
  if (allowed.includes('scale') && given(op.scale) && op.scale !== '') {
    const scale = Number(op.scale);
    if (![5, 10].includes(scale)) throw new Refused('scale must be 5 or 10');
    block.scale = scale;
  }
  if (allowed.includes('x') || allowed.includes('y')) {
    for (const axis of ['x', 'y']) {
      const value = op[axis] ?? op[`${axis}_axis`];
      if (!value || typeof value !== 'object') continue;
      const low = words(value.low, CHARS.axis);
      const high = words(value.high, CHARS.axis);
      block[axis] = { low: low || block[axis]?.low || 'Low', high: high || block[axis]?.high || 'High',
        ...(words(value.name, CHARS.axis) || block[axis]?.name ? { name: words(value.name, CHARS.axis) || block[axis].name } : {}) };
    }
  }
  if (allowed.includes('quadrants') && op.quadrants && typeof op.quadrants === 'object') {
    const names = { ...(block.quadrants || {}) };
    for (const q of QUADRANTS) {
      if (!given(op.quadrants[q])) continue;
      const name = words(op.quadrants[q], CHARS.axis);
      if (name) names[q] = name;
      else delete names[q];
    }
    block.quadrants = names;
  }
  if (allowed.includes('columns') && Array.isArray(op.columns)) {
    block.columns ??= [];
    const single = block.type === 'chart' && !block.columns.length;
    for (const column of op.columns) {
      const id = ident(column?.id);
      const name = words(column?.name ?? column?.title, CHARS.column);
      if (!id) throw new Refused('a column needs an id');
      const found = block.columns.find((c) => c.id === id);
      if (found) {
        if (name) found.name = name;
        continue;
      }
      if (taken(board, id)) throw new Refused(`${id} is already used on this board`);
      if (!name) throw new Refused('a new column needs a name');
      if (block.columns.length >= LIMITS.columns) throw new Refused(`a block holds at most ${LIMITS.columns} columns`);
      block.columns.push({ id, name });
    }
    // A one-series chart that gets series keeps its numbers: each becomes its item's number in the first series.
    if (single && block.columns.length) {
      const first = block.columns[0].id;
      for (const item of block.items) {
        if (item.value === undefined) continue;
        item.cells = { [first]: item.value, ...(item.cells || {}) };
        delete item.value;
      }
    }
  }
  if (allowed.includes('pick') && given(op.pick)) {
    const pick = ident(op.pick);
    if (!pick) delete block.pick;
    else if (!(block.columns || []).some((c) => c.id === pick)) throw new Refused(`there is no column ${pick}`);
    else block.pick = pick;
  }
}

// An item's own fields from an edit, for its block's type: an action item's owner and due date, a risk's level, a step's
// shape, a milestone's date and status, a number, a table row's cells, a quadrant, a mind map item's parent.
function fill(board, block, item, op) {
  const allowed = FIELDS.item[block.type];
  const set = (key, value) => {
    if (value === '' || value === null) delete item[key];
    else item[key] = value;
  };
  if (allowed.includes('owner') && given(op.owner)) set('owner', words(op.owner, CHARS.owner));
  if (allowed.includes('due') && given(op.due)) set('due', words(op.due, CHARS.due));
  if (allowed.includes('level') && given(op.level)) set('level', op.level === '' ? '' : oneOf(op.level, LEVELS, 'level'));
  if (allowed.includes('shape') && given(op.shape)) set('shape', op.shape === '' || op.shape === 'step' ? '' : oneOf(op.shape, SHAPES, 'shape'));
  if (allowed.includes('when') && given(op.when)) set('when', words(op.when, CHARS.when));
  if (allowed.includes('status') && given(op.status)) set('status', op.status === '' ? '' : oneOf(op.status, STATUSES, 'status'));
  if (allowed.includes('quadrant') && given(op.quadrant)) set('quadrant', oneOf(op.quadrant, QUADRANTS, 'quadrant'));
  if (allowed.includes('note') && given(op.note)) set('note', words(op.note, CHARS.note));
  if (allowed.includes('trend') && given(op.trend)) set('trend', op.trend === '' ? '' : oneOf(op.trend, TRENDS, 'trend'));
  if (allowed.includes('lane') && given(op.lane)) set('lane', words(op.lane, CHARS.lane));
  for (const key of ['start', 'end']) {
    if (!allowed.includes(key) || !given(op[key])) continue;
    const when = words(op[key], CHARS.when);
    if (when && dayOf(when) === null) throw new Refused(`${key} must be a date, like 2027-03-15, 2027-03 or Q2 2027`);
    set(key, when);
  }
  if (allowed.includes('target') && given(op.target)) set('target', words(op.target, CHARS.value));
  if (allowed.includes('points') && given(op.points)) {
    const list = Array.isArray(op.points) ? op.points : String(op.points).split(/[\s,;]+/).filter(Boolean);
    const points = list.map((v) => numberOf(v));
    if (points.some((v) => v === null)) throw new Refused('points must be numbers');
    set('points', points.length ? points.slice(-LIMITS.points) : '');
  }
  if (allowed.includes('value') && given(op.value)) {
    if (NUMBERED.includes(block.type)) {
      const n = op.value === '' ? null : numberOf(op.value);
      if (op.value !== '' && n === null) throw new Refused('a chart needs a number');
      set('value', n);
    } else set('value', words(op.value, CHARS.value));
  }
  if (allowed.includes('parent') && given(op.parent)) {
    const parent = ident(op.parent);
    if (parent && parent !== block.id) {
      if (!block.items.some((i) => i.id === parent)) throw new Refused(`there is no item ${parent} in ${block.title}`);
      // Never a loop: an item cannot hang from itself or from anything that hangs from it.
      for (let at = parent; at; at = block.items.find((i) => i.id === at)?.parent) {
        if (at === item.id) throw new Refused('an item cannot hang from itself');
      }
      item.parent = parent;
    } else delete item.parent;
  }
  if (allowed.includes('cells') && op.cells && typeof op.cells === 'object' && !Array.isArray(op.cells)) {
    const cells = { ...(item.cells || {}) };
    for (const [key, value] of Object.entries(op.cells)) {
      const id = ident(key);
      if (!(block.columns || []).some((c) => c.id === id)) throw new Refused(`there is no column ${id || key} in ${block.title}`);
      if (value === '' || value === null) delete cells[id];
      else if (block.type === 'chart') {
        const n = numberOf(value);
        if (n === null) throw new Refused('a chart needs a number');
        cells[id] = n;
      } else cells[id] = typeof value === 'number' && Number.isFinite(value) ? value : words(value, CHARS.cell);
    }
    if (Object.keys(cells).length) item.cells = cells;
    else delete item.cells;
  }
}

// An item's details in words: 'owner Lee, due Fri Dec 5', 'high risk', '1.2M', 'Q3'.
function details(block, item) {
  const parts = facts(block, item);
  return parts.length ? `, ${parts.join(', ')}` : '';
}

function facts(block, item) {
  const parts = [];
  if (block.type === 'list') {
    if (item.owner) parts.push(`owner ${item.owner}`);
    else if (kindOf(block) === 'actions') parts.push('no owner yet');
    if (item.due) parts.push(`due ${item.due}`);
    if (item.level) parts.push(LEVEL_WORDS[item.level]);
  }
  if (block.type === 'timeline' && item.status) parts.push(STATUS_WORDS[item.status]);
  if (block.type === 'timeline' && item.when) parts.push(item.when);
  if (NUMBERED.includes(block.type) && item.value !== undefined) parts.push(withUnit(item.value, block.unit));
  if (block.type === 'stats' && item.value) parts.push(item.value);
  if (block.type === 'stats' && item.target) parts.push(`target ${item.target}`);
  if (block.type === 'stats' && item.points?.length) parts.push(`${count(item.points.length, 'point')} of history`);
  if (item.lane && ['roadmap', 'swimlane'].includes(block.type)) parts.push(item.lane);
  if (block.type === 'roadmap' && item.start) parts.push(item.end && item.end !== item.start ? `${item.start} to ${item.end}` : item.start);
  if (block.type === 'roadmap' && item.status) parts.push(STATUS_WORDS[item.status]);
  if (block.type === 'tree' && item.note) parts.push(item.note);
  if (block.type === 'matrix' && item.quadrant) parts.push(block.quadrants?.[item.quadrant] || QUADRANT_WORDS[item.quadrant]);
  // A row's cells, by column: "Priya 5".
  for (const column of block.columns || []) {
    if (given(item.cells?.[column.id]) && item.cells[column.id] !== '') parts.push(`${column.name} ${item.cells[column.id]}`);
  }
  return parts;
}

function findBlock(board, id) {
  const block = board.blocks.find((b) => b.id === id);
  if (!block) throw new Refused(`there is no block ${id || '(none given)'}`);
  return block;
}

// Each edit: (board, op) => what it did. It changes `board` in place; apply() hands it a copy.
const EDITS = {
  title(board, op) {
    const title = words(op.text, CHARS.title);
    if (!title) throw new Refused('a title needs words');
    board.title = title;
    return said(['title'], `Named the board ${quote(title)}`);
  },

  // Adds a block of a type, or changes the block with this id: its title, its settings, its place among the others, or
  // its type (its items stay, and show the new way).
  block(board, op, { most = LIMITS.blocks } = {}) {
    const id = ident(op.id);
    if (!id) throw new Refused('a block needs an id');
    const found = board.blocks.find((b) => b.id === id);
    const type = given(op.type) && op.type !== '' ? oneOf(op.type, TYPES, 'type') : found?.type;
    if (!type) throw new Refused(`type must be one of ${TYPES.join(', ')}`);
    const title = words(op.title, CHARS.block);
    const after = given(op.after) ? (op.after === 'first' ? 'first' : ident(op.after)) : undefined;
    if (after && after !== 'first' && after !== id && !board.blocks.some((b) => b.id === after)) {
      throw new Refused(`there is no block ${after}`);
    }
    if (found) {
      const was = { ...found, columns: [...(found.columns || [])] };
      const before = JSON.stringify(board.blocks);
      if (type !== found.type && (type === 'sketch' || found.type === 'sketch')) {
        throw new Refused('a picture is drawn new, not made from another block');
      }
      if (type !== found.type) {
        found.type = type;
        for (const key of Object.keys(found)) {
          if (!['id', 'type', 'title', 'items'].includes(key) && !FIELDS.block[type].includes(key)) delete found[key];
        }
        if (type === 'list' && !found.kind) found.kind = guessKind(found.title);
        const series = (was.columns || [])[0]?.id;
        found.items = found.items.map((item) => {
          const kept = { id: item.id, text: item.text };
          for (const key of FIELDS.item[type]) if (given(item[key])) kept[key] = item[key];
          // What one type calls a field another names its own way: a milestone's date is a roadmap bar's start, a
          // chart's first series is a funnel stage's number, a number said as words is a key number.
          if (type === 'roadmap' && item.when && dayOf(item.when) !== null) kept.start = item.when;
          if (type === 'timeline' && item.start) kept.when = item.start;
          if (NUMBERED.includes(type) && kept.value === undefined && series && given(item.cells?.[series])) kept.value = item.cells[series];
          if (NUMBERED.includes(type) && kept.value !== undefined && numberOf(kept.value) === null) delete kept.value;
          if (NUMBERED.includes(type) && kept.value !== undefined) kept.value = numberOf(kept.value);
          if (type === 'stats' && kept.value !== undefined) kept.value = words(kept.value, CHARS.value);
          return kept;
        });
      }
      if (title) found.title = title;
      settle(board, found, op);
      if (after !== undefined && after !== id) {
        board.blocks.splice(board.blocks.indexOf(found), 1);
        place(board.blocks, found, after);
      }
      // A block sent again as it is changes nothing, and says nothing (the room keeps no step for it).
      if (JSON.stringify(board.blocks) === before) return said([], '', { same: true });
      const added = (found.columns || []).filter((c) => !(was.columns || []).some((w) => w.id === c.id));
      const picked = found.pick && found.pick !== was.pick ? found.columns.find((c) => c.id === found.pick) : null;
      const restyled = type === 'chart' && found.style !== was.style && found.style;
      const what = type !== was.type ? `Made ${quote(found.title)} a ${restyled ? STYLE_WORDS[found.style] : TYPE_WORDS[type]}`
        : restyled ? `Made ${quote(found.title)} a ${STYLE_WORDS[found.style]}`
        : title && title !== was.title ? `Renamed ${quote(was.title)} to ${quote(title)}`
        : type === 'sketch' && found.drawing && found.drawing !== was.drawing ? `Redrawing ${quote(found.title)}`
          : picked ? `Picked ${quote(picked.name)} in ${found.title}`
            : added.length ? `Added ${added.map((c) => quote(c.name)).join(', ')} to ${found.title}` : `Changed ${quote(found.title)}`;
      return said([id, ...found.items.map((i) => i.id)], what);
    }
    if (taken(board, id)) throw new Refused(`${id} is already used on this board`);
    if (board.blocks.length >= most) throw new Refused(`a board holds at most ${most} blocks`);
    if (type === 'sketch' && board.blocks.filter((b) => b.type === 'sketch').length >= LIMITS.sketches) {
      throw new Refused(`a board holds at most ${LIMITS.sketches} custom pictures`);
    }
    const block = { id, type, title: title || TYPE_TITLES[type], items: [] };
    if (type === 'list') block.kind = given(op.kind) && op.kind !== '' ? oneOf(op.kind, KINDS, 'kind') : guessKind(block.title);
    settle(board, block, op);
    place(board.blocks, block, after);
    return said([id], `Added the ${TYPE_WORDS[type]} ${quote(block.title)}`, { block: block.title });
  },

  // Adds an item to a block, or changes the item with this id: its words, its fields, its block or its place.
  item(board, op) {
    const id = ident(op.id);
    if (!id) throw new Refused('an item needs an id');
    const { items } = index(board);
    const found = items.get(id);
    const block = given(op.block) ? findBlock(board, ident(op.block)) : found?.block;
    if (!block) throw new Refused('there is no block (none given)');
    if (block.type === 'sketch') throw new Refused('a picture has no items: ask for the change to it instead');
    const text = op.text === undefined ? undefined : words(op.text, CHARS.item);
    const after = given(op.after) ? (op.after === 'first' ? 'first' : ident(op.after)) : undefined;
    if (after && after !== 'first' && after !== id && !block.items.some((i) => i.id === after)) {
      throw new Refused(`there is no item ${after} in ${block.title}`);
    }
    if (!found) {
      if (!text) throw new Refused('a new item needs words');
      if (taken(board, id)) throw new Refused(`${id} is already used on this board`);
      if (block.items.length >= LIMITS.items) throw new Refused(`a block holds at most ${LIMITS.items} items`);
      if (allItems(board).length >= LIMITS.allItems) throw new Refused(`a board holds at most ${LIMITS.allItems} items`);
      const item = { id, text };
      fill(board, block, item, op);
      place(block.items, item, after);
      return said([id], `Added ${quote(text)} to ${block.title}${details(block, item)}`, { added: block.title });
    }
    const item = found.item;
    const was = JSON.stringify(item);
    const wasText = item.text;
    const moved = block !== found.block;
    if (moved) {
      if (block.items.length >= LIMITS.items) throw new Refused(`a block holds at most ${LIMITS.items} items`);
      found.block.items.splice(found.block.items.indexOf(item), 1);
      for (const key of Object.keys(item)) if (!['id', 'text'].includes(key) && !FIELDS.item[block.type].includes(key)) delete item[key];
      // What hung from it in a mind map stays where it was, on the branch above.
      for (const other of found.block.items) {
        if (other.parent !== id) continue;
        if (item.parent) other.parent = item.parent;
        else delete other.parent;
      }
      found.block.links = (found.block.links || []).filter((l) => l.from !== id && l.to !== id);
      if (!found.block.links.length) delete found.block.links;
      delete item.parent;
      place(block.items, item, after);
    } else if (after !== undefined && after !== id) {
      block.items.splice(block.items.indexOf(item), 1);
      place(block.items, item, after);
    }
    if (text) item.text = text;
    fill(board, block, item, op);
    const parts = [];
    if (text && text !== wasText) parts.push(`now ${quote(text)}`);
    if (moved) parts.push(`moved to ${block.title}`);
    // Only what this change set: "Changed “Private beta”: done", not its date as well.
    const before = new Set(facts(block, JSON.parse(was)));
    const now = facts(block, item).filter((part) => !before.has(part));
    if (JSON.stringify(item) !== was && now.length && !parts.length) parts.push(now.join(', '));
    return said([id], `Changed ${quote(wasText)}${parts.length ? `: ${parts.join(', ')}` : ''}`);
  },

  // An arrow from one step of a flow to another, beyond the order the steps are in: a branch or a loop back.
  link(board, op) {
    const from = ident(op.from);
    const to = ident(op.to);
    const { items } = index(board);
    const a = items.get(from);
    const b = items.get(to);
    if (!a || !b || from === to || a.block !== b.block) throw new Refused('a link joins two different items of one block');
    if (!['flow', 'swimlane'].includes(a.block.type)) throw new Refused('links join the steps of a flow');
    const block = a.block;
    block.links ??= [];
    const label = words(op.label, CHARS.label);
    const found = block.links.find((l) => l.from === from && l.to === to);
    const what = `Joined ${quote(a.item.text)} to ${quote(b.item.text)}${label ? ` (${label})` : ''}`;
    if (found) {
      if (label) found.label = label;
      else delete found.label;
      return said([from, to], what, { joined: block.title });
    }
    if (block.links.length >= LIMITS.links) throw new Refused(`a flow holds at most ${LIMITS.links} links`);
    block.links.push({ from, to, ...(label ? { label } : {}) });
    return said([from, to], what, { joined: block.title });
  },

  unlink(board, op) {
    const from = ident(op.from);
    const to = ident(op.to);
    for (const block of board.blocks) {
      const before = (block.links || []).length;
      block.links = (block.links || []).filter((l) => !(l.from === from && l.to === to));
      if (block.links.length !== before) {
        const name = (id) => block.items.find((i) => i.id === id)?.text || id;
        return said([], `Took away the link from ${quote(name(from))} to ${quote(name(to))}`);
      }
    }
    throw new Refused('there is no such link');
  },

  // Removes an item (and, in a mind map, what hangs from it), a block with its items, or a column with its cells.
  remove(board, op) {
    const id = ident(op.id);
    const { blocks, items, columns } = index(board);
    let gone = new Set([id]);
    let what;
    if (items.has(id)) {
      const { block, item } = items.get(id);
      // In a mind map, what hangs from it goes too: each pass takes the next level down.
      for (let size = 0; size !== gone.size;) {
        size = gone.size;
        for (const other of block.items) if (other.parent && gone.has(other.parent)) gone.add(other.id);
      }
      block.items = block.items.filter((i) => !gone.has(i.id));
      if (block.links) block.links = block.links.filter((l) => !gone.has(l.from) && !gone.has(l.to));
      if (block.links && !block.links.length) delete block.links;
      what = `Removed ${quote(item.text)} from ${block.title}${gone.size > 1 ? ` and ${count(gone.size - 1, 'item')} under it` : ''}`;
    } else if (blocks.has(id)) {
      const block = blocks.get(id);
      gone = new Set([id, ...block.items.map((i) => i.id)]);
      board.blocks = board.blocks.filter((b) => b !== block);
      what = `Removed ${quote(block.title)}${block.items.length ? ` and its ${count(block.items.length, 'item')}` : ''}`;
    } else if (columns.has(id)) {
      const { block, column } = columns.get(id);
      block.columns = block.columns.filter((c) => c.id !== id);
      if (block.pick === id) delete block.pick;
      for (const item of block.items) {
        if (!item.cells) continue;
        delete item.cells[id];
        if (!Object.keys(item.cells).length) delete item.cells;
      }
      what = `Removed ${quote(column.name)} from ${block.title}`;
    } else throw new Refused(`there is nothing called ${id || '(none given)'}`);
    for (const block of board.blocks) for (const item of block.items) if (item.parent && gone.has(item.parent)) delete item.parent;
    // A copy taken off a recap stays off when the recap is made again (recap()).
    for (const key of gone) {
      if (!board.copied?.[key]) continue;
      board.dropped = [...(board.dropped || []), board.copied[key]].slice(-LIMITS.items * 3);
      delete board.copied[key];
    }
    return said([id], what);
  },

  clear(board) {
    board.blocks = [];
    return said([], 'Cleared the board');
  },

  // Hermes's custom picture as its model draws it: { id, drawing, svg, done } fills the picture block, again and again
  // while the model is still writing (so it appears a part at a time), and `done` ends the drawing. `failed` ends it
  // with the reason, keeping any picture from before. Only the drawing the block is waiting for may fill it: a picture
  // asked for again since, or taken away, refuses an older one. The SVG kept is only what svg.mjs lets through.
  sketch(board, op) {
    const id = ident(op.id);
    const block = board.blocks.find((b) => b.id === id && b.type === 'sketch');
    if (!block) throw new Refused(`there is no picture ${id || '(none given)'}`);
    if (!block.drawing || block.drawing !== ident(op.drawing)) throw new Refused('that picture was asked for again since');
    if (given(op.failed) && op.failed !== '') {
      delete block.drawing;
      block.failed = words(op.failed, 80) || 'it could not be drawn';
      return said([id], `Could not draw ${quote(block.title)}`);
    }
    const svg = cleanSvg(op.svg);
    if (!svg) throw new Refused('that picture is not one the board can show');
    block.svg = svg;
    if (op.done) delete block.drawing;
    return said(op.done ? [id] : [], `${op.done ? 'Drew' : 'Drawing'} ${quote(block.title)}`, op.done ? { drew: block.title } : {});
  },

  // From before blocks: a section is a list, a note its item, an arrow a link.
  section(board, op) {
    const id = ident(op.id);
    const found = board.blocks.find((b) => b.id === id);
    return EDITS.block(board, { id, title: op.title, ...(found ? {} : { type: 'list' }), kind: op.kind });
  },
  note(board, op) {
    return EDITS.item(board, { ...op, block: op.section });
  },
  arrow(board, op) {
    return EDITS.link(board, op);
  },
  unarrow(board, op) {
    return EDITS.unlink(board, op);
  },
};

export const OPS = ['title', 'block', 'item', 'link', 'unlink', 'remove', 'clear', 'sketch'];

// The board after one edit, the ids it changed and what it did in words: { board, changed, what, added?, block? }
// (added: the block a new item went to; block: a new block's title) or { error } with the board untouched. `most`: the
// blocks a new one may join (clean() lets a whole board keep up to LIMITS.kept).
export function apply(board, op, { most = LIMITS.blocks } = {}) {
  // Only the edits named above: an op such as "__proto__" or "constructor" is refused like any unknown one.
  const name = op && typeof op === 'object' ? op.op : undefined;
  if (typeof name !== 'string' || !Object.hasOwn(EDITS, name)) return { error: `unknown edit ${String(name).slice(0, 20)}` };
  const edit = EDITS[name];
  const next = structuredClone(isBoard(board) ? board : clean(board));
  try {
    return { board: next, ...edit(next, op, { most }) };
  } catch (error) {
    if (error instanceof Refused) return { error: error.message };
    throw error;
  }
}

// A board from anywhere (stored, sent by a client, or from before blocks) made safe to draw: known types and fields,
// short texts, unique ids, and only links and parents that exist. Rebuilt through the edits, so it obeys their rules.
export function clean(value) {
  const source = upgrade(value);
  let board = emptyBoard(source?.title);
  if (source?.recap === true) board.recap = true;
  const take = (op) => {
    const result = apply(board, op, { most: LIMITS.kept });
    if (result.board) board = result.board;
    return !result.error;
  };
  for (const block of Array.isArray(source?.blocks) ? source.blocks : []) {
    if (!block || typeof block !== 'object' || !TYPES.includes(block.type)) continue;
    const settings = Object.fromEntries(FIELDS.block[block.type].filter((k) => k !== 'pick' && given(block[k])).map((k) => [k, block[k]]));
    if (!take({ op: 'block', id: block.id, type: block.type, title: block.title || TYPE_TITLES[block.type], ...settings })) continue;
    const id = ident(block.id);
    const items = Array.isArray(block.items) ? block.items.filter((i) => i && typeof i === 'object') : [];
    // Parents after the items they name, so a mind map's order never refuses one.
    for (const item of items) {
      const fields = Object.fromEntries(FIELDS.item[block.type].filter((k) => k !== 'parent' && given(item[k])).map((k) => [k, item[k]]));
      take({ op: 'item', id: item.id, block: id, text: item.text, ...fields });
    }
    for (const item of items) if (item.parent) take({ op: 'item', id: item.id, parent: item.parent });
    for (const link of Array.isArray(block.links) ? block.links : []) {
      if (link && typeof link === 'object') take({ op: 'link', from: link.from, to: link.to, label: link.label });
    }
    if (given(block.pick)) take({ op: 'block', id, pick: block.pick });
    if (block.type === 'sketch') {
      // A picture keeps what it showed (checked again), and whether it was still being drawn or could not be.
      const made = board.blocks.find((b) => b.id === id);
      const svg = typeof block.svg === 'string' ? cleanSvg(block.svg) : null;
      if (made && svg) made.svg = svg;
      if (made && ident(block.drawing)) made.drawing = ident(block.drawing);
      if (made && !made.drawing && typeof block.failed === 'string' && words(block.failed, 80)) made.failed = words(block.failed, 80);
    }
  }
  // A recap's memory of what it copied from the boards, and of copies taken off it (recap()), after its items: adding
  // an item forgets any copy of that id.
  if (board.recap) {
    const copied = Object.entries(source.copied && typeof source.copied === 'object' ? source.copied : {})
      .slice(0, LIMITS.items * 3).map(([id, item]) => [ident(id), fields(item)]).filter(([id, item]) => id && item.text);
    if (copied.length) board.copied = Object.fromEntries(copied);
    const dropped = (Array.isArray(source.dropped) ? source.dropped : []).slice(-LIMITS.items * 3).map(fields).filter((i) => i.text);
    if (dropped.length) board.dropped = dropped;
  }
  return board;
}

// An item's words, owner, due date and level, short and checked, and only those it has.
function fields(item) {
  const kept = { text: words(item?.text, CHARS.item) };
  if (item?.owner) kept.owner = words(item.owner, CHARS.owner);
  if (item?.due) kept.due = words(item.due, CHARS.due);
  if (LEVELS.includes(item?.level)) kept.level = item.level;
  return kept;
}

const sameItem = (a, b) => ['text', 'owner', 'due', 'level'].every((key) => (a?.[key] || '') === (b?.[key] || ''));
const RECAP_KINDS = ['actions', 'risks', 'decisions'];
const lists = (board) => (upgrade(board)?.blocks || []).filter((b) => b?.type === 'list' && Array.isArray(b.items));

// The end-of-call recap: every board's action items (with owners and dates), decisions and open risks, as three lists
// on a board of its own; null when there is nothing to recap. A kind with more items than a list holds ends in "+N more".
// Made again (`previous`, the call's earlier recap), it follows the boards: a copy nobody touched is replaced by what
// its board says now, and goes when its board no longer has it. To tell, the recap remembers each item's board version
// (`copied`, by item id; none for an item added on the recap). What someone changed or added on the recap itself stays,
// and wins over the board's copy, however many times the recap is made again. A copy someone took off the recap
// (`dropped`) stays off, unless its board has changed it since.
export function recap(boards, previous = null) {
  // Each kind's items as { item, from }: `from` is the board's version of the item, null for one only the recap has.
  const found = { actions: [], risks: [], decisions: [] };
  for (const board of boards || []) {
    if (!board || board.recap) continue;
    for (const block of lists(board)) {
      const kind = kindOf(block);
      if (found[kind]) found[kind].push(...block.items.map((n) => ({ item: fields(n), from: fields(n) })));
    }
  }
  const dropped = [];
  // Each removal keeps one matching copy off, so two boards' identical tasks both stay off when both were removed.
  for (const item of previous?.dropped || []) {
    for (const list of Object.values(found)) {
      const at = list.findIndex((f) => sameItem(f.from, item));
      if (at < 0) continue;
      list.splice(at, 1);
      dropped.push(item);
      break;
    }
  }
  const copied = previous?.copied || {};
  for (const block of previous ? lists(previous) : []) {
    const kind = kindOf(block);
    if (!found[kind]) continue;
    for (const item of block.items) {
      const was = copied[item.id];
      if (was ? sameItem(was, item) : /^\+\d+ more on the boards$/.test(item.text)) continue;
      const match = found[kind].find((f) => f.item.text === (was ? was.text : item.text));
      if (!match) found[kind].push({ item: fields(item), from: null });
      else match.item = was ? fields(item) : { ...match.item, ...fields(item) };
    }
  }
  if (!RECAP_KINDS.some((kind) => found[kind].length)) return null;
  const copies = {};
  const take = (list, prefix) => {
    const over = list.length > LIMITS.items ? list.length - (LIMITS.items - 1) : 0;
    const kept = (over ? list.slice(0, LIMITS.items - 1) : list).map(({ item, from }, i) => {
      if (from) copies[`${prefix}${i + 1}`] = from;
      return { id: `${prefix}${i + 1}`, ...item };
    });
    if (over) kept.push({ id: `${prefix}more`, text: `+${over} more on the boards` });
    return kept;
  };
  const blocks = [
    { id: 'actions', type: 'list', title: 'Action items', kind: 'actions', items: take(found.actions, 'a') },
    { id: 'risks', type: 'list', title: 'Open risks', kind: 'risks', items: take(found.risks, 'r') },
    { id: 'decisions', type: 'list', title: 'Decisions', kind: 'decisions', items: take(found.decisions, 'd') },
  ];
  return clean({ v: 2, title: 'Recap', recap: true, blocks, copied: copies, dropped });
}

// A recap board as one chat line: 'Recap. Action items: Hire a designer (Lee, due Fri Dec 5); ... Decided: ...'.
export function recapText(board, limit = 480) {
  const line = (block, item) => {
    const parts = [];
    if (kindOf(block) === 'actions') parts.push(item.owner || 'no owner');
    if (item.due) parts.push(`due ${item.due}`);
    if (item.level) parts.push(item.level);
    return parts.length ? `${item.text} (${parts.join(', ')})` : item.text;
  };
  const names = { actions: 'Action items', risks: 'Open risks', decisions: 'Decided' };
  const parts = lists(board).filter((b) => b.items.length)
    .map((b) => `${names[kindOf(b)] || b.title}: ${b.items.map((n) => line(b, n)).join('; ')}.`);
  const text = ['Recap.', ...parts].join(' ');
  return text.length > limit ? `${text.slice(0, limit - 1).trimEnd()}…` : text;
}
