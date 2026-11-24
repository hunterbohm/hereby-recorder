// The board's shape: a title and a few visual blocks, each of one type, each holding items. Shared by the board room's
// edits (src/ops.js) and the board page (view.mjs, blocks.mjs), so both agree on what a board can hold. Pure.
//
// board = { v: 2, title, recap?: true, copied?, dropped?, blocks: [block] }
// block = { id, type, title, items: [item], ...what its type takes (FIELDS.block) }
// item  = { id, text, ...what its block's type takes (FIELDS.item) }
//
// Ids are unique across the whole board: blocks, items and a table's or chart's columns. A board starts with no blocks;
// what is said first decides the first block, and later changes add to a block or put a new one beside it.
import { guessKind, KINDS, kindOf } from './kinds.mjs';

export { guessKind, KINDS, kindOf };

// What each type of block draws:
//   list      cards of one kind: goals, risks (each with a level), action items (owner and due date), decisions, pros,
//             cons, or plain notes
//   flow      steps in order, joined by arrows, with decision steps and labeled links for a branch or a loop
//   timeline  milestones in time order, each with when it is and how it stands
//   chart     numbers by category: bars (or a line over time), one series or a few (`columns`)
//   table     options compared on criteria: each item is a criterion, each column an option, each cell a score or words
//   matrix    a 2x2: two axes, four quadrants, each item in one
//   mindmap   a topic (the block's title) and its branches; an item with a `parent` hangs off that item
//   stats     a few key numbers, big; each may have a target (a meter) and its recent values (a sparkline)
//   funnel    stages that lose people or deals on the way, each with its number and what share of the stage before
//   roadmap   work over date ranges, in lanes (a team or a person): a Gantt chart with today marked
//   tree      a hierarchy drawn top down: who reports to whom, or anything nested
//   swimlane  steps in order, each in the lane of who does it, joined by arrows
//   sketch    a custom picture for what no other block fits, drawn as SVG by a stronger model (src/svg.js checks it)
// A chart's style says how its numbers are drawn: bars, a line, stacked bars (each category split into its series), a
// donut or a pie (parts of a whole), or a heatmap (a grid of numbers shaded by size).
export const TYPES = ['list', 'flow', 'timeline', 'chart', 'table', 'matrix', 'mindmap', 'stats', 'funnel', 'roadmap', 'tree',
  'swimlane', 'sketch'];
export const LEVELS = ['high', 'medium', 'low'];
export const SHAPES = ['step', 'decision', 'start', 'end'];
export const STATUSES = ['done', 'now', 'next', 'late'];
export const QUADRANTS = ['tl', 'tr', 'bl', 'br'];
export const TRENDS = ['up', 'down', 'flat'];
export const STYLES = ['bar', 'line', 'stacked', 'donut', 'pie', 'heatmap'];
// Edits add blocks up to `blocks`; a whole board (one from before blocks, or one Hermes sends whole) keeps up to `kept`,
// the most sections a board held before, so an old board loses none. A board holds at most `sketches` custom pictures,
// and a sparkline at most `points` values.
export const LIMITS = { boards: 9, blocks: 6, kept: 8, items: 12, allItems: 48, columns: 5, links: 12, sketches: 2, points: 12 };
export const CHARS = { title: 60, block: 40, item: 90, label: 40, id: 24, owner: 30, due: 30, when: 24, value: 16, note: 40,
  unit: 12, cell: 40, column: 24, axis: 24, lane: 24, brief: 400, svg: 20000 };

// The fields each block and item may carry beyond its id, title or text, by the block's type. A sketch's picture is set
// only by its own edit (ops.js `sketch`), never as a field.
export const FIELDS = {
  block: { list: ['kind'], flow: ['links'], timeline: [], chart: ['unit', 'style', 'columns'], table: ['columns', 'pick', 'scale'],
    matrix: ['x', 'y', 'quadrants'], mindmap: [], stats: [], funnel: ['unit'], roadmap: [], tree: [], swimlane: ['links'],
    sketch: ['brief'] },
  item: { list: ['owner', 'due', 'level'], flow: ['shape'], timeline: ['when', 'status'], chart: ['value', 'cells'],
    table: ['cells'], matrix: ['quadrant'], mindmap: ['parent'], stats: ['value', 'note', 'trend', 'target', 'points'],
    funnel: ['value'], roadmap: ['lane', 'start', 'end', 'status'], tree: ['parent', 'note'], swimlane: ['lane', 'shape'],
    sketch: [] },
};

// A block's title when none was given.
export const TYPE_TITLES = { list: 'Notes', flow: 'Steps', timeline: 'Timeline', chart: 'Numbers', table: 'Comparison',
  matrix: 'Priorities', mindmap: 'Ideas', stats: 'Key numbers', funnel: 'Funnel', roadmap: 'Roadmap', tree: 'Org chart',
  swimlane: 'Who does what', sketch: 'Sketch' };

// The chart styles that draw one whole split into parts, and those that need two or more series to mean anything.
export const ROUND = ['donut', 'pie'];
export const roundChart = (block) => block?.type === 'chart' && ROUND.includes(block.style);

// The title a board has until it is named.
export const DEFAULT_TITLE = 'Whiteboard';

export const emptyBoard = (title = DEFAULT_TITLE) => ({ v: 2, title: words(title, CHARS.title) || DEFAULT_TITLE, blocks: [] });

export function words(value, limit) {
  return String(value ?? '').split(/\s+/).filter(Boolean).join(' ').slice(0, limit);
}

// A board's name, on its tab and when someone asks for it by name: its title, or while that is still the default, what
// its first block is called; "New board" while it holds nothing. The mini names boards the same way (meeting_board.py).
export function boardName(board) {
  const title = words(board?.title, CHARS.title);
  if (title && title !== DEFAULT_TITLE) return title;
  return (board?.blocks || []).map((block) => words(block?.title, CHARS.block)).find(Boolean) || 'New board';
}

// How the boards are on the shared screen (the room's `view`): one board, two side by side (`boards`, left then right),
// or every board small at once ('all'). Anything else, a pair that names a board the call no longer has, or 'all' with
// one board, is one board. The board on screen that the next change goes to is the room's `current`.
export function fitView(view, count) {
  if (view?.mode === 'all' && count > 1) return { mode: 'all' };
  const pair = Array.isArray(view?.boards) ? view.boards.map(Number) : [];
  if (view?.mode === 'split' && pair.length === 2 && pair[0] !== pair[1]
    && pair.every((n) => Number.isInteger(n) && n >= 1 && n <= count)) return { mode: 'split', boards: pair };
  return { mode: 'one' };
}

export const ident = (value) => String(value ?? '').replace(/[^\w-]/g, '').slice(0, CHARS.id);

export const isBoard = (value) => Boolean(value) && typeof value === 'object' && Array.isArray(value.blocks);

// A board from before blocks (sections of notes, laid out as columns, a grid, a timeline or a flow), as blocks: each
// section a list of its kind, its notes the list's items. A call that was under way when this changed keeps its boards.
// Arrows between sections are left behind; nothing else is.
export function upgrade(value) {
  if (isBoard(value) || !value || typeof value !== 'object') return value;
  const board = { v: 2, title: value.title, blocks: [] };
  for (const key of ['recap', 'copied', 'dropped']) if (value[key] !== undefined) board[key] = value[key];
  for (const section of Array.isArray(value.sections) ? value.sections : []) {
    if (!section || typeof section !== 'object') continue;
    board.blocks.push({ id: section.id, type: 'list', title: section.title, kind: kindOf(section),
      items: (Array.isArray(section.notes) ? section.notes : []).map((note) => ({ ...note })) });
  }
  return board;
}

// Every block, item and column on a board, by id.
export function index(board) {
  const blocks = new Map();
  const items = new Map();
  const columns = new Map();
  for (const block of board?.blocks || []) {
    blocks.set(block.id, block);
    for (const item of block.items || []) items.set(item.id, { block, item });
    for (const column of block.columns || []) columns.set(column.id, { block, column });
  }
  return { blocks, items, columns };
}

// A mindmap item's branch: the top item it hangs from (itself for a branch).
export function branchOf(block, item) {
  const byId = new Map(block.items.map((i) => [i.id, i]));
  let at = item;
  for (let hops = 0; at?.parent && byId.has(at.parent) && hops < LIMITS.items; hops++) at = byId.get(at.parent);
  return at;
}

// A number already written ("4.6", "1.2M") with its block's unit: a currency sign goes before it and a size after
// ("$M" makes "$4.6M"), "%" goes after it, and a word follows a space ("340 leads").
export function withUnit(text, unit) {
  const u = String(unit ?? '').trim();
  const money = /^([$€£])([kMB]?)$/.exec(u);
  // A number already written with its size ("1.9M") keeps it, not "$1.9MM".
  const size = money && /[kMB]$/.test(String(text)) ? '' : money?.[2];
  if (money) return String(text).startsWith('-') ? `-${money[1]}${String(text).slice(1)}${size}` : `${money[1]}${text}${size}`;
  if (u === '%') return `${text}%`;
  return u ? `${text} ${u}` : String(text);
}

// A number for a chart: 1200, "1,200", "$1.2k", "38%", "1.5M" all read; anything else is no number.
export function numberOf(value) {
  if (typeof value === 'number') return Number.isFinite(value) ? value : null;
  const match = /^\s*[-+]?[$€£]?\s*([-+]?\d[\d,]*\.?\d*|\.\d+)\s*([kmb]|thousand|million|billion)?\s*%?\s*$/i.exec(String(value ?? ''));
  if (!match) return null;
  const n = Number(match[1].replace(/,/g, ''));
  const scale = { k: 1e3, thousand: 1e3, m: 1e6, million: 1e6, b: 1e9, billion: 1e9 }[(match[2] || '').toLowerCase()] || 1;
  const sign = /^\s*-/.test(String(value)) ? -1 : 1;
  return Number.isFinite(n) ? sign * Math.abs(n) * scale : null;
}

// --- Dates, for a roadmap -----------------------------------------------------------------------------------------------

const MONTHS = ['jan', 'feb', 'mar', 'apr', 'may', 'jun', 'jul', 'aug', 'sep', 'oct', 'nov', 'dec'];
const DAY_MS = 86400000;
const utc = (y, m, d) => Date.UTC(y, m, d) / DAY_MS;

// A roadmap date as the day it stands for (days since 1970, UTC), or null. `end` takes a period's last day rather than
// its first ("March" ends Mar 31, "Q2" Jun 30). Reads 2027-03-15, 2027-03, Mar 15, March 15 2027, March, Q2, Q2 2027 and
// 2027; a date with no year is in the year that puts it nearest `today` (a Date), or, given `after` (a day), the first
// one on or after it.
export function dayOf(value, { end = false, today = new Date(), after = null } = {}) {
  const text = String(value ?? '').trim().toLowerCase().replace(/(\d)(st|nd|rd|th)\b/g, '$1').replace(/[,.]/g, ' ')
    .replace(/\s+/g, ' ');
  if (!text) return null;
  const year = today.getUTCFullYear();
  const near = (make) => {
    // The year that puts the date nearest today, leaning ahead (plans are mostly about what comes next): "January"
    // said in November is next January, "June" too, and "September" is the one just gone.
    const now = today.getTime() / DAY_MS;
    const far = (day) => (day < now ? (now - day) * 1.5 : day - now);
    const options = [year - 1, year, year + 1].map((y) => [y, far(make(y))]);
    return options.reduce((a, b) => (b[1] < a[1] ? b : a))[0];
  };
  // The day `at` gives in the year chosen: after `after` when given, else nearest today (judged by `mid`, its middle).
  const pick = (at, mid) => {
    if (after === null) return at(near(mid));
    const y = new Date(after * DAY_MS).getUTCFullYear();
    return at(at(y) >= after ? y : y + 1);
  };
  let match = /^(\d{4})-(\d{1,2})(?:-(\d{1,2}))?$/.exec(text);
  if (match) {
    const [y, m, d] = [Number(match[1]), Number(match[2]) - 1, match[3] ? Number(match[3]) : null];
    if (m < 0 || m > 11 || (d !== null && (d < 1 || d > 31))) return null;
    if (d !== null) return utc(y, m, d);
    return end ? utc(y, m + 1, 0) : utc(y, m, 1);
  }
  // A quarter: "q2", "q2 2027", "2027 q2", "2027-q2".
  match = /^q([1-4])(?: (\d{4}))?$/.exec(text);
  const yearFirst = /^(\d{4})[ -]q([1-4])$/.exec(text);
  if (match || yearFirst) {
    const q = Number(match ? match[1] : yearFirst[2]) - 1;
    const given = match ? match[2] : yearFirst[1];
    const at = (y) => (end ? utc(y, q * 3 + 3, 0) : utc(y, q * 3, 1));
    return given ? at(Number(given)) : pick(at, (yy) => utc(yy, q * 3 + 1, 15));
  }
  match = /^(\d{4})$/.exec(text);
  if (match) return end ? utc(Number(match[1]), 11, 31) : utc(Number(match[1]), 0, 1);
  match = /^([a-z]{3,9})(?: (\d{1,2}))?(?: (\d{4}))?$/.exec(text) || /^(\d{1,2}) ([a-z]{3,9})(?: (\d{4}))?$/.exec(text);
  if (match) {
    const [word, day] = /^\d/.test(match[1]) ? [match[2], match[1]] : [match[1], match[2]];
    const m = MONTHS.indexOf(word.slice(0, 3));
    if (m < 0 || (word.length > 3 && !'january february march april may june july august september october november december'
      .split(' ')[m].startsWith(word) && word !== 'sept')) return null;
    const d = day ? Number(day) : null;
    if (d !== null && (d < 1 || d > 31)) return null;
    const at = (y) => (d !== null ? utc(y, m, d) : end ? utc(y, m + 1, 0) : utc(y, m, 1));
    return match[3] ? at(Number(match[3])) : pick(at, (yy) => utc(yy, m, d || 15));
  }
  return null;
}

// A day (days since 1970) as a board says it: "Mar 15", or "Mar 2027" when `year`.
export function dayWords(day, { year = false, month = false } = {}) {
  const date = new Date(day * DAY_MS);
  const name = MONTHS[date.getUTCMonth()];
  const head = name[0].toUpperCase() + name.slice(1);
  if (month) return year ? `${head} ${date.getUTCFullYear()}` : head;
  return `${head} ${date.getUTCDate()}${year ? ` ${date.getUTCFullYear()}` : ''}`;
}

// A roadmap item's span as days: { from, to } (to is its last day), or null when its start is not a date. With no end,
// it runs to the end of the period its start names ("March": all of March; "Mar 15": that day and the next two weeks).
export function spanOf(item, today = new Date()) {
  const from = dayOf(item?.start, { today });
  if (from === null) return null;
  // An end with no year of its own is the first one after the start: "Nov to Feb" ends in February next year, and
  // "2027-01 to December" in December 2027.
  const said = dayOf(item?.end, { end: true, after: from });
  const own = dayOf(item?.start, { end: true, today });
  const to = said !== null && said >= from ? said : own > from ? own : from + 13;
  return { from, to };
}
