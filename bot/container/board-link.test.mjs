// The bot's line to its call's board room: what it hears goes out at once, commands are never lost to a dropped line,
// and the room's word on which board is on screen comes back. Run with `node --test`.
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { BoardLink } from './board-link.mjs';

class FakeSocket {
  constructor(url, protocols) {
    Object.assign(this, { url, protocols, readyState: 0, sent: [] });
  }

  send(data) {
    this.sent.push(JSON.parse(data));
  }

  close() {
    this.readyState = 3;
  }

  open() {
    this.readyState = 1;
    this.onopen?.();
  }

  drop() {
    this.readyState = 3;
    this.onclose?.({ code: 1006 });
  }

  hear(msg) {
    this.onmessage?.({ data: typeof msg === 'string' ? msg : JSON.stringify(msg) });
  }
}

function rig(options = {}) {
  const sockets = [], waits = [], rooms = [];
  const link = new BoardLink({ ...options, socket: 'wss://bots.test/b/abc/bot/room-key', log: () => {},
    onRoom: (room) => rooms.push(room), connect: (url, protocols) => sockets.at(sockets.push(new FakeSocket(url, protocols)) - 1),
    later: (work, ms) => waits.push([work, ms]) });
  return { link, sockets, waits, rooms };
}

test('the key goes only in the path, never a header, and what is sent before the line opens waits for it', () => {
  const { link, sockets } = rig();
  link.connect();
  assert.deepEqual([sockets[0].url, sockets[0].protocols], ['wss://bots.test/b/abc/bot/room-key', ['hermes-bot']]);
  link.send({ t: 'hearing', id: 'v1', text: 'add the' });
  link.send({ t: 'command', id: 'v1', text: 'add the press kit' });
  assert.deepEqual(sockets[0].sent, []);
  sockets[0].open();
  // A stale caption is not worth showing late; the command is.
  assert.deepEqual(sockets[0].sent, [{ t: 'command', id: 'v1', text: 'add the press kit' }]);
  link.send({ t: 'hearing', id: 'v2', text: 'stop' });
  assert.equal(sockets[0].sent.at(-1).t, 'hearing');
});

test('a dropped line opens again after growing waits, and commands said meanwhile arrive', () => {
  const { link, sockets, waits } = rig();
  link.connect();
  sockets[0].open();
  sockets[0].drop();
  assert.deepEqual(waits.map(([, ms]) => ms), [500]);
  link.send({ t: 'command', id: 'v3', text: 'stop sharing' });
  assert.equal(sockets.length, 2, 'sending opens the line at once');
  sockets[1].drop();
  waits.shift()[0]();
  assert.equal(sockets.length, 3);
  sockets[2].drop();
  assert.deepEqual(waits.map(([, ms]) => ms), [1000, 2000]);
  waits.shift()[0]();
  sockets[3].open();
  assert.deepEqual(sockets[3].sent, [{ t: 'command', id: 'v3', text: 'stop sharing' }]);
  sockets[3].drop();
  assert.equal(waits.at(-1)[1], 500, 'an open line starts the waits over');
});

test('a command goes again on every new line until the room says it has it', () => {
  const { link, sockets, waits } = rig();
  link.connect();
  sockets[0].open();
  link.send({ t: 'command', id: 'v1', text: 'add the press kit' });
  assert.equal(link.pending(), 1);
  // The line drops with the command on its way: nothing says the room got it.
  sockets[0].drop();
  waits.shift()[0]();
  sockets[1].open();
  assert.deepEqual(sockets[1].sent, [{ t: 'command', id: 'v1', text: 'add the press kit' }]);
  sockets[1].hear({ t: 'got', id: 'v1' });
  assert.equal(link.pending(), 0);
  sockets[1].drop();
  waits.shift()[0]();
  sockets[2].open();
  assert.deepEqual(sockets[2].sent, []);
});

test('at most 50 commands wait for the room; past that the oldest is given up, and said so', () => {
  const logged = [];
  const sockets = [];
  const link = new BoardLink({ socket: 'wss://bots.test/b/abc/bot/k', log: (...words) => logged.push(words.join(' ')),
    connect: (url) => sockets.at(sockets.push(new FakeSocket(url)) - 1), later: () => {} });
  for (let i = 1; i <= 51; i++) link.send({ t: 'command', id: `v${i}`, text: `command ${i}` });
  assert.equal(link.pending(), 50);
  assert.deepEqual(logged, ['board link: gave up on command v1']);
  sockets[0].open();
  assert.deepEqual(sockets[0].sent.map((m) => m.id), Array.from({ length: 50 }, (_, i) => `v${i + 2}`));
});

test('the room says which board is on screen', () => {
  const { link, sockets, rooms } = rig();
  link.connect();
  sockets[0].open();
  sockets[0].hear({ t: 'hello', current: null, boards: [] });
  sockets[0].hear('not json');
  sockets[0].hear({ t: 'caption', state: 'drawing' });
  sockets[0].hear({ t: 'board', n: 1, current: 1 });
  sockets[0].hear({ t: 'current', n: null });
  sockets[0].hear({ t: 'current', n: 1 });
  sockets[0].hear({ t: 'ended' });
  assert.deepEqual(rooms, [{ current: null, boards: 0 }, { current: 1, boards: 1 }, { current: null, boards: 1 },
    { current: 1, boards: 1 }, { current: null, boards: 1 }]);
});

test('a closed link sends nothing and never opens again', () => {
  const { link, sockets, waits } = rig();
  link.connect();
  sockets[0].open();
  link.close();
  link.send({ t: 'command', id: 'v1', text: 'x' });
  sockets[0].drop();
  link.connect();
  assert.deepEqual([sockets.length, waits.length, sockets[0].sent], [1, 0, []]);
});

test('an undo that brings a board back on screen reaches the bot, so it shares it again', () => {
  const { link, sockets, rooms } = rig();
  link.connect();
  sockets[0].open();
  sockets[0].hear({ t: 'hello', boards: [{}], current: null });
  sockets[0].hear({ t: 'undone', boards: [{}, {}], current: 2 });
  assert.deepEqual(rooms.at(-1), { current: 2, boards: 2 });
});

test('as the bot leaves it asks the room for the recap and waits a moment for it', async () => {
  const { link, sockets, waits } = rig();
  assert.equal(await link.recap(), null, 'no board, nothing to recap');
  link.connect();
  sockets[0].open();
  sockets[0].hear({ t: 'hello', boards: [{}], current: 1 });
  const asked = link.recap();
  assert.deepEqual(sockets[0].sent.at(-1), { t: 'recap' });
  sockets[0].hear({ t: 'recapped', ok: true, n: 2, text: 'Recap.' });
  assert.deepEqual(await asked, { t: 'recapped', ok: true, n: 2, text: 'Recap.' });
  // No answer in time: it gives up and the bot leaves all the same.
  const late = link.recap(3000);
  const [work, ms] = waits.at(-1);
  assert.equal(ms, 3000);
  work();
  assert.equal(await late, null);
});

test('how the bot is now (whether it can hear) goes on every new line, and is never held as old news', () => {
  let on = true;
  const { link, sockets } = rig({ current: () => [{ t: 'listening', on }] });
  link.connect();
  sockets[0].open();
  assert.deepEqual(sockets[0].sent, [{ t: 'listening', on: true }]);
  sockets[0].drop();
  on = false;
  link.send({ t: 'listening', on: false });
  sockets[1].open();
  assert.deepEqual(sockets[1].sent, [{ t: 'listening', on: false }]);
});
