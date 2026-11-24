// A call's board room (src/room.js) without Cloudflare: a stand-in for the Durable Object base class and its storage.
// What Hermes sends is applied and passed on; what the bot hears reaches Hermes with the boards. Run: node --test bot/test/
import test from 'node:test';
import assert from 'node:assert/strict';
import { register } from 'node:module';

register(`data:text/javascript,${encodeURIComponent(`
export async function resolve(specifier, context, next) {
  if (specifier !== 'cloudflare:workers') return next(specifier, context);
  return { shortCircuit: true, url: 'data:text/javascript,' + encodeURIComponent(
    'export class DurableObject { constructor(ctx, env) { this.ctx = ctx; this.env = env; } }') };
}`)}`);
const { BoardRoom } = await import('../src/room.js');

// Cloudflare's socket pair, as the room uses it: each end records what it was sent and can be made to receive.
class FakeSocket {
  constructor() {
    Object.assign(this, { got: [], listeners: {}, closed: null });
  }

  accept() {}

  send(text) {
    this.got.push(JSON.parse(text));
  }

  close(code, reason) {
    this.closed = [code, reason];
    for (const listener of this.listeners.close || []) listener();
  }

  addEventListener(type, listener) {
    (this.listeners[type] ??= []).push(listener);
  }

  hear(data) {
    for (const listener of this.listeners.message || []) listener({ data: typeof data === 'string' ? data : JSON.stringify(data) });
  }
}
globalThis.WebSocketPair = class {
  constructor() {
    Object.assign(this, { 0: new FakeSocket(), 1: new FakeSocket() });
  }
};
const LATER = Math.floor(Date.now() / 1000) + 3600;

class Storage {
  constructor() {
    this.data = new Map();
    this.alarm = null;
  }

  async get(key) {
    return structuredClone(this.data.get(key));
  }

  async put(key, value) {
    this.data.set(key, structuredClone(value));
  }

  async deleteAll() {
    this.data.clear();
  }

  async getAlarm() {
    return this.alarm;
  }

  async setAlarm(at) {
    this.alarm = at;
  }
}

const ask = (made, path, { role = 'hermes', method = 'GET', body, headers = {} } = {}) => made.fetch(new Request(`https://room${path}`,
  { method, body: body === undefined ? undefined : JSON.stringify(body), headers: { 'x-room-role': role, ...headers } }));

// A room the Worker opened, with one watching page and one Hermes stream, each recording what it was sent.
async function room(storage = new Storage(), env = {}) {
  const made = new BoardRoom({ storage, blockConcurrencyWhile: (work) => work() }, env);
  await new Promise((resolve) => setTimeout(resolve, 0));
  if (!made.state.opened) await ask(made, '/open', { method: 'POST', body: { expires: LATER } });
  made.accepted = () => ({ status: 101 });
  const page = [];
  made.sockets.set({ send: (text) => page.push(JSON.parse(text)), close: () => {} }, { role: 'screen' });
  const hermes = [];
  made.streams.add({ write: (text) => hermes.push(text), writer: { close: async () => {} } });
  return { made, page, hermes, storage };
}

const send = (made, ...msgs) => msgs.map((msg) => made.fromHermes(msg));
const events = (hermes) => hermes.filter((t) => t.startsWith('id:') || t.startsWith('data:'))
  .map((t) => JSON.parse(t.slice(t.indexOf('data: ') + 6)));

test("Hermes's edits are applied one at a time and every page gets each new board", async () => {
  const { made, page, storage } = await room();
  const [created, title, block, item, refused] = send(made, { t: 'new', cmd: 'v1' }, { t: 'op', n: 1, op: { op: 'title', text: 'Launch' } },
    { t: 'op', n: 1, op: { op: 'block', id: 'todo', type: 'list', title: 'To do' } },
    { t: 'op', n: 1, op: { op: 'item', id: 'n1', block: 'todo', text: 'Press kit' }, cmd: 'v1' },
    { t: 'op', n: 1, op: { op: 'item', id: 'n2', block: 'nowhere', text: 'x' } });
  assert.deepEqual(created, { ok: true, n: 1 });
  assert.ok(title.ok);
  assert.deepEqual(block, { ok: true, changed: ['todo'], what: 'Added the list “To do”', block: 'To do' });
  assert.deepEqual(item, { ok: true, changed: ['n1'], what: 'Added “Press kit” to To do', added: 'To do' });
  assert.match(refused.error, /no block nowhere/);
  const boards = page.filter((m) => m.t === 'board');
  assert.deepEqual(boards.map((m) => m.seq), [1, 2, 3, 4]);
  assert.deepEqual(boards.at(-1).changed, ['n1']);
  assert.equal(boards.at(-1).cmd, 'v1');
  assert.equal(boards.at(-1).board.blocks[0].items[0].text, 'Press kit');
  assert.deepEqual(send(made, { t: 'op', n: 2, op: { op: 'title', text: 'X' } }), [{ ok: false, error: 'there is no board 2' }]);
  // Kept, so a room that restarts has its boards.
  const again = await room(storage);
  assert.equal(again.made.state.boards[0].title, 'Launch');
});

test('captions go to the pages only; stop and show change the board on screen and keep the last one', async () => {
  const { made, page, hermes } = await room();
  send(made, { t: 'new' }, { t: 'caption', state: 'drawing', text: 'add risks', cmd: 'v2' }, { t: 'stop' });
  assert.deepEqual(page.find((m) => m.t === 'caption'), { t: 'caption', state: 'drawing', text: 'add risks', detail: '', id: 'v2' });
  assert.ok(!events(hermes).some((m) => m.t === 'caption'));
  assert.deepEqual([made.state.current, made.state.last], [null, 1]);
  assert.deepEqual(send(made, { t: 'show', n: 1 }, { t: 'show', n: 3 }, { t: 'caption', state: 'shouting' }),
    [{ ok: true, n: 1, view: { mode: 'one' } }, { ok: false, error: 'there is no board 3' }, { ok: false, error: 'unknown caption state' }]);
  assert.equal(made.state.current, 1);
});

test("what the bot hears is a live caption on the pages, and a command reaches Hermes with the boards", async () => {
  const { made, page, hermes } = await room();
  send(made, { t: 'new' });
  made.fromBot({ t: 'hearing', id: 'v1', text: 'add the press' });
  assert.deepEqual(page.at(-1), { t: 'caption', state: 'hearing', text: 'add the press', id: 'v1' });
  made.fromBot({ t: 'command', id: 'v1', text: 'add the press kit', source: 'voice', direct: true });
  assert.deepEqual(page.at(-1), { t: 'caption', state: 'heard', text: 'add the press kit', id: 'v1' });
  const command = events(hermes).at(-1);
  assert.deepEqual({ ...command, at: undefined, boards: command.boards.length },
    { t: 'command', seq: 2, id: 'v1', text: 'add the press kit', source: 'voice', sender: '', direct: true, at: undefined,
      boards: 1, current: 1, last: 1, view: { mode: 'one' }, recent: [1] });
  // A typed command shows no caption: it is already on everyone's screen in the chat.
  const before = page.length;
  made.fromBot({ t: 'command', id: 'c:9', text: 'Hermes, add a risk', source: 'chat', sender: 'Lee' });
  assert.equal(page.length, before);
  assert.equal(events(hermes).at(-1).sender, 'Lee');
  made.fromBot({ t: 'presenting', on: true });
  assert.deepEqual(page.at(-1), { t: 'presenting', on: true, error: null });
});

test('a command that carries on another says which, and Hermes is told', async () => {
  const { made, hermes } = await room();
  made.fromBot({ t: 'command', id: 'v1', text: 'Hermes, add an action item: hire a designer.', source: 'voice', direct: true });
  made.fromBot({ t: 'command', id: 'v2', text: 'Hermes, due Friday.', source: 'voice', direct: true, continues: 'v1' });
  made.fromBot({ t: 'command', id: 'v3', text: 'Hermes, add a risk', source: 'voice', direct: true, continues: 'x'.repeat(80) });
  const [one, two, three] = events(hermes).filter((e) => e.t === 'command');
  assert.equal('continues' in one, false);
  assert.equal(two.continues, 'v1');
  assert.equal(three.continues.length, 40);
});

test('a Hermes that reconnects gets the room as it is, then the commands it missed', async () => {
  const { made } = await room();
  send(made, { t: 'new' });
  made.fromBot({ t: 'command', id: 'v1', text: 'one' });
  made.fromBot({ t: 'command', id: 'v2', text: 'two' });
  const response = made.events(2);
  // The stream's keep-alive would hold the test open.
  clearInterval(made.pinger);
  assert.equal(response.headers.get('content-type'), 'text/event-stream');
  const reader = response.body.getReader();
  let text = '';
  while (!text.includes('"t":"command"')) text += new TextDecoder().decode((await reader.read()).value);
  await reader.cancel();
  const sent = text.split('\n\n').filter(Boolean).map((block) => JSON.parse(block.slice(block.indexOf('data: ') + 6)));
  assert.deepEqual(sent.map((m) => m.t), ['hello', 'command']);
  assert.equal(sent[0].boards.length, 1);
  assert.equal(sent[1].text, 'two');
});

test('a command the bot sends again is taken once, and the bot is told each time that the room has it', async () => {
  const { made, hermes } = await room();
  const bot = [];
  const line = { send: (text) => bot.push(JSON.parse(text)) };
  made.fromBot({ t: 'command', id: 'v1', text: 'add the press kit', source: 'voice' }, line);
  made.fromBot({ t: 'command', id: 'v1', text: 'add the press kit', source: 'voice' }, line);
  assert.deepEqual(bot, [{ t: 'got', id: 'v1' }, { t: 'got', id: 'v1' }]);
  assert.equal(events(hermes).filter((e) => e.t === 'command').length, 1);
  assert.equal(made.state.events.length, 1);
});

test('a command Hermes finished is marked, so a Hermes that restarts is told not to do it again', async () => {
  const { made } = await room();
  made.fromBot({ t: 'command', id: 'v1', text: 'one' });
  made.fromBot({ t: 'command', id: 'v2', text: 'two' });
  send(made, { t: 'caption', state: 'done', detail: 'Added “one”', cmd: 'v1' });
  const response = made.events(0);
  clearInterval(made.pinger);
  const reader = response.body.getReader();
  let text = '';
  while ((text.match(/"t":"command"/g) || []).length < 2) text += new TextDecoder().decode((await reader.read()).value);
  await reader.cancel();
  const sent = text.split('\n\n').filter(Boolean).map((block) => JSON.parse(block.slice(block.indexOf('data: ') + 6)));
  assert.deepEqual(sent.filter((m) => m.t === 'command').map((m) => [m.id, Boolean(m.finished)]), [['v1', true], ['v2', false]]);
});

test('an undo is finished as it happens, so a Hermes that restarts never undoes a second change for it', async () => {
  const { made } = await room();
  send(made, { t: 'new' });
  send(made, { t: 'op', n: 1, op: { op: 'title', text: 'First' }, cmd: 'v1' });
  send(made, { t: 'op', n: 1, op: { op: 'title', text: 'Second' }, cmd: 'v2' });
  made.fromBot({ t: 'command', id: 'v3', text: 'Hermes, undo that' });
  assert.equal(send(made, { t: 'undo', cmd: 'v3' })[0].ok, true);
  assert.equal(made.state.boards[0].title, 'First');
  assert.equal(made.state.events.find((e) => e.id === 'v3').finished, true);
});

test('a command makes at most one board: asked again, the room gives the board it made', async () => {
  const { made } = await room();
  assert.deepEqual(send(made, { t: 'new', cmd: 'v1' }, { t: 'new', cmd: 'v1' }), [{ ok: true, n: 1 }, { ok: true, n: 1 }]);
  assert.deepEqual(send(made, { t: 'new', cmd: 'v2' }), [{ ok: true, n: 2 }]);
  assert.equal(made.state.boards.length, 2);
  // Once an undo takes its board away, the command's board is gone, and asking again makes it anew.
  send(made, { t: 'undo', cmd: 'v3' });
  assert.deepEqual(send(made, { t: 'new', cmd: 'v2' }), [{ ok: true, n: 2 }]);
  assert.equal(made.state.boards.length, 2);
});

test('the bot says whether it can hear spoken commands: pages are told, and a page that opens later too', async () => {
  const { made, page, hermes, storage } = await room();
  made.fromBot({ t: 'hearing', id: 'v1', text: 'add Kim to the' });
  made.fromBot({ t: 'listening', on: false });
  assert.deepEqual(page.at(-1), { t: 'listening', on: false });
  assert.equal(made.snapshot().caption, null, 'half-heard words are not shown to a page that opens later');
  const told = page.length;
  made.fromBot({ t: 'listening', on: false });
  assert.equal(page.length, told, 'no change, no message');
  assert.equal((await room(storage)).made.snapshot().listening, false, 'kept with the room');
  made.fromBot({ t: 'listening', on: true });
  assert.deepEqual(page.at(-1), { t: 'listening', on: true });
  assert.equal(made.snapshot().listening, true);
  assert.ok(!hermes.some((text) => text.includes('listening')), 'Hermes reads the voice state from /status instead');
});

test('a closed room forgets its boards, tells everyone, and refuses more', async () => {
  const { made, page, storage } = await room();
  send(made, { t: 'new' }, { t: 'new' });
  assert.deepEqual(await made.close(), { ok: true, boards: 2 });
  assert.equal(page.at(-1).t, 'ended');
  assert.deepEqual(made.state.boards, []);
  assert.equal(made.sockets.size, 0);
  assert.deepEqual(send(made, { t: 'new' }), [{ ok: false, error: 'the call is over' }]);
  assert.ok(storage.alarm > Date.now() + 23 * 3600 * 1000);
});

test('the room holds at most nine boards', async () => {
  const { made } = await room();
  const results = send(made, ...Array.from({ length: 10 }, () => ({ t: 'new' })));
  assert.deepEqual(results.at(-2), { ok: true, n: 9 });
  assert.match(results.at(-1).error, /at most 9/);
});

// Someone opening the board link from `address`, as the room sees their socket: what it was sent, and what it says.
function person(made, { address = '203.0.113.7', role = 'editor', link = made.state.link } = {}) {
  const answer = made.socket(role, address, link);
  if (answer.status !== 101) return { status: answer.status };
  const ws = [...made.sockets.keys()].at(-1);
  const who = made.sockets.get(ws);
  return { ws, who, got: ws.got, status: 101, say: (msg) => ws.hear(msg) };
}

test('someone with the link edits through the same checks as Hermes, and everyone sees it, Hermes too', async () => {
  const { made, page, hermes } = await room();
  send(made, { t: 'new' }, { t: 'op', n: 1, op: { op: 'block', id: 'todo', type: 'list', title: 'To do' } });
  const lee = person(made);
  lee.say({ t: 'op', n: 1, op: { op: 'item', id: 'p1', block: 'todo', text: 'Call Kim' }, name: 'Lee', ref: 'r1' });
  const board = page.at(-1);
  assert.deepEqual({ t: board.t, n: board.n, changed: board.changed, by: board.by, name: board.name, person: board.person },
    { t: 'board', n: 1, changed: ['p1'], by: 'person', name: 'Lee', person: lee.who.id });
  assert.equal(made.state.boards[0].blocks[0].items[0].text, 'Call Kim');
  assert.equal(events(hermes).at(-1).by, 'person');
  assert.equal(lee.got.at(-1).t, 'board', 'the editor gets the board like everyone');
  lee.say({ t: 'op', n: 1, op: { op: 'item', id: 'p2', block: 'nowhere', text: 'x' }, ref: 'r2' });
  lee.say({ t: 'op', n: 4, op: { op: 'title', text: 'x' }, ref: 'r3' });
  assert.deepEqual(lee.got.slice(-2).map((m) => [m.t, m.ref, m.error]),
    [['refused', 'r2', 'there is no block nowhere'], ['refused', 'r3', 'there is no board 4']]);
  assert.equal(page.at(-1), board, 'a refused edit reaches nobody else');
});

test('one address cannot flood the board: past its allowance edits are refused, a new socket gets none, then later more', async () => {
  const { made } = await room();
  let now = Date.now();
  made.now = () => now;
  send(made, { t: 'new' });
  const lee = person(made);
  for (let i = 0; i < 25; i++) lee.say({ t: 'op', n: 1, op: { op: 'title', text: `Plan ${i}` } });
  assert.equal(made.state.boards[0].title, 'Plan 19');
  assert.match(lee.got.at(-1).error, /too many changes/);
  // Reconnecting, or a second tab, is the same address with the same allowance.
  const again = person(made);
  again.say({ t: 'op', n: 1, op: { op: 'title', text: 'Reset?' } });
  assert.equal(made.state.boards[0].title, 'Plan 19');
  assert.match(again.got.at(-1).error, /too many changes/);
  // Refused tries cost too, so the wait is for the whole overdraft: 26 tries past the allowance at 5 a second.
  now += 6000;
  lee.say({ t: 'op', n: 1, op: { op: 'title', text: 'Later' } });
  assert.equal(made.state.boards[0].title, 'Later');
});

test("many addresses together are held to the room's own allowance", async () => {
  const { made } = await room();
  const now = Date.now();
  made.now = () => now;
  send(made, { t: 'new' });
  const people = Array.from({ length: 8 }, (_, i) => person(made, { address: `198.51.100.${i}` }));
  for (const [i, one] of people.entries()) for (let j = 0; j < 10; j++) one.say({ t: 'op', n: 1, op: { op: 'title', text: `T${i}-${j}` } });
  const made80 = made.state.seq - 1;
  assert.equal(made80, 60, 'the room took 60 of the 80 edits');
  assert.match(people.at(-1).got.at(-1).error, /too many changes/);
});

test("an address past its own allowance spends none of the room's, so everyone else still gets in and edits", async () => {
  const { made } = await room();
  const now = Date.now();
  made.now = () => now;
  send(made, { t: 'new' });
  // 70 tries at once from one address: it gets its 8 sockets, and only those cost the room.
  const lee = Array.from({ length: 70 }, () => person(made));
  assert.equal(lee.filter((p) => p.status === 101).length, 8);
  assert.equal(person(made, { address: '198.51.100.1' }).status, 101, 'another address still gets in');
  // 79 edits at once from one address (just under its message limit): 20 are applied, and only those cost the room.
  for (let i = 0; i < 79; i++) lee[0].say({ t: 'op', n: 1, op: { op: 'title', text: `Lee ${i}` } });
  assert.equal(made.state.boards[0].title, 'Lee 19');
  const kim = person(made, { address: '198.51.100.2' });
  kim.say({ t: 'op', n: 1, op: { op: 'title', text: 'Kim' } });
  assert.equal(made.state.boards[0].title, 'Kim', "another address's edit still goes through");
});

test('a room the API did not open answers nothing, keeps nothing and sets no alarm', async () => {
  const storage = new Storage();
  const made = new BoardRoom({ storage, blockConcurrencyWhile: (work) => work() }, {});
  await new Promise((resolve) => setTimeout(resolve, 0));
  for (const [path, role] of [['/socket', 'editor'], ['/socket', 'bot'], ['/state', 'hermes'], ['/events', 'hermes'], ['/close', 'hermes']]) {
    assert.equal((await ask(made, path, { role, method: path === '/close' ? 'POST' : 'GET' })).status, 404, path);
  }
  assert.equal((await ask(made, '/open', { role: 'editor', method: 'POST', body: { expires: LATER } })).status, 404);
  assert.equal(storage.data.size, 0);
  assert.equal(storage.alarm, null);
  await made.alarm();
  assert.equal(storage.data.size, 0, 'an alarm left from before only empties it');
  assert.equal((await ask(made, '/open', { method: 'POST', body: { expires: LATER } })).status, 200);
  assert.ok(storage.alarm > Date.now() + 11 * 3600 * 1000);
  assert.equal((await ask(made, '/open', { method: 'POST', body: { expires: LATER } })).status, 409);
  assert.equal((await ask(made, '/state')).status, 200);
});

test('sockets are limited per address and per room, and an address that floods is cut off for a minute', async () => {
  const { made } = await room();
  let now = Date.now();
  made.now = () => now;
  const lee = Array.from({ length: 9 }, () => person(made));
  assert.deepEqual(lee.map((p) => p.status), [...Array(8).fill(101), 429], 'eight sockets from one address');
  lee[0].ws.close();
  assert.equal(person(made).status, 101, 'a closed socket frees its place');
  for (let i = 0; i < 3; i++) person(made);
  assert.equal(person(made).status, 429, 'and at most 12 tries a minute from one address');
  // Many addresses at once: the room's own limit.
  const crowd = Array.from({ length: 60 }, (_, i) => person(made, { address: `198.51.100.${i}` }));
  assert.ok(crowd.some((p) => p.status === 429));
  assert.equal([...made.sockets.values()].filter((w) => w.client).length, 50, 'at most 50 people at once');
  for (const one of [...lee, ...crowd]) one.ws?.close();
  // The bot's own sockets are not people and are not counted with them.
  assert.equal(made.socket('bot', '', 0).status, 101);
  // Flooding: every message costs, refused or not; past twice the allowance the address's sockets close.
  now += 120000;
  const kim = person(made, { address: '192.0.2.50' });
  const kimToo = person(made, { address: '192.0.2.50' });
  for (let i = 0; i < 200; i++) kim.say({ t: 'pointer', x: i, y: 1, name: 'Kim' });
  assert.deepEqual(kim.ws.closed, [1008, 'too many messages']);
  assert.deepEqual(kimToo.ws.closed, [1008, 'too many messages'], "all the address's sockets");
  assert.equal(person(made, { address: '192.0.2.50' }).status, 429);
  now += 61000;
  assert.equal(person(made, { address: '192.0.2.50' }).status, 101);
});

test('malformed messages are refused without an exception, and edit names are only the real ones', async () => {
  const { made } = await room();
  send(made, { t: 'new' });
  const lee = person(made);
  for (const bad of ['null', '[]', '7', '"op"', JSON.stringify({ t: 'op', n: 1, op: null }),
    JSON.stringify({ t: 'op', n: 1, op: { op: '__proto__' } }), JSON.stringify({ t: 'op', n: 1, op: { op: 'constructor' } }),
    JSON.stringify({ t: 'op', n: 1, op: { op: 'toString' } })]) {
    assert.doesNotThrow(() => lee.ws.hear(bad), bad);
  }
  assert.deepEqual(lee.got.filter((m) => m.t === 'refused').map((m) => m.error),
    ['unknown edit undefined', 'unknown edit __proto__', 'unknown edit constructor', 'unknown edit toString']);
  assert.deepEqual(send(made, null, [], { t: 'op', n: 1, op: { op: '__proto__' } }).map((r) => r.error),
    ['unknown message', 'unknown message', 'unknown edit __proto__']);
  const big = await ask(made, '/send', { method: 'POST', body: { msgs: Array(51).fill({ t: 'caption', state: 'idle' }) } });
  assert.equal(big.status, 413);
});

test('a watch-only link and the shared screen cannot edit, and a link from an older version is refused', async () => {
  const { made } = await room();
  send(made, { t: 'new' });
  const watcher = person(made, { role: 'watcher' });
  assert.equal(watcher.got[0].role, 'watcher');
  watcher.say({ t: 'op', n: 1, op: { op: 'title', text: 'Mine now' } });
  watcher.say({ t: 'pointer', x: 1, y: 1 });
  const screen = person(made, { role: 'screen' });
  screen.say({ t: 'op', n: 1, op: { op: 'title', text: 'Mine now' } });
  assert.equal(made.state.boards[0].title, 'Whiteboard');
  assert.equal(person(made, { link: made.state.link + 1 }).status, 410);
  assert.equal(person(made, { link: 0 }).status, 410);
});

test('turning the link off cuts off everyone on it and every older link, but not the shared screen or the bot', async () => {
  const { made, page, hermes, storage } = await room();
  send(made, { t: 'new' });
  const lee = person(made);
  const watcher = person(made, { role: 'watcher', address: '198.51.100.9' });
  const screen = person(made, { role: 'screen', link: 1 });
  const bot = person(made, { role: 'bot', link: 0 });
  const before = hermes.length;
  const answer = await ask(made, '/link', { method: 'POST' });
  assert.deepEqual(await answer.json(), { version: 2, expires: LATER });
  assert.deepEqual([lee.ws.closed, watcher.ws.closed], [[4403, 'this link was turned off'], [4403, 'this link was turned off']]);
  assert.deepEqual([screen.ws.closed, bot.ws.closed], [null, null]);
  assert.deepEqual(page.at(-1), { t: 'short', seq: made.state.seq, short: null }, 'the screen stops showing a short link');
  assert.equal(hermes.length, before, 'Hermes is not told');
  assert.equal(person(made, { link: 1 }).status, 410, 'the old link no longer works');
  assert.equal(person(made, { link: 2, address: '192.0.2.70' }).status, 101, "a link signed for the new version does");
  assert.equal(person(made, { role: 'screen', link: 1 }).status, 101, 'the shared screen reconnects with its own link');
  assert.deepEqual(await made.share(), { ok: false, error: 'the owner hands out this link' },
    'a share already on its way puts no short link on the screen');
  assert.equal(made.snapshot().short, null);
  assert.equal((await ask(made, '/link', { method: 'POST', role: 'editor' })).status, 404, 'only Hermes turns it off');
  const stored = await room(storage);
  assert.equal(stored.made.state.link, 2, 'a room woken later still refuses the old link');
  await ask(made, '/close', { method: 'POST' });
  assert.equal((await ask(made, '/link', { method: 'POST' })).status, 409);
});

test("a pointer reaches only the other pages, and the bot's own line cannot edit", async () => {
  const { made, page, hermes } = await room();
  let now = Date.now();
  made.now = () => now;
  send(made, { t: 'new' });
  const before = hermes.length;
  const lee = person(made);
  const kim = person(made, { address: '198.51.100.9' });
  const hellos = lee.got.length;
  for (let i = 0; i < 30; i++) lee.say({ t: 'pointer', x: 100 + i, y: 80, name: 'Lee' });
  assert.deepEqual(kim.got.at(-1), { t: 'pointer', id: lee.who.id, name: 'Lee', x: 124, y: 80 }, 'a burst of 25, then 25 a second');
  assert.deepEqual(page.at(-1), kim.got.at(-1));
  assert.equal(lee.got.length, hellos);
  now += 2000;
  lee.say({ t: 'pointer', x: 120, y: 80, name: 'Lee' });
  lee.say({ t: 'pointer', x: 'left', y: 1e9 });
  assert.deepEqual(kim.got.at(-1).x, 120, 'a pointer off any board is dropped');
  lee.say({ t: 'pointer', gone: true });
  assert.deepEqual(kim.got.at(-1), { t: 'pointer', id: lee.who.id, gone: true });
  assert.equal(hermes.length, before);
  made.fromBot({ t: 'op', n: 1, op: { op: 'title', text: 'Bot' } });
  assert.equal(made.state.boards[0].title, 'Whiteboard');
});

test("undo puts back everything the last command did, then the one before, and a board it made goes away", async () => {
  const { made, page, hermes } = await room();
  send(made, { t: 'new', cmd: 'v1' }, { t: 'op', n: 1, op: { op: 'block', id: 'r', type: 'list', title: 'Risks' }, cmd: 'v1' },
    { t: 'caption', state: 'done', detail: 'Started “Launch”', cmd: 'v1' },
    { t: 'op', n: 1, op: { op: 'item', id: 'a', block: 'r', text: 'One designer' }, cmd: 'v2' },
    { t: 'op', n: 1, op: { op: 'item', id: 'b', block: 'r', text: 'Stripe review' }, cmd: 'v2' },
    { t: 'caption', state: 'done', detail: 'Added 2 items to Risks', cmd: 'v2' });
  const [undone] = send(made, { t: 'undo', cmd: 'v3' });
  assert.deepEqual(undone, { ok: true, what: 'Undone: added 2 items to Risks', changed: [1], boards: 1, current: 1 });
  assert.deepEqual(made.state.boards[0].blocks[0].items, []);
  const told = page.filter((m) => m.t === 'undone').at(-1);
  assert.equal(told.boards[0].blocks[0].title, 'Risks');
  assert.equal(events(hermes).at(-1).t, 'undone');
  assert.deepEqual(page.at(-1), { t: 'caption', state: 'done', text: '', detail: 'Undone: added 2 items to Risks', id: 'v3' });
  // The step before made the board: undoing it takes the board away and nothing is on screen.
  assert.equal(send(made, { t: 'undo' })[0].boards, 0);
  assert.deepEqual([made.state.boards, made.state.current, made.state.last], [[], null, null]);
  assert.deepEqual(send(made, { t: 'undo' }), [{ ok: false, error: 'there is nothing to undo' }]);
  assert.deepEqual(made.state.log.map((l) => [l.what, l.who]), [['Started “Launch”', 'Hermes'],
    ['Added 2 items to Risks', 'Hermes'], ['Undone: added 2 items to Risks', 'Hermes'], ['Undone: started “Launch”', 'Hermes']]);
});

test('a room kept from before blocks opens with its boards as lists, every note there, and its undo still works', async () => {
  const storage = new Storage();
  const old = (notes) => ({ title: 'Retro', layout: 'columns', arrows: [],
    sections: [{ id: 'w', title: 'Went well', notes }, { id: 'a', title: 'Action items', notes: [{ id: 'n9', text: 'Fix CI', owner: 'Kim' }] }] });
  const shipped = { id: 'n1', text: 'Shipped on time' };
  await storage.put('state', { opened: true, expires: LATER, seq: 4, current: 1, last: 1,
    boards: [old([shipped, { id: 'n2', text: 'Fast reviews' }])],
    history: [{ key: 'k', count: 1, current: 1, last: 1, boards: { 1: old([shipped]) }, what: 'Added “Fast reviews” to Went well' }] });
  const { made, page } = await room(storage);
  assert.deepEqual(made.state.boards[0].blocks.map((b) => [b.type, b.kind, b.items.map((i) => i.text)]),
    [['list', 'pros', ['Shipped on time', 'Fast reviews']], ['list', 'actions', ['Fix CI']]]);
  const [undone] = send(made, { t: 'undo' });
  assert.equal(undone.ok, true);
  assert.deepEqual(made.state.boards[0].blocks[0].items.map((i) => i.text), ['Shipped on time']);
  assert.ok(Array.isArray(page.filter((m) => m.t === 'undone').at(-1).boards[0].blocks));
});

test('the Undo button on the link takes back the last change, whoever made it, and the log names who did what', async () => {
  const { made, page } = await room();
  send(made, { t: 'new', cmd: 'v1' }, { t: 'op', n: 1, op: { op: 'block', id: 'r', type: 'list', title: 'Risks' }, cmd: 'v1' });
  const lee = person(made);
  lee.say({ t: 'op', n: 1, op: { op: 'item', id: 'p1', block: 'r', text: 'Call Kim' }, name: 'Lee' });
  lee.say({ t: 'op', n: 1, op: { op: 'title', text: 'Launch' }, name: 'Lee' });
  assert.equal(page.filter((m) => m.t === 'log').at(-1).entry.who, 'Lee');
  lee.say({ t: 'undo', name: 'Lee' });
  assert.equal(made.state.boards[0].title, 'Whiteboard');
  assert.equal(made.state.boards[0].blocks[0].items.length, 1, 'each change from the link is its own step');
  assert.equal(made.state.log.at(-1).what, 'Undone: named the board “Launch”');
  // A limit on undo too: it counts as a change (here the address has spent its allowance and more).
  lee.who.client.edits.left = -lee.who.client.edits.size;
  lee.say({ t: 'undo' });
  assert.match(lee.got.at(-1).error, /too many changes/);
});

test('the recap goes on screen as a board of its own, and the bot leaving asks for it', async () => {
  const { made, page, hermes } = await room();
  assert.match(send(made, { t: 'recap' })[0].error, /nothing to recap/);
  send(made, { t: 'new' }, { t: 'op', n: 1, op: { op: 'block', id: 'a', type: 'list', title: 'Action items' } },
    { t: 'op', n: 1, op: { op: 'item', id: 'h', block: 'a', text: 'Hire a designer', owner: 'Lee' } }, { t: 'stop' });
  assert.deepEqual(send(made, { t: 'recap', cmd: 'v9' }), [{ ok: true, n: 2, text: 'Recap. Action items: Hire a designer (Lee).' }]);
  assert.deepEqual([made.state.current, made.state.boards[1].recap], [2, true]);
  // Asked again (the bot leaving), the same recap board is brought up to date, not made twice.
  const bot = [];
  made.fromBot({ t: 'recap' }, { send: (text) => bot.push(JSON.parse(text)) });
  assert.equal(made.state.boards.length, 2);
  assert.deepEqual(bot, [{ t: 'recapped', ok: true, n: 2, text: 'Recap. Action items: Hire a designer (Lee).' }]);
  const told = events(hermes).at(-1);
  assert.deepEqual([told.t, told.recap, told.auto, told.n], ['board', true, true, 2]);
  assert.equal(page.at(-1).board.title, 'Recap');
});

test('a board asked for by name arrives whole in one message; a plain new board is empty', async () => {
  const { made } = await room();
  send(made, { t: 'new', board: { v: 2, title: 'Retro', blocks: [{ id: 'well', type: 'list', title: 'Went well', kind: 'pros', items: [] }] } });
  assert.deepEqual(made.state.boards[0].blocks, [{ id: 'well', type: 'list', title: 'Went well', kind: 'pros', items: [] }]);
  // One from a Hermes that has not caught up (sections of notes) comes in as lists.
  send(made, { t: 'new', board: { title: 'Old', sections: [{ id: 'r', title: 'Risks', notes: [{ id: 'n', text: 'Slip' }] }] } });
  assert.deepEqual(made.state.boards[1].blocks, [{ id: 'r', type: 'list', title: 'Risks', kind: 'risks', items: [{ id: 'n', text: 'Slip' }] }]);
  send(made, { t: 'new' });
  assert.deepEqual(made.state.boards[2], { v: 2, title: 'Whiteboard', blocks: [] });
});

test('sharing the link with the room puts a short link on the screen, once, for the pages only, while the link works', async () => {
  const held = new Map();
  const SHORT_LINKS = { idFromName: (name) => name, get: (name) => ({ fetch: async (url, init) => {
    const { token } = JSON.parse(init.body);
    if (held.has(name) && held.get(name) !== token) return new Response('taken', { status: 409 });
    held.set(name, token);
    return Response.json({ ok: true });
  } }) };
  const token = 'ab'.repeat(16);
  const { made, page, hermes } = await room(new Storage(), { SHORT_LINKS, API_TOKEN: 'test-api-token' });
  const share = () => ask(made, '/send', { method: 'POST', headers: { 'x-room-token': token },
    body: { msgs: [{ t: 'new' }, { t: 'link' }] } }).then((r) => r.json());
  const before = events(hermes).length;
  const { short } = (await share()).results[1];
  assert.match(short, /^[a-hj-km-np-z2-9]{10}$/, 'no letters that look alike');
  assert.equal(held.get(short), token);
  assert.deepEqual(page.at(-1), { t: 'short', seq: made.state.seq, short });
  assert.equal(events(hermes).length - before, 1, 'Hermes hears of the board, not of the short link');
  assert.equal((await share()).results[1].short, short);
  assert.equal(held.size, 1, 'one short link per room');
  assert.equal(made.snapshot().short, short);
  assert.deepEqual(await (await ask(made, '/short')).json(), { version: 1, expires: LATER, ended: false, short });
  // A new link version (the link turned off, or made again) ends the short link with it.
  made.state.link = 2;
  assert.equal(made.snapshot().short, null);
  const none = await room();
  assert.deepEqual(await none.made.share(), { ok: false, error: 'no short link here' });
});

test('a link turned off, or a call that ends, while a short link is being made puts no short link on the screen', async () => {
  for (const meanwhile of ['/link', '/close']) {
    let made;
    const SHORT_LINKS = { idFromName: (name) => name, get: () => ({ fetch: async () => {
      await ask(made, meanwhile, { method: 'POST' });
      return Response.json({ ok: true });
    } }) };
    ({ made } = await room(new Storage(), { SHORT_LINKS, API_TOKEN: 'test-api-token' }));
    made.token = 'ab'.repeat(16);
    send(made, { t: 'new' });
    const answer = await made.share();
    assert.deepEqual(answer, { ok: false, error: meanwhile === '/link' ? 'the owner hands out this link' : 'the call is over' },
      meanwhile);
    assert.equal(made.state.short ?? null, null, meanwhile);
  }
});

test('on the lists a pointer is the item it is on, so every page can find it', async () => {
  const { made } = await room();
  send(made, { t: 'new' });
  const lee = person(made);
  const kim = person(made, { address: '198.51.100.9' });
  lee.say({ t: 'pointer', at: 'n:<b>hire', name: 'Lee' });
  assert.deepEqual(kim.got.at(-1), { t: 'pointer', id: lee.who.id, name: 'Lee', at: 'n:bhire' });
  // With two boards side by side, the item's board too; a board number that cannot be is left out.
  lee.say({ t: 'pointer', at: 'n:hire', n: 2, name: 'Lee' });
  assert.equal(kim.got.at(-1).n, 2);
  lee.say({ t: 'pointer', at: 'n:hire', n: 'two', name: 'Lee' });
  assert.equal('n' in kim.got.at(-1), false);
});

test('two boards side by side, or every board at once: the room checks the ask, and every page and Hermes are told', async () => {
  const { made, page, hermes } = await room();
  send(made, { t: 'new', title: 'Launch' }, { t: 'new', title: 'Pricing' }, { t: 'new', title: 'Hiring' });
  assert.deepEqual(send(made, { t: 'show', n: 1, split: [1, 3], cmd: 'v1' }),
    [{ ok: true, n: 1, view: { mode: 'split', boards: [1, 3] } }]);
  assert.deepEqual(page.at(-1), { t: 'current', seq: 4, n: 1, view: { mode: 'split', boards: [1, 3] }, cmd: 'v1' });
  assert.deepEqual(send(made, { t: 'show', n: 2, split: [1, 3] }, { t: 'show', n: 1, split: [1, 1] },
    { t: 'show', n: 1, split: [1, 7] }, { t: 'show', n: 1, split: 'both' }), [
    { ok: false, error: 'board 2 is not one of the two' }, { ok: false, error: 'side by side takes two boards the call has' },
    { ok: false, error: 'side by side takes two boards the call has' }, { ok: false, error: 'side by side takes two boards the call has' }]);
  // A change to the other board of the two makes it the one the next change goes to.
  send(made, { t: 'op', n: 3, op: { op: 'title', text: 'Design hire' }, cmd: 'v2' });
  assert.deepEqual([made.state.current, made.state.last], [3, 3]);
  assert.deepEqual(page.at(-1).view, { mode: 'split', boards: [1, 3] });
  // A change to a board not on screen leaves the screen as it is.
  send(made, { t: 'op', n: 2, op: { op: 'title', text: 'Prices' } });
  assert.equal(made.state.current, 3);
  assert.deepEqual(send(made, { t: 'show', n: 3, all: true }), [{ ok: true, n: 3, view: { mode: 'all' } }]);
  const told = events(hermes);
  made.fromBot({ t: 'command', id: 'v5', text: 'add a risk', source: 'voice', direct: true });
  const command = events(hermes).at(-1);
  assert.ok(events(hermes).length > told.length);
  assert.deepEqual([command.view, command.current, command.recent], [{ mode: 'all' }, 3, [3, 1, 2]]);
  // The snapshot a page or Hermes opens with has the view too.
  assert.deepEqual(made.snapshot().view, { mode: 'all' });
  // A new board opens alone, as a new tab does.
  send(made, { t: 'new', title: 'Questions' });
  assert.deepEqual([made.state.current, made.view()], [4, { mode: 'one' }]);
  // One board cannot be shown with every board.
  const one = await room();
  send(one.made, { t: 'new' });
  assert.deepEqual(send(one.made, { t: 'show', n: 1, all: true }), [{ ok: false, error: 'there is only one board' }]);
});

test('undo puts the screen back as it was: one board, two side by side, or every board', async () => {
  const { made, page } = await room();
  send(made, { t: 'new', title: 'Launch', cmd: 'v1' }, { t: 'new', title: 'Pricing', cmd: 'v2' },
    { t: 'new', title: 'Hiring', cmd: 'v3' });
  send(made, { t: 'show', n: 1, split: [1, 2], cmd: 'v4' }, { t: 'caption', state: 'done', detail: 'Showing 1 and 2 side by side', cmd: 'v4' });
  send(made, { t: 'show', n: 3, cmd: 'v5' }, { t: 'caption', state: 'done', detail: 'Showing Hiring', cmd: 'v5' });
  const [undone] = send(made, { t: 'undo', cmd: 'v6' });
  // The status bar says what is back on screen, not the move that was taken back.
  assert.deepEqual([undone.what, undone.current], ['Undone: back to Launch and Pricing side by side', 1]);
  assert.deepEqual(made.view(), { mode: 'split', boards: [1, 2] });
  assert.deepEqual(page.filter((m) => m.t === 'undone').at(-1).view, { mode: 'split', boards: [1, 2] });
  assert.deepEqual(made.state.recent, [1, 3, 2]);
  send(made, { t: 'show', n: 2, all: true, cmd: 'v8' });
  assert.equal(send(made, { t: 'undo' })[0].what, 'Undone: back to Launch and Pricing side by side');
  assert.equal(send(made, { t: 'undo' })[0].what, 'Undone: back to Hiring');
  assert.deepEqual([made.state.current, made.view()], [3, { mode: 'one' }]);
  // Undoing a board two side by side showed takes the pair away with it: one board is left on screen.
  send(made, { t: 'show', n: 2, split: [2, 3], cmd: 'v7' });
  send(made, { t: 'undo' }, { t: 'undo' });
  assert.deepEqual([made.state.boards.length, made.state.current, made.view()], [2, 2, { mode: 'one' }]);
});

test('a step kept from before views undoes to one board, and a pair that names a board the call lost is one board', async () => {
  const storage = new Storage();
  const board = (title) => ({ v: 2, title, blocks: [] });
  await storage.put('state', { opened: true, expires: LATER, seq: 3, current: 2, last: 2, boards: [board('A'), board('B')],
    view: { mode: 'split', boards: [2, 5] }, history: [{ key: 'k', count: 2, current: 1, last: 1, boards: {}, what: 'Showed B' }] });
  const { made } = await room(storage);
  assert.deepEqual(made.view(), { mode: 'one' });
  assert.deepEqual(made.snapshot().recent, []);
  send(made, { t: 'undo' });
  assert.deepEqual([made.state.current, made.view()], [1, { mode: 'one' }]);
});

test('the recap opens alone, whatever was on screen', async () => {
  const { made } = await room();
  send(made, { t: 'new' }, { t: 'op', n: 1, op: { op: 'block', id: 'a', type: 'list', title: 'Action items' } },
    { t: 'op', n: 1, op: { op: 'item', id: 'h', block: 'a', text: 'Hire a designer' } }, { t: 'new' },
    { t: 'show', n: 1, split: [1, 2] });
  send(made, { t: 'recap' });
  assert.deepEqual([made.state.current, made.view()], [3, { mode: 'one' }]);
});

test("a finished command's words are kept with the room, for the change log and its undo step", async () => {
  const storage = new Storage();
  const { made } = await room(storage);
  send(made, { t: 'new', cmd: 'c1' }, { t: 'op', n: 1, op: { op: 'title', text: 'Plan' }, cmd: 'c1' },
    { t: 'caption', state: 'done', detail: 'Named the board “Plan”', cmd: 'c1' });
  await new Promise((resolve) => setTimeout(resolve, 0));
  const kept = await storage.get('state');
  assert.equal(kept.log.at(-1).what, 'Named the board “Plan”');
  assert.equal(kept.history.at(-1).what, 'Named the board “Plan”');
});

test('a custom picture fills in without an undo step of its own: undo after it keeps the picture, undo of its ask takes it away', async () => {
  const { made, page } = await room();
  const svg = '<svg viewBox="0 0 1000 520"><rect x="1" y="1" width="100" height="50" fill="#ffffff"/><text x="9" y="30">API</text></svg>';
  send(made, { t: 'new', cmd: 'v1' }, { t: 'op', n: 1, op: { op: 'block', id: 'goals', type: 'list', title: 'Goals' }, cmd: 'v1' },
    { t: 'op', n: 1, op: { op: 'block', id: 'arch', type: 'sketch', title: 'Stripe', brief: 'App to API to Stripe', drawing: 'd1' }, cmd: 'v2' },
    { t: 'caption', state: 'done', detail: 'Added the picture “Stripe”', cmd: 'v2' },
    { t: 'op', n: 1, op: { op: 'item', id: 'g1', block: 'goals', text: 'Ship it' }, cmd: 'v3' });
  const [partial] = send(made, { t: 'op', n: 1, op: { op: 'sketch', id: 'arch', drawing: 'd1', svg: svg.slice(0, 80) }, cmd: 'v2' });
  assert.deepEqual(partial, { ok: true, changed: [], what: 'Drawing “Stripe”' });
  const [whole] = send(made, { t: 'op', n: 1, op: { op: 'sketch', id: 'arch', drawing: 'd1', svg, done: true }, cmd: 'v2' });
  assert.equal(whole.what, 'Drew “Stripe”');
  const shown = page.filter((m) => m.t === 'board').at(-1);
  assert.equal(shown.sketch, true);
  assert.match(shown.board.blocks[1].svg, /API/);
  assert.equal(made.state.history.length, 3, 'the picture made no undo step');
  // Undoing the goal (asked after the picture) leaves the picture whole, not its placeholder.
  send(made, { t: 'undo' });
  const kept = made.state.boards[0].blocks.find((b) => b.id === 'arch');
  assert.deepEqual([kept.drawing, /API/.test(kept.svg), made.state.boards[0].blocks[0].items.length], [undefined, true, 0]);
  // Undoing the ask takes the picture away, and a drawing still on its way is refused.
  send(made, { t: 'undo' });
  assert.equal(made.state.boards[0].blocks.some((b) => b.id === 'arch'), false);
  assert.match(send(made, { t: 'op', n: 1, op: { op: 'sketch', id: 'arch', drawing: 'd1', svg } })[0].error, /no picture arch/);
});

test('only Hermes draws custom pictures: someone on the link cannot make, fill or mark one', async () => {
  const { made } = await room();
  send(made, { t: 'new' }, { t: 'op', n: 1, op: { op: 'block', id: 'arch', type: 'sketch', title: 'Stripe', brief: 'x', drawing: 'd1' } });
  const lee = person(made);
  const svg = '<svg viewBox="0 0 10 10"><rect width="5" height="5"/></svg>';
  lee.say({ t: 'op', n: 1, op: { op: 'block', id: 'new', type: 'sketch', title: 'Mine' }, ref: 'r1' });
  lee.say({ t: 'op', n: 1, op: { op: 'sketch', id: 'arch', drawing: 'd1', svg }, ref: 'r2' });
  lee.say({ t: 'op', n: 1, op: { op: 'block', id: 'arch', drawing: 'd2' }, ref: 'r3' });
  lee.say({ t: 'op', n: 1, op: { op: 'block', id: 'big', type: 'SKETCH', title: 'Mine' }, ref: 'r5' });
  lee.say({ t: 'op', n: 1, op: { op: 'block', id: 'arr', type: ['Sketch'], title: 'Mine' }, ref: 'r6' });
  lee.say({ t: 'op', n: 1, op: { op: 'block', id: 'arch', brief: 'Draw something else' }, ref: 'r7' });
  assert.deepEqual(lee.got.filter((m) => m.t === 'refused').map((m) => m.ref), ['r1', 'r2', 'r3', 'r5', 'r6', 'r7']);
  assert.ok(lee.got.filter((m) => m.t === 'refused').every((m) => m.error === 'only Hermes draws custom pictures'));
  assert.equal(made.state.boards[0].blocks.length, 1);
  // Renaming it is fine.
  lee.say({ t: 'op', n: 1, op: { op: 'block', id: 'arch', title: 'Payments' }, ref: 'r4' });
  assert.equal(made.state.boards[0].blocks[0].title, 'Payments');
});

test('a block Hermes sends again just as it is changes nothing: no board sent, no ring, and no undo step', async () => {
  const { made, page } = await room();
  send(made, { t: 'new', cmd: 'v1' }, { t: 'op', n: 1, op: { op: 'block', id: 'k', type: 'stats', title: 'Key numbers' }, cmd: 'v1' },
    { t: 'op', n: 1, op: { op: 'item', id: 'r', block: 'k', text: 'Revenue', value: '$4.2M' }, cmd: 'v1' });
  const boards = page.filter((m) => m.t === 'board').length;
  const [again] = send(made, { t: 'op', n: 1, op: { op: 'block', id: 'k', type: 'stats', title: 'Key numbers' }, cmd: 'v2' });
  assert.deepEqual(again, { ok: true, changed: [], what: '', same: true });
  assert.equal(page.filter((m) => m.t === 'board').length, boards);
  // Undo still undoes the command that made the block, not the one that sent it again.
  send(made, { t: 'undo', cmd: 'v3' });
  assert.equal(made.state.boards.length, 0);
});
