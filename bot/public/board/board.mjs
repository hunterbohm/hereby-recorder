// The live whiteboard page. The bot shares it in the call (?screen=1), and anyone with the link can watch and change it
// (or only watch, with a watch-only link).
// It keeps a WebSocket to the call's board room and shows its boards as blocks side by side (view.mjs, blocks.mjs): a
// list, a flow, a chart, a table and so on, each drawn the way its content reads best, at sizes that stay readable in a
// call. A board starts empty and takes shape from what is said; every change animates where it lands, and Hermes's
// cursor (or the person's pointer) goes to it. A call's boards are tabs along the top, as in a browser: the one on
// screen joined to the board below it. The screen shows one board, two side by side (each with its name, the one the
// next change goes to marked), or every board small at once (views.mjs). A status bar docked at the bottom says what
// Hermes hears while someone speaks and then what changed, in words.
//
// On the link each block is there to change: "+ Add" in each, tap anything to change it, "+ Block", Undo, and the list
// of changes; a tab shows that board alone. On a phone the blocks stack. driver.mjs calls window.hermesBoard.export(n)
// for the files kept in the notes, and print(board) on a page of its own (?print=1) to take the board's picture.
import { boardName, index, KINDS, STYLES, TYPES } from './model.mjs';
import { sketchesDrawn } from './blocks.mjs';
import { personColor, render } from './view.mjs';
import { grid, pageView, tabStates } from './views.mjs';
import * as canvas from './canvas.mjs';

const HERMES = { name: 'Hermes', color: '#6a45dc' };
// How long Hermes's cursor stays after it finished, and someone's pointer after it last moved.
const CURSOR_MS = 5000;
const PERSON_MS = 8000;
const POINTER_EVERY_MS = 50;
const FAILED_MS = 8000;
const NAME_KEY = 'hermes-board-name';
// The least width of a tab's name, in pixels, before the tabs not on screen give up their names for their numbers.
const TAB_NAME_MIN = 96;
// Where the shared screen draws a board (1280 by 720, less the tabs, the status bar and the margins), and every board at
// once on a phone: two columns, 16 pixels apart (index.html).
const SCREEN_STAGE = { width: 1208, height: 552 };
const PHONE_COLUMNS = 2;
const PHONE_GAP = 16;
const WAKE = /^@?(?:herm[eéèê]s|hermies|hermie|hermy|hermeez|hermez|hermis|hermus|herms)\b[,:.!]?\s*/i;

const $ = (selector) => document.querySelector(selector);
const params = new URLSearchParams(location.search);
// The link's key is after the # (src/links.js), so the page's own address carries none and the browser never sends it.
const linkKey = location.hash.slice(1);
const screen = params.has('screen');
const print = params.has('print');
document.body.classList.toggle('screen', screen);
document.body.classList.toggle('print', print);
// Whether this page's link may change the board (a watch-only link and the shared screen may not), from the room's hello.
let link = false;
// The link on a narrow screen stacks the blocks, one a row, and scrolls.
const phone = () => !screen && !print && innerWidth <= 760;
const reduced = () => matchMedia('(prefers-reduced-motion: reduce)').matches;

// `current` is the board on the shared screen (of two side by side, the one the next change goes to), `view` how the
// boards are on it, and `last` the board shown last, which the link shows when none is shared. On the link, `viewing`
// is a board picked from the tabs, shown alone.
const room = { boards: [], current: null, last: null, view: { mode: 'one' }, ended: false, log: [], short: null, caption: null,
  listening: true };
let viewing = null;
const shownView = () => pageView({ count: room.boards.length, current: room.current, last: room.last, view: room.view,
  viewing, follows: screen || print });
const shownN = () => shownView().target;
const onScreen = (n) => shownView().mode !== 'all' && shownView().boards.includes(n);

const stage = $('#stage');
let helloSeen;
const hello = new Promise((resolve) => { helloSeen = resolve; });
// The board's font, loaded before anything is drawn (or timed out, when the font falls back to the system's).
const fonts = Promise.race([
  Promise.all([400, 600, 700, 800].map((weight) => document.fonts.load(`${weight} 20px "Atkinson Next"`))),
  new Promise((resolve) => { setTimeout(resolve, 8000); }),
]).catch(() => {});

// --- Drawing ---------------------------------------------------------------------------------------------------------

let sheet = null;
// The view drawn last, so a new one knows which way the boards moved.
let drawnView = null;
// Each board's blocks changed while this page was open, latest first: beside another board, these stay unfolded.
const touched = new Map();

function touch(n, board, changed) {
  const { blocks, items, columns } = index(board);
  const ids = changed.map((id) => (blocks.has(id) ? id : (items.get(id) || columns.get(id))?.block.id)).filter(Boolean);
  if (ids.length) touched.set(n, [...new Set([...ids, ...(touched.get(n) || [])])]);
}

// Draws what this page shows. `n` is the board a change was to (the one shown, when not given), `changed` the ids it
// changed, by whom, in the command `cmd`.
function show({ n: to = null, changed = [], by = null, person = null, name = '', instant = false, cmd = null } = {}) {
  const view = shownView();
  const before = drawnView;
  drawnView = view;
  // Hermes's cursor points at a change on the boards that were on screen; when others come on, it goes with them.
  if (before && (before.mode !== view.mode || String(before.boards) !== String(view.boards))) cursorOff();
  tabs(view, instant);
  share();
  $('#tools').hidden = !link || view.mode === 'none' || room.ended;
  $('#follow').hidden = screen || print || !viewing || room.ended;
  document.body.classList.toggle('editing', link && !room.ended);
  document.body.dataset.view = view.mode;
  if (view.mode === 'none') {
    stage.hidden = true;
    $('#empty-board').hidden = true;
    notice(screen || print ? '' : `No whiteboard yet. ${room.listening ? 'Say “Hey Hermes, start a whiteboard” in the call'
      : 'Type “Hermes, start a whiteboard” in the meeting chat'}.`);
    return;
  }
  notice('');
  const who = by === 'hermes' ? HERMES : by === 'person' && person ? { name: name || 'Someone', color: personColor(person) } : null;
  if (view.mode === 'all') {
    invite(false);
    stage.hidden = false;
    return overview(view, { instant: instant || reduced(), moved: !before || before.mode !== 'all', to });
  }
  // One board with nothing on it yet: what to say to start it, in place of the blocks.
  const lone = view.mode === 'one' ? room.boards[view.target - 1] : null;
  const none = Boolean(lone && !lone.blocks.length);
  invite(none);
  stage.hidden = none;
  const panes = placePanes(view, before, instant);
  let hit = [];
  const changedOn = to ?? view.target;
  for (const [n, pane] of panes) {
    const board = room.boards[n - 1];
    fillHead(pane, n, board, view);
    const body = pane.querySelector('.blocks');
    const empty = !board.blocks.length;
    pane.querySelector('.pane-empty').hidden = !empty || view.mode === 'one';
    body.hidden = empty;
    const ours = n === changedOn;
    if (ours) touch(n, board, changed);
    const got = render(body, board, { changed: ours ? changed : [], who: ours ? who : null, cmd, link: link && !room.ended,
      instant: instant || pane.fresh, print, phone: phone(), fold: view.mode === 'split', recent: touched.get(n) || [] });
    if (ours) hit = got;
    if (ours && changed.includes('title') && who) glow(pane.querySelector('.pane-name'));
    pane.fresh = false;
  }
  if (changed.includes('title') && who) glow($(`#tabs .tab[data-n="${changedOn}"] .name`));
  // A new or changed block: the cursor goes to its name rather than its far corner.
  const last = hit.at(-1)?.matches('.blk') ? hit.at(-1).querySelector('.blk-title') : hit.at(-1);
  if (who && by === 'hermes' && last) cursorTo(placed(last));
  else if (who && last && person !== you) pointerTo(person, who, placed(last));
}

// The panes for one board or two side by side, keyed by board: a board staying on screen keeps its pane, so its blocks
// glide to their new places as it narrows or widens; one coming on screen slides in from the side its tab is on.
function placePanes(view, before, instant) {
  stage.dataset.mode = view.mode;
  const old = new Map([...stage.querySelectorAll(':scope > .pane')].map((node) => [Number(node.dataset.n), node]));
  for (const node of stage.querySelectorAll(':scope > .thumb')) node.remove();
  const from = before && before.mode !== 'none' ? before.target : null;
  const panes = new Map();
  for (const n of view.boards) {
    let pane = old.get(n);
    old.delete(n);
    if (!pane) {
      pane = makePane(n);
      if (!instant && !reduced() && from) {
        // Beside another, from its own side; alone, from the right for a board after the one shown before, else the left.
        const right = view.mode === 'split' ? view.boards.indexOf(n) === 1 : n > from;
        pane.classList.add(right ? 'from-right' : 'from-left');
        pane.addEventListener('animationend', () => pane.classList.remove('from-right', 'from-left'), { once: true });
      }
      pane.fresh = true;
    }
    panes.set(n, pane);
  }
  for (const node of old.values()) node.remove();
  stage.replaceChildren(...panes.values());
  return panes;
}

function makePane(n) {
  const pane = document.createElement('section');
  pane.className = 'pane';
  pane.dataset.n = n;
  pane.innerHTML = '<header class="pane-head"><span class="num"></span><h2 class="pane-name"></h2>'
    + '<span class="target">Adding here</span></header><div class="blocks"></div><p class="pane-empty"></p>';
  return pane;
}

// A pane's name, number and whether the next change goes to it (only said with two on screen).
function fillHead(pane, n, board, view) {
  pane.dataset.n = n;
  pane.classList.toggle('target', view.mode === 'split' && n === view.target);
  pane.querySelector('.num').textContent = n;
  // The picture kept in the notes is titled with the board's own title.
  pane.querySelector('.pane-name').textContent = print ? board.title : boardName(board);
  pane.querySelector('.pane-empty').textContent = !room.listening ? 'Type in the meeting chat what to put on this board'
    : link ? 'Say what to put on this board, or tap + Block' : 'Say what to put on this board';
}

// Every board small at once, each with its number and name, in a grid that keeps them as big as it can. The board the
// next change goes to is outlined. On the link a board opens alone when tapped.
function overview(view, { instant, moved, to }) {
  stage.dataset.mode = 'all';
  for (const node of stage.querySelectorAll(':scope > .pane')) node.remove();
  // On a phone the page is as tall as what it holds, so there is no height to share out: each picture is the board as
  // the shared screen draws it, as wide as one of the phone's two columns.
  const small = phone();
  const width = small ? SCREEN_STAGE.width : stage.clientWidth;
  const height = small ? SCREEN_STAGE.height : stage.clientHeight;
  const cells = small ? { columns: PHONE_COLUMNS, w: Math.floor((stage.clientWidth - PHONE_GAP) / PHONE_COLUMNS), h: Infinity }
    : grid(view.boards.length, { width, height, aspect: width / Math.max(1, height), head: 44 });
  stage.style.setProperty('--columns', cells.columns);
  const old = new Map([...stage.querySelectorAll(':scope > .thumb')].map((node) => [Number(node.dataset.n), node]));
  const thumbs = [];
  for (const n of view.boards) {
    let thumb = old.get(n);
    old.delete(n);
    const fresh = !thumb;
    if (fresh) {
      thumb = document.createElement(screen || print ? 'div' : 'button');
      thumb.className = 'thumb';
      if (!screen && !print) thumb.type = 'button';
      thumb.innerHTML = '<span class="thumb-head"><span class="num"></span><span class="thumb-name"></span></span>'
        + '<span class="thumb-frame"><span class="blocks mini"></span><span class="thumb-empty">Nothing on it yet</span></span>';
    }
    thumb.dataset.n = n;
    thumb.classList.toggle('target', n === view.target);
    thumb.querySelector('.num').textContent = n;
    thumb.querySelector('.thumb-name').textContent = boardName(room.boards[n - 1]);
    thumbs.push({ n, thumb, fresh });
  }
  for (const node of old.values()) node.remove();
  stage.replaceChildren(...thumbs.map((t) => t.thumb));
  if (moved && !instant) {
    stage.classList.remove('zooming');
    void stage.offsetWidth;
    stage.classList.add('zooming');
  }
  // Each picture is the board drawn at the size it has on screen alone, then made small, so it looks the same.
  const frameW = cells.w;
  const frameH = Math.max(40, cells.h - 44);
  const scale = Math.min(frameW / width, frameH / height);
  for (const { n, thumb, fresh } of thumbs) {
    if (!fresh && !moved && to !== null && to !== n) continue;
    const board = room.boards[n - 1];
    const frame = thumb.querySelector('.thumb-frame');
    frame.style.width = `${Math.round(width * scale)}px`;
    frame.style.height = `${Math.round(height * scale)}px`;
    const mini = thumb.querySelector('.mini');
    mini.style.width = `${width}px`;
    mini.style.height = `${height}px`;
    mini.style.transform = `scale(${scale})`;
    mini.hidden = !board.blocks.length;
    thumb.querySelector('.thumb-empty').hidden = Boolean(board.blocks.length);
    if (board.blocks.length) render(mini, board, { instant: true });
  }
}

function invite(on) {
  const box = $('#empty-board');
  box.hidden = !on;
  if (!on) return;
  box.querySelector('.lead').textContent = !room.listening ? 'Type in the meeting chat what to put on the board'
    : link ? 'Say what to put on the board, or tap + Block' : 'Say what to put on the board';
}

// Where an element will sit once its motion ends, on the window: offsets leave out the transforms that animate it, and
// a block or a part placed by blocks.mjs keeps where it is going in data-x and data-y.
function placed(node) {
  let left = 0;
  let top = 0;
  for (let at = node; at; at = at.offsetParent) {
    left += at.offsetLeft + Number(at.dataset?.x || 0);
    top += at.offsetTop + Number(at.dataset?.y || 0);
  }
  for (let at = node.parentElement; at; at = at.parentElement) {
    left -= at.scrollLeft;
    top -= at.scrollTop;
  }
  const width = Number(node.dataset?.w) || node.offsetWidth;
  const height = Number(node.dataset?.h) || node.offsetHeight;
  return { left, top, width, height, right: left + width, bottom: top + height };
}

function glow(node) {
  if (!node) return;
  node.classList.remove('glow');
  void node.offsetWidth;
  node.classList.add('glow');
}

// The tabs, one a board, as in a browser: the board on screen is the tab joined to the page below it (two are, side by
// side), each says its number and its name, and a new board's tab slides in at the end. With two boards or more, a tab
// at the front stands for every board at once.
function tabs(view, instant = false) {
  const nav = $('#tabs');
  const count = room.boards.length;
  if (!count || print) return nav.replaceChildren();
  const old = new Map([...nav.querySelectorAll('.tab[data-n]')].map((node) => [node.dataset.n, node]));
  const made = [];
  const tab = (key, fill) => {
    let node = old.get(key);
    old.delete(key);
    if (!node) {
      node = document.createElement('button');
      node.type = 'button';
      node.className = 'tab';
      node.dataset.n = key;
      node.innerHTML = '<span class="num"></span><span class="name"></span>';
      if (screen) node.tabIndex = -1;
      if (!instant && !reduced() && nav.childElementCount) {
        node.classList.add('entering');
        node.addEventListener('animationend', () => node.classList.remove('entering'), { once: true });
      }
    }
    fill(node);
    made.push(node);
  };
  if (count > 1) {
    tab('all', (node) => {
      node.classList.add('all');
      node.classList.toggle('on', view.mode === 'all');
      node.setAttribute('aria-current', String(view.mode === 'all'));
      node.title = 'All boards';
      node.querySelector('.num').replaceChildren(gridIcon());
      node.querySelector('.name').textContent = view.mode === 'all' ? 'All boards' : '';
    });
  }
  for (const state of tabStates(count, view)) {
    tab(String(state.n), (node) => {
      const name = boardName(room.boards[state.n - 1]);
      node.classList.toggle('on', state.on);
      node.classList.toggle('target', state.target);
      node.dataset.side = state.side || '';
      node.setAttribute('aria-current', String(state.on));
      node.title = `${state.n} ${name}`;
      node.querySelector('.num').textContent = state.n;
      node.querySelector('.name').textContent = name;
    });
  }
  for (const node of old.values()) node.remove();
  nav.replaceChildren(...made);
  // Too many tabs for their names (many boards, or the link's tools beside them): the boards not on screen show just
  // their number, as a browser's crowded tabs show just their icon, rather than "Q…"; each still names itself on hover.
  nav.classList.remove('tight');
  const cut = (name) => name.scrollWidth > name.clientWidth + 1 && name.clientWidth < TAB_NAME_MIN;
  nav.classList.toggle('tight', [...nav.querySelectorAll('.tab:not(.on) .name')].some(cut));
}

function gridIcon() {
  const icon = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
  icon.setAttribute('viewBox', '0 0 16 16');
  icon.setAttribute('aria-hidden', 'true');
  icon.innerHTML = '<rect x="1" y="1" width="6" height="6" rx="1.5"/><rect x="9" y="1" width="6" height="6" rx="1.5"/>'
    + '<rect x="1" y="9" width="6" height="6" rx="1.5"/><rect x="9" y="9" width="6" height="6" rx="1.5"/>';
  return icon;
}

// The board link, once Hermes has shared it with the room: a QR code and a short link, on the shared screen only.
let sharedAs = '';
function share() {
  const box = $('#share');
  const short = screen && room.short;
  box.hidden = !short;
  if (!short || sharedAs === short) return;
  sharedAs = short;
  const url = `${location.origin}/j/${short}`;
  box.querySelector('.short').textContent = `${location.host}/j/${short.slice(0, 5)}-${short.slice(5)}`;
  const svg = $('#qr');
  if (typeof window.qrcode !== 'function') {
    svg.hidden = true;
    return;
  }
  const code = window.qrcode(0, 'M');
  code.addData(url);
  code.make();
  const size = code.getModuleCount();
  let path = '';
  for (let y = 0; y < size; y++) for (let x = 0; x < size; x++) if (code.isDark(y, x)) path += `M${x} ${y}h1v1h-1z`;
  svg.setAttribute('viewBox', `-2 -2 ${size + 4} ${size + 4}`);
  svg.innerHTML = `<rect x="-2" y="-2" width="${size + 4}" height="${size + 4}" fill="#fff"/><path d="${path}" fill="#17202a"/>`;
}

function notice(text) {
  const box = $('#notice');
  box.textContent = text || '';
  box.style.display = text ? 'flex' : 'none';
}

// --- Hermes's cursor and people's pointers --------------------------------------------------------------------------

// The arrow's tip goes just inside the bottom-right corner, so it and its name never cover the words.
const spot = (rect) => ({ x: Math.min(rect.right - 26, innerWidth - 150), y: Math.min(rect.bottom - 16, innerHeight - 100) });

function glideTo(node, { x, y }) {
  if (!node.classList.contains('on')) {
    node.style.transition = 'none';
    node.style.transform = `translate(${x - 120}px, ${y - 80}px)`;
    void node.offsetWidth;
    node.style.transition = '';
  }
  node.style.transform = `translate(${x}px, ${y}px)`;
  node.classList.add('on');
}

let cursorTimer;
function cursorOff() {
  clearTimeout(cursorTimer);
  $('#cursor').classList.remove('on');
}

function cursorTo(rect) {
  if (!rect || print) return;
  const node = $('#cursor');
  glideTo(node, spot(rect));
  clearTimeout(cursorTimer);
  cursorTimer = setTimeout(() => node.classList.remove('on'), CURSOR_MS);
}

// Someone else with the link: their named pointer on the item it is on, by the room's id for their page.
const people = new Map();
let you = null;

function pointerTo(id, who, rect) {
  if (!rect || !id || id === you || print) return;
  let person = people.get(id);
  if (!person) {
    const node = document.createElement('div');
    node.className = 'pointer';
    node.innerHTML = '<svg viewBox="0 0 24 24"><path d="M3 2l17 9.5-7.3 1.6L9.5 21z" stroke="#fff" stroke-width="1.6" stroke-linejoin="round"/></svg><span></span>';
    $('#pointers').append(node);
    person = { node };
    people.set(id, person);
  }
  person.node.querySelector('path').setAttribute('fill', who.color);
  const label = person.node.querySelector('span');
  label.textContent = who.name;
  label.style.background = who.color;
  glideTo(person.node, spot(rect));
  person.at = performance.now();
}

// An item on board n where this page shows it (ids are unique on one board only), or on the board shown.
function rectOfItem(id, n) {
  const pane = stage.querySelector(`:scope > .pane[data-n="${Number(n) || shownN()}"]`);
  const node = pane?.querySelector(`.blocks [data-id="${CSS.escape(id)}"]`);
  return node && !stage.hidden ? placed(node) : null;
}

function pointerOf(msg) {
  if (msg.gone) {
    people.get(msg.id)?.node.remove();
    people.delete(msg.id);
    return;
  }
  if (typeof msg.at !== 'string') return;
  const rect = rectOfItem(msg.at, msg.n);
  if (rect) pointerTo(msg.id, { name: msg.name || 'Guest', color: personColor(msg.id) }, rect);
}

setInterval(() => {
  const now = performance.now();
  for (const [id, person] of people) {
    if (now - person.at > PERSON_MS) {
      person.node.remove();
      people.delete(id);
    }
  }
}, 1000);

// --- The status bar --------------------------------------------------------------------------------------------------

const bar = $('#status');
const LABELS = { hearing: 'Hearing', heard: 'Heard you', drawing: 'Drawing' };
let failedTimer;

function setBar(state, label, what, { quoted = false, hint = '' } = {}) {
  bar.dataset.state = state;
  bar.querySelector('.label').textContent = label;
  const box = bar.querySelector('.what');
  const before = box.textContent;
  box.replaceChildren();
  if (Array.isArray(what)) box.append(...what);
  else if (quoted && what) box.append(Object.assign(document.createElement('q'), { textContent: what }));
  else box.append(what || '');
  if (box.textContent !== before) {
    box.classList.remove('changed');
    void box.offsetWidth;
    box.classList.add('changed');
  }
  const tip = bar.querySelector('.hint');
  tip.replaceChildren();
  if (hint === 'undo') {
    // Typed in chat the bare name is enough; spoken it needs "Hey" (voice.mjs).
    const undo = (words) => Object.assign(document.createElement('kbd'), { textContent: words });
    if (link) tip.append('Not right? Tap Undo');
    else if (!room.listening) tip.append('Not right? Type ', undo('Hermes, undo'), ' in chat');
    else tip.append('Not right? Say ', undo('Hey Hermes, undo'));
  }
}

// 'Added “X” to Risks' as the bold word and the rest; 'Undone: added …' as 'Undone' and 'added …'.
function split(words) {
  const match = /^(\S+?)[:,]?\s+(.*)$/s.exec(words || '');
  return match ? [match[1], match[2]] : [words || '', ''];
}

// With nothing under way: how to talk to Hermes, until the first change; then the last change. While Hermes cannot hear
// spoken commands (the speech-to-text stream dropped or gave up), it says so instead, so nobody talks to it in vain.
function idle() {
  if (!room.listening) return setBar('off', '', 'Not listening, type in chat');
  const last = room.log.at(-1);
  if (!last) {
    const started = room.boards[(shownN() || 0) - 1];
    const ask = Object.assign(document.createElement('q'), { textContent: started ? 'Hey Hermes, add …' : 'Hey Hermes, start a whiteboard' });
    return setBar('idle', '', ['Say ', ask, ' or type in chat']);
  }
  const [verb, rest] = split(last.what);
  setBar('done', verb, `${rest}${last.who && last.who !== 'Hermes' ? ` · by ${last.who}` : ''}`, { hint: 'undo' });
}

function caption(msg) {
  room.caption = msg;
  clearTimeout(failedTimer);
  const state = msg?.state;
  // Words heard before the stream dropped are not being acted on: the bar says it is not listening instead.
  if (!room.listening && (state === 'hearing' || state === 'heard')) return idle();
  if (LABELS[state]) return setBar(state, LABELS[state], String(msg.text || '').replace(WAKE, ''), { quoted: true });
  if (state === 'failed') {
    setBar('failed', 'Couldn’t do that', msg.detail || String(msg.text || '').replace(WAKE, ''));
    failedTimer = setTimeout(idle, FAILED_MS);
    return;
  }
  if (state === 'done' && msg.detail) {
    const [verb, rest] = split(msg.detail);
    setBar('done', verb, rest, { hint: 'undo' });
    // While not listening, what a typed command did shows for a while, then the bar says it is not listening again.
    if (!room.listening) failedTimer = setTimeout(idle, FAILED_MS);
    return;
  }
  idle();
}

// --- The room ----------------------------------------------------------------------------------------------------------

function receive(msg) {
  if (msg.t === 'hello') {
    Object.assign(room, { boards: msg.boards || [], current: msg.current ?? null, last: msg.last ?? msg.current ?? null,
      view: msg.view || { mode: 'one' }, ended: Boolean(msg.ended), log: msg.log || [], short: msg.short || null,
      listening: msg.listening !== false });
    you = msg.you || null;
    link = msg.role === 'editor' && !screen && !print;
    failures = 0;
    if (viewing && viewing > room.boards.length) viewing = null;
    if (room.ended) return ended();
    show({ instant: true });
    caption(msg.caption);
    helloSeen();
  } else if (msg.t === 'board') {
    const was = shownView();
    room.boards[msg.n - 1] = msg.board;
    room.current = msg.current ?? room.current;
    if (msg.view) room.view = msg.view;
    if (room.current) room.last = room.current;
    // On the link, a board picked from the tabs stays picked until Hermes puts another one on screen.
    if (viewing && msg.n !== viewing && msg.by === 'hermes' && msg.n === room.current) viewing = null;
    const now = shownView();
    // Drawn when the change is on this page, or what it shows changed (a new board, or the next change's board moved).
    if (now.boards.includes(msg.n) || now.mode !== was.mode || now.target !== was.target || String(now.boards) !== String(was.boards)) {
      show({ n: msg.n, changed: msg.changed || [], by: msg.by, person: msg.person, name: msg.name, cmd: msg.cmd });
    } else tabs(now);
    if (sheet) refreshSheet();
  } else if (msg.t === 'undone') {
    room.boards = msg.boards || [];
    room.current = msg.current ?? null;
    room.last = msg.last ?? room.current;
    room.view = msg.view || { mode: 'one' };
    if (viewing && viewing > room.boards.length) viewing = null;
    show({ changed: msg.changed || [], by: 'hermes' });
    if (sheet) refreshSheet();
  } else if (msg.t === 'current') {
    room.current = msg.n;
    room.view = msg.view || { mode: 'one' };
    if (msg.n) room.last = msg.n;
    if (msg.n) viewing = null;
    show();
    if (sheet) refreshSheet();
  } else if (msg.t === 'pointer') {
    pointerOf(msg);
  } else if (msg.t === 'refused') {
    toast(`That change was not made: ${msg.error}.`);
  } else if (msg.t === 'caption') {
    caption(msg);
  } else if (msg.t === 'listening') {
    room.listening = msg.on !== false;
    // The page with no board yet says how to start one: by voice, or in the chat.
    show({ instant: true });
    // A typed command Hermes is drawing keeps the bar until it is done.
    if (room.caption?.state !== 'drawing') {
      clearTimeout(failedTimer);
      idle();
    }
  } else if (msg.t === 'log') {
    room.log = [...room.log, msg.entry].slice(-30);
    if (!$('#log').hidden) showLog();
    if (!room.caption || room.caption.state === 'done' || room.caption.state === 'failed') {
      // A change from the link has no caption of its own: the bar says it.
      if (msg.entry?.who !== 'Hermes') idle();
    }
  } else if (msg.t === 'short') {
    room.short = msg.short || null;
    share();
  } else if (msg.t === 'ended') {
    ended();
  }
}

function ended() {
  room.ended = true;
  $('#tools').hidden = true;
  closeSheet();
  notice('This board has ended. It is saved with the meeting notes.');
}

let socket = null;
let retry = 0;
// Sockets in a row that closed before the room said hello: a link that was turned off, or has ended, is refused that way.
let failures = 0;
function connect() {
  if (room.ended) return;
  const ws = socket = new WebSocket(`${location.protocol === 'http:' ? 'ws' : 'wss'}://${location.host}/b/${linkKey}/ws`);
  ws.onopen = () => { retry = 0; };
  ws.onmessage = (event) => {
    try {
      receive(JSON.parse(event.data));
    } catch (error) {
      console.log('board message', error);
    }
  };
  ws.onclose = () => {
    if (room.ended) return;
    failures += 1;
    if (failures >= 3) {
      link = false;
      $('#tools').hidden = true;
      notice('This board link does not work: it was turned off, or the call is over.');
    }
    retry = Math.min(retry + 1, 6);
    setTimeout(connect, [500, 1000, 2000, 4000, 8000, 30000][retry - 1]);
  };
}

// The arrangement depends on the page's width: a new size draws the board again, in place.
let resizing;
window.addEventListener('resize', () => {
  clearTimeout(resizing);
  resizing = setTimeout(() => { if (shownView().mode !== 'none') show({ instant: true }); }, 120);
});

// --- Changing the board from the link ---------------------------------------------------------------------------------

// Each change is one edit to the room, which checks it as it checks Hermes's and sends everyone the result.
const form = $('#sheet');
let storedName = '';
try {
  storedName = localStorage.getItem(NAME_KEY) || '';
} catch {
  // No storage on this page; the name lasts until it is closed.
}
const myName = () => storedName.trim().slice(0, 40) || 'Guest';
function saveName(value) {
  storedName = value.trim().slice(0, 40);
  try {
    localStorage.setItem(NAME_KEY, storedName);
  } catch {
    // As above.
  }
  $('#me').textContent = storedName || 'Your name';
}
$('#me').textContent = storedName || 'Your name';

const fresh = (prefix) => `${prefix}${Date.now().toString(36).slice(-4)}${Math.random().toString(36).slice(2, 6)}`;

function sendRoom(msg, { quiet = false } = {}) {
  if (socket?.readyState === 1) {
    socket.send(JSON.stringify(msg));
    return true;
  }
  if (!quiet) toast('Not connected right now. Trying again.');
  return false;
}

function toast(text) {
  const box = $('#toast');
  box.textContent = text;
  box.hidden = false;
  clearTimeout(toast.timer);
  toast.timer = setTimeout(() => { box.hidden = true; }, 4500);
}

// A form changes the board it was opened on, even when another one is on screen by the time it is saved.
function edit(op) {
  const n = sheet?.n ?? shownN();
  if (!n || !room.boards[n - 1]) return toast('There is no board to change yet.');
  if (sendRoom({ t: 'op', n, op, name: myName(), ref: fresh('r') })) closeSheet();
}

// What each type of block calls its items, in the forms.
const ITEM_WORDS = { list: 'What it says', flow: 'Step', timeline: 'Milestone', chart: 'Label', table: 'What they are compared on',
  matrix: 'Item', mindmap: 'Idea', stats: 'What it measures', funnel: 'Stage', roadmap: 'The work', tree: 'Who or what',
  swimlane: 'Step' };
const TYPE_NAMES = { list: 'List', flow: 'Flow (steps in order)', timeline: 'Timeline', chart: 'Chart (numbers)',
  table: 'Comparison table', matrix: '2x2 matrix', mindmap: 'Mind map', stats: 'Key numbers', funnel: 'Funnel (stages)',
  roadmap: 'Roadmap (work over dates)', tree: 'Org chart (who reports to whom)', swimlane: 'Swimlane (steps by who does them)' };
const STYLE_NAMES = { bar: 'Bars', line: 'A line', stacked: 'Stacked bars', donut: 'A donut (parts of a whole)', pie: 'A pie',
  heatmap: 'A heatmap (a grid of shades)' };
const STATUS_CHOICES = [['', 'Not said'], ['done', 'Done'], ['now', 'Under way'], ['next', 'Next'], ['late', 'Late']];
const KIND_NAMES = { notes: 'Notes', goals: 'Goals', risks: 'Risks', actions: 'Action items', decisions: 'Decisions', pros: 'Pros',
  cons: 'Cons' };
const QUADRANT_NAMES = { tl: 'Top left', tr: 'Top right', bl: 'Bottom left', br: 'Bottom right' };
const kindOfList = (block) => block?.kind || 'notes';
// A table's cell as typed: a number is a score, anything else words.
const cellValue = (text) => (/^\s*-?\d+(?:\.\d+)?\s*$/.test(text) ? Number(text) : text);

function control(tag, props = {}) {
  const node = document.createElement(tag);
  Object.assign(node, props);
  return node;
}
const field = (label, widget) => {
  const box = control('label');
  box.append(label, widget);
  return box;
};
const input = (name, value, { max = 90, area = false, placeholder = '', type = 'text' } = {}) => {
  const node = control(area ? 'textarea' : 'input', { name, value: value ?? '', maxLength: max, placeholder, autocomplete: 'off' });
  if (!area) node.type = type;
  return node;
};
const select = (name, options, value) => {
  const node = control('select', { name });
  node.append(...options.map(([v, words]) => new Option(words, v, false, v === (value ?? ''))));
  return node;
};
const pair = (...fields) => {
  const box = control('div', { className: 'pair' });
  box.append(...fields);
  return box;
};

// The fields for one item of `block`, filled from `item` (none for a new one).
function itemFields(board, block, item) {
  const parts = [field(ITEM_WORDS[block.type] || 'What it says', input('text', item?.text, { area: true }))];
  const columns = block.columns || [];
  if (block.type === 'list') {
    const kind = kindOfList(block);
    if (kind === 'actions' || item?.owner || item?.due) {
      parts.push(pair(field('Owner', input('owner', item?.owner, { max: 30, placeholder: 'No owner' })),
        field('Due', input('due', item?.due, { max: 30, placeholder: 'Fri Dec 5' }))));
    }
    if (kind === 'risks' || kind === 'cons' || item?.level) {
      parts.push(field('How serious', select('level', [['', 'Not said'], ['high', 'High'], ['medium', 'Medium'], ['low', 'Low']], item?.level)));
    }
  } else if (block.type === 'flow') {
    parts.push(field('Kind of step', select('shape', [['step', 'A step'], ['decision', 'A decision'], ['start', 'Start'], ['end', 'End']],
      item?.shape || 'step')));
  } else if (block.type === 'timeline') {
    parts.push(pair(field('When', input('when', item?.when, { max: 24, placeholder: 'March' })),
      field('How it stands', select('status', STATUS_CHOICES, item?.status))));
  } else if (block.type === 'chart' && !columns.length) {
    parts.push(field(`Number${block.unit ? ` (${block.unit})` : ''}`, input('value', item?.value, { max: 16, placeholder: '1200' })));
  } else if (block.type === 'chart' || block.type === 'table') {
    for (const column of columns) {
      parts.push(field(column.name, input(`cell:${column.id}`, item?.cells?.[column.id], { max: 40,
        placeholder: block.type === 'chart' ? 'A number' : `A score out of ${block.scale || 5}, or words` })));
    }
    if (!columns.length) parts.push(control('p', { className: 'hint', textContent: 'Add the options to compare in the block’s own form first.' }));
  } else if (block.type === 'matrix') {
    parts.push(field('Where it goes', select('quadrant', Object.entries(QUADRANT_NAMES)
      .map(([q, words]) => [q, block.quadrants?.[q] ? `${block.quadrants[q]} (${words.toLowerCase()})` : words]), item?.quadrant || 'tl')));
  } else if (block.type === 'mindmap' || block.type === 'tree') {
    // Anything but itself and what hangs from it.
    const under = new Set(item ? [item.id] : []);
    for (let size = -1; size !== under.size;) {
      size = under.size;
      for (const other of block.items) if (other.parent && under.has(other.parent)) under.add(other.id);
    }
    const tree = block.type === 'tree';
    parts.push(field(tree ? 'Reports to' : 'Hangs from', select('parent', [['', tree ? 'Nobody (the top)' : block.title],
      ...block.items.filter((i) => !under.has(i.id)).map((i) => [i.id, i.text])], item?.parent)));
    if (tree) parts.push(field('Role, under the name', input('note', item?.note, { max: 40, placeholder: 'Head of design' })));
  } else if (block.type === 'stats') {
    parts.push(pair(field('The number', input('value', item?.value, { max: 16, placeholder: '38%' })),
      field('Going', select('trend', [['', 'Not said'], ['up', 'Up'], ['down', 'Down'], ['flat', 'Flat']], item?.trend))));
    parts.push(pair(field('A note under it', input('note', item?.note, { max: 40, placeholder: 'vs 31% last quarter' })),
      field('Target', input('target', item?.target, { max: 16, placeholder: '45%' }))));
    parts.push(field('Recent values, oldest first', input('points', (item?.points || []).join(', '), { max: 120, placeholder: '31, 33, 36, 38' })));
  } else if (block.type === 'funnel') {
    parts.push(field(`How many${block.unit ? ` (${block.unit})` : ''}`, input('value', item?.value, { max: 16, placeholder: '1800' })));
  } else if (block.type === 'roadmap') {
    parts.push(field('Lane (team or person)', input('lane', item?.lane, { max: 24, placeholder: 'Payments' })));
    parts.push(pair(field('Starts', input('start', item?.start, { max: 24, placeholder: 'March or 2027-03-15' })),
      field('Ends', input('end', item?.end, { max: 24, placeholder: 'May' }))));
    parts.push(field('How it stands', select('status', STATUS_CHOICES, item?.status)));
  } else if (block.type === 'swimlane') {
    parts.push(pair(field('Who does it', input('lane', item?.lane, { max: 24, placeholder: 'Support' })),
      field('Kind of step', select('shape', [['step', 'A step'], ['decision', 'A decision'], ['start', 'Start'], ['end', 'End']],
        item?.shape || 'step'))));
  }
  if (item && board.blocks.length > 1) {
    parts.push(field('Block', select('block', board.blocks.map((b) => [b.id, b.title]), block.id)));
  }
  return parts;
}

// The fields for a block's own settings: its name, and what its type takes.
function blockFields(block) {
  const parts = [field('Name', input('text', block?.title, { max: 40, placeholder: 'Goals' }))];
  if (!block) {
    // A picture is Hermes's to draw: asked for out loud, never made here.
    parts.push(field('Draw it as', select('type', TYPES.filter((t) => TYPE_NAMES[t]).map((t) => [t, TYPE_NAMES[t]]), 'list')));
    parts.push(field('For a list: what it holds', select('kind', [['', 'Guess from its name'], ...KINDS.map((k) => [k, KIND_NAMES[k]])], '')));
    return parts;
  }
  if (block.type === 'list') parts.push(field('What it holds', select('kind', KINDS.map((k) => [k, KIND_NAMES[k]]), kindOfList(block))));
  if (block.type === 'chart') {
    parts.push(pair(field('Drawn as', select('style', STYLES.map((st) => [st, STYLE_NAMES[st]]), block.style || 'bar')),
      field('Unit', input('unit', block.unit, { max: 12, placeholder: '$, %, users' }))));
  }
  if (block.type === 'funnel') parts.push(field('Unit', input('unit', block.unit, { max: 12, placeholder: 'people, $' })));
  if (block.type === 'sketch') {
    parts.push(control('p', { className: 'hint', textContent: `Hermes drew this from: “${block.brief || block.title}”. To change the picture, ask Hermes.` }));
  }
  if (block.type === 'chart' || block.type === 'table') {
    const box = control('fieldset', { className: 'columns' });
    box.append(control('legend', { textContent: block.type === 'chart' ? 'Series (clear one to take it away)' : 'Options (clear one to take it away)' }));
    for (const column of block.columns || []) box.append(input(`col:${column.id}`, column.name, { max: 24 }));
    if ((block.columns || []).length < 5) box.append(input('col:new', '', { max: 24, placeholder: block.type === 'chart' ? 'Add a series' : 'Add an option' }));
    parts.push(box);
  }
  if (block.type === 'table' && (block.columns || []).length) {
    parts.push(field('Picked', select('pick', [['', 'None yet'], ...block.columns.map((c) => [c.id, c.name])], block.pick)));
  }
  return parts;
}

// The form for one thing on board n (the board shown, or the one of two the next change goes to, when not given):
// { kind: 'item' | 'new-item' | 'block' | 'new-block' | 'title' | 'name', n?, block?, item? }.
function openSheet(target) {
  const n = target.n ?? shownN();
  const board = room.boards[(n || 0) - 1];
  if (!board && target.kind !== 'name') return;
  sheet = { ...target, n };
  const { kind, block, item } = target;
  const parts = [];
  const heading = { item: 'Change this', 'new-item': `Add to ${block?.title}`, block: block?.title, 'new-block': 'New block',
    title: 'Board title', name: 'Your name' }[kind];
  parts.push(control('h3', { textContent: heading }));
  if (kind === 'name' || !storedName) {
    parts.push(field('Your name, shown to the others', input('me', storedName, { max: 40, placeholder: 'Your name' })));
  }
  if (kind === 'item' || kind === 'new-item') parts.push(...itemFields(board, block, item));
  else if (kind === 'block' || kind === 'new-block') parts.push(...blockFields(block));
  else if (kind === 'title') parts.push(field('Title', input('text', board.title, { max: 60 })));
  parts.push(control('div', { className: 'error' }));
  const buttons = control('div', { className: 'row-btns' });
  if (kind === 'item' || kind === 'block') {
    buttons.append(control('button', { type: 'button', className: 'btn bad left delete', textContent: kind === 'block' ? 'Delete block' : 'Delete' }));
  }
  buttons.append(control('button', { type: 'button', className: 'btn cancel', textContent: 'Cancel' }),
    control('button', { type: 'submit', className: 'btn main', textContent: kind.startsWith('new') ? 'Add' : 'Save' }));
  parts.push(buttons);
  form.replaceChildren(...parts);
  form.hidden = false;
  $('#sheet-back').hidden = false;
  const first = form.querySelector('[name=me]:placeholder-shown') || form.querySelector('[name=text]') || form.querySelector('input');
  first?.focus();
  if (first?.select) first.select();
}

// The thing being changed changed under the form (someone else's edit), or the page moved to another board: the form
// closes if what it changes is gone or no longer on screen, and otherwise keeps what it holds.
function refreshSheet() {
  if (!sheet || sheet.kind === 'name') return;
  const board = room.boards[sheet.n - 1];
  if (!onScreen(sheet.n)) {
    closeSheet();
    return toast('Hermes moved to another board, so that form closed.');
  }
  const found = board ? index(board) : null;
  const gone = !found || (sheet.block && !found.blocks.has(sheet.block.id)) || (sheet.item && !found.items.has(sheet.item.id));
  if (gone) {
    closeSheet();
    toast('Someone else changed that just now.');
  }
}

function closeSheet() {
  form.hidden = true;
  $('#sheet-back').hidden = true;
  sheet = null;
}

form.addEventListener('click', (event) => {
  if (event.target.closest('.cancel')) return closeSheet();
  const remove = event.target.closest('.delete');
  if (!remove || !sheet) return;
  if (sheet.kind === 'block' && sheet.block.items.length && !remove.dataset.sure) {
    remove.dataset.sure = 'yes';
    remove.textContent = `Delete it and its ${sheet.block.items.length} items`;
    return;
  }
  edit({ op: 'remove', id: sheet.kind === 'item' ? sheet.item.id : sheet.block.id });
});

form.addEventListener('submit', (event) => {
  event.preventDefault();
  if (!sheet) return;
  const value = (name) => {
    const node = form.elements.namedItem(name);
    return node && 'value' in node ? node.value.split(/\s+/).filter(Boolean).join(' ') : undefined;
  };
  const fail = (words) => { form.querySelector('.error').textContent = words; };
  const me = value('me');
  if (me !== undefined) saveName(me);
  const { kind, block, item } = sheet;
  if (kind === 'name') return closeSheet();
  const text = value('text');
  if (!text) return fail(kind === 'item' ? 'Write something, or delete it.' : 'Write something first.');
  if (kind === 'item' || kind === 'new-item') {
    const op = { op: 'item', id: kind === 'item' ? item.id : fresh('i') };
    if (kind === 'new-item') op.block = block.id;
    if (kind === 'new-item' || text !== item.text) op.text = text;
    const changes = (key, given, was = item?.[key]) => {
      if (given === undefined) return;
      if (kind === 'new-item' ? given !== '' : given !== String(was ?? '')) op[key] = given;
    };
    for (const key of ['owner', 'due', 'level', 'when', 'status', 'value', 'note', 'trend', 'quadrant', 'parent', 'lane', 'start', 'end',
      'target']) changes(key, value(key));
    changes('points', value('points'), (item?.points || []).join(', '));
    changes('shape', value('shape'), item?.shape || 'step');
    const cells = {};
    for (const column of block.columns || []) {
      const given = value(`cell:${column.id}`);
      if (given === undefined) continue;
      if (kind === 'new-item' ? given !== '' : given !== String(item?.cells?.[column.id] ?? '')) {
        cells[column.id] = block.type === 'table' && given !== '' ? cellValue(given) : given;
      }
    }
    if (Object.keys(cells).length) op.cells = cells;
    const moveTo = value('block');
    if (kind === 'item' && moveTo && moveTo !== block.id) op.block = moveTo;
    if (kind === 'item' && Object.keys(op).length === 2) return closeSheet();
    return edit(op);
  }
  if (kind === 'new-block') {
    const kindGiven = value('kind');
    const type = value('type') || 'list';
    return edit({ op: 'block', id: fresh('b'), type, title: text, ...(type === 'list' && kindGiven ? { kind: kindGiven } : {}) });
  }
  if (kind === 'block') {
    const op = { op: 'block', id: block.id };
    if (text !== block.title) op.title = text;
    for (const key of ['kind', 'style', 'unit']) {
      const given = value(key);
      if (given !== undefined && given !== String(block[key] ?? (key === 'style' ? 'bar' : key === 'kind' ? 'notes' : ''))) op[key] = given;
    }
    const columns = [];
    const removals = [];
    for (const column of block.columns || []) {
      const given = value(`col:${column.id}`);
      if (given === '') removals.push(column.id);
      else if (given && given !== column.name) columns.push({ id: column.id, name: given });
    }
    const added = value('col:new');
    if (added) columns.push({ id: fresh('c'), name: added });
    if (columns.length) op.columns = columns;
    const pick = value('pick');
    if (pick !== undefined && pick !== (block.pick || '')) op.pick = pick;
    const n = sheet.n;
    if (Object.keys(op).length > 2) edit(op);
    for (const id of removals) sendRoom({ t: 'op', n, op: { op: 'remove', id }, name: myName(), ref: fresh('r') });
    return closeSheet();
  }
  if (text !== room.boards[sheet.n - 1]?.title) return edit({ op: 'title', text });
  closeSheet();
});
form.addEventListener('keydown', (event) => {
  if (event.key === 'Escape') closeSheet();
  else if (event.key === 'Enter' && !event.shiftKey && event.target.tagName === 'TEXTAREA') {
    event.preventDefault();
    form.requestSubmit();
  }
});
$('#sheet-back').addEventListener('click', closeSheet);

// The board a tap or a pointer is on: the pane it is in.
const paneOf = (node) => Number(node?.closest?.('.pane[data-n]')?.dataset.n) || null;

// What a tap landed on: an item, a block (its title, or a mind map's middle), or nothing; with its board.
function tapped(target) {
  const n = paneOf(target);
  const board = room.boards[(n || 0) - 1];
  const node = target.closest('.blk [data-id], .blk-title');
  const article = target.closest('.blk[data-block]');
  if (!board || !article) return null;
  const found = index(board);
  const block = found.blocks.get(article.dataset.block);
  if (!block) return null;
  const id = node?.classList.contains('blk-title') ? block.id : node?.dataset.id;
  if (id && found.items.has(id)) return { kind: 'item', n, block, item: found.items.get(id).item };
  if (id === block.id) return { kind: 'block', n, block };
  return null;
}

// A tap on the board opens the form for what is under it.
if (!screen && !print) {
  document.getElementById('app').addEventListener('click', (event) => {
    if (room.ended) return;
    // A tab shows its board alone; the board on screen alone, or "every board" while that is on screen, goes back to
    // following the shared screen. Tapping the tab already shown changes the board's name.
    const tab = event.target.closest('#tabs .tab');
    const thumb = event.target.closest('.thumb[data-n]');
    if (tab || thumb) {
      const key = (tab || thumb).dataset.n;
      const before = shownView();
      const screenView = pageView({ count: room.boards.length, current: room.current, last: room.last, view: room.view,
        follows: true });
      if (key === 'all') viewing = null;
      else {
        const n = Number(key);
        if (tab && link && before.mode === 'one' && before.target === n) return openSheet({ kind: 'title', n });
        viewing = screenView.mode === 'one' && screenView.target === n ? null : n;
      }
      closeSheet();
      return show();
    }
    if (event.target.closest('#follow')) {
      viewing = null;
      closeSheet();
      return show();
    }
    if (!link) return;
    const add = event.target.closest('.blk-head .add');
    if (add) {
      const n = paneOf(add);
      const block = index(room.boards[(n || 0) - 1]).blocks.get(add.closest('.blk').dataset.block);
      if (block) return openSheet({ kind: 'new-item', n, block });
    }
    if (event.target.closest('#add-block')) return openSheet({ kind: 'new-block' });
    const target = tapped(event.target);
    if (target) return openSheet(target);
    const head = event.target.closest('.pane-name');
    if (head) return openSheet({ kind: 'title', n: paneOf(head) });
  });
  $('#undo').addEventListener('click', () => sendRoom({ t: 'undo', name: myName(), ref: fresh('r') }));
  $('#me').addEventListener('click', () => openSheet({ kind: 'name' }));
  $('#changes').addEventListener('click', () => {
    const box = $('#log');
    box.hidden = !box.hidden;
    if (!box.hidden) showLog();
  });
  $('#log-close').addEventListener('click', () => { $('#log').hidden = true; });
  // Moving over an item shows the others whose pointer is where (the item, so every page can find it).
  let pointedAt = '';
  let pointerSentAt = 0;
  document.addEventListener('pointermove', (event) => {
    if (!link || event.pointerType === 'touch' || room.ended) return;
    const at = event.target.closest?.('.pane .blk [data-id]')?.dataset.id || event.target.closest?.('.pane .blk[data-block]')?.dataset.block || '';
    const n = at ? paneOf(event.target) : null;
    const now = performance.now();
    if (`${n}:${at}` === pointedAt && now - pointerSentAt < 2000) return;
    if (now - pointerSentAt < POINTER_EVERY_MS) return;
    pointedAt = `${n}:${at}`;
    pointerSentAt = now;
    sendRoom(at ? { t: 'pointer', at, n, name: myName() } : { t: 'pointer', gone: true }, { quiet: true });
  });
  document.documentElement.addEventListener('mouseleave', () => {
    pointedAt = '';
    sendRoom({ t: 'pointer', gone: true }, { quiet: true });
  });
}

function showLog() {
  const list = $('#log ol');
  const time = (at) => {
    const date = new Date(at);
    return Number.isNaN(date.getTime()) ? '' : date.toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' });
  };
  list.replaceChildren(...[...room.log].reverse().map((entry) => {
    const item = document.createElement('li');
    item.append(Object.assign(document.createElement('span'), { className: 'who', textContent: entry.who }), ' ', entry.what,
      Object.assign(document.createElement('time'), { textContent: time(entry.at) }));
    return item;
  }));
  if (!room.log.length) list.append(Object.assign(document.createElement('li'), { textContent: 'Nothing has changed yet.' }));
}

// --- The files for the notes -----------------------------------------------------------------------------------------

// Board n as an editable .excalidraw file (canvas.mjs). Its picture is taken on a page of its own with print()
// (`print: true`), drawn as the page draws it.
async function exportBoard(n) {
  await hello;
  const board = room.boards[n - 1];
  if (!board) throw new Error(`there is no board ${n}`);
  const { scene } = await canvas.exportBoard(board);
  return { n, title: board.title, board, scene, print: true };
}

// On the print page: draws `board` as the notes' picture, with no tabs, link or status bar, every block in full.
async function printBoard(board) {
  await fonts;
  room.boards = [board];
  room.current = 1;
  room.view = { mode: 'one' };
  show({ instant: true });
  // A custom picture goes up once it has loaded as an image.
  await sketchesDrawn();
  await new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve)));
  return { width: document.documentElement.scrollWidth, height: document.documentElement.scrollHeight };
}

window.hermesBoard = {
  ready: () => (print ? fonts : Promise.all([fonts, hello])).then(() => true),
  export: exportBoard,
  print: printBoard,
  boards: () => room.boards,
};

idle();
if (print) {
  // Drawn only through print().
} else if (!/^[0-9a-f]{77}$/.test(linkKey)) notice('This board link is not complete.');
else fonts.then(connect);
