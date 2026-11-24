// The Worker's public routes (src/index.js) without Cloudflare: a link this Worker did not sign is refused before any
// board room is reached, and the API opens a call's room before its bot starts. Run: node --test bot/test/
import test from 'node:test';
import assert from 'node:assert/strict';
import { register } from 'node:module';

register(`data:text/javascript,${encodeURIComponent(`
export async function resolve(specifier, context, next) {
  const stubs = {
    'cloudflare:workers': 'export class DurableObject { constructor(ctx, env) { this.ctx = ctx; this.env = env; } }',
    '@cloudflare/containers': 'export class Container { constructor(ctx, env) { this.ctx = ctx; this.env = env; } } export const getContainer = (ns, id) => ns.get(id);',
  };
  if (!(specifier in stubs)) return next(specifier, context);
  return { shortCircuit: true, url: 'data:text/javascript,' + encodeURIComponent(stubs[specifier]) };
}`)}`);
const { default: worker, MeetBot } = await import('../src/index.js');
const { address, botKey, sign, verify } = await import('../src/links.js');

// Node's Response refuses status 101, which the Worker answers a bot's upgrade with.
const NodeResponse = globalThis.Response;
globalThis.Response = class extends NodeResponse {
  constructor(body, init = {}) {
    super(body, init.status === 101 ? { ...init, status: 200 } : init);
    if (init.status === 101) Object.defineProperty(this, 'status', { value: 101 });
  }

  static json(...args) {
    return NodeResponse.json(...args);
  }
};

const SECRET = 'test-api-token';
const TOKEN = 'ab'.repeat(16);

// Every board room the Worker reaches, and what it asked each. `answers` gives a room path's answer as JSON.
function rig(answers = {}) {
  const reached = [];
  const started = [];
  const kept = [];
  const env = {
    API_TOKEN: SECRET,
    ASSETS: { fetch: async () => new Response('<html></html>', { headers: { 'content-type': 'text/html' } }) },
    BOARD_ROOM: {
      idFromName: (name) => { reached.push({ name }); return name; },
      get: (name) => ({ fetch: async (request) => {
        reached.at(-1).path = new URL(request.url).pathname;
        reached.at(-1).role = request.headers.get('x-room-role');
        reached.at(-1).client = request.headers.get('x-room-client');
        reached.at(-1).link = request.headers.get('x-room-link');
        reached.at(-1).body = request.method === 'POST' ? await request.text() : null;
        const answer = answers[new URL(request.url).pathname];
        if (answer) return Response.json(answer.body, { status: answer.status || 200 });
        return new Response(request.headers.get('upgrade') ? null : '{"ok":true}', { status: request.headers.get('upgrade') ? 101 : 200 });
      } }),
    },
    MEET_BOT: { get: () => ({ fetch: async (request) => { started.push(JSON.parse(await request.text())); return new Response('{}'); },
      keepRoom: async (token) => { kept.push(token); } }) },
  };
  const get = (path, headers = {}) => worker.fetch(new Request(`https://bots.example${path}`, { headers }), env);
  return { env, reached, started, kept, get };
}

const upgrade = { upgrade: 'websocket', 'cf-connecting-ip': '2001:db8:1:2:3:4:5:6' };
const later = () => Math.floor(Date.now() / 1000) + 3600;

test('an invented, altered or expired link is refused without reaching any board room', async () => {
  const { reached, get } = rig();
  const real = await sign(SECRET, { token: TOKEN, scope: 'e', version: 1, expires: later() });
  const invented = [
    `/b/${TOKEN}/ws`,
    `/b/${'cd'.repeat(16)}e0001${later().toString(16)}${'0'.repeat(32)}/ws`,
    `/b/${real.slice(0, -1)}${real.at(-1) === '0' ? '1' : '0'}/ws`,
    `/b/${real.replace(/^(.{32})e/, '$1c')}/ws`,
    `/b/${await sign('another-secret', { token: TOKEN, scope: 'e', version: 1, expires: later() })}/ws`,
    `/b/${await sign(SECRET, { token: TOKEN, scope: 'e', version: 1, expires: Math.floor(Date.now() / 1000) - 1 })}/ws`,
    `/b/${TOKEN}/bot/${'0'.repeat(64)}`,
    `/b/${TOKEN}/bot`,
    `/b/${TOKEN}`,
    `/b/${real}`,
  ];
  for (const path of invented) assert.equal((await get(path, upgrade)).status, 404, path);
  assert.deepEqual(reached, [], 'no room was named, so none was made');
});

test("a signed link reaches its room with the link's role, version and the person's address", async () => {
  const { reached, get } = rig();
  const edit = await sign(SECRET, { token: TOKEN, scope: 'e', version: 3, expires: later() });
  const watch = await sign(SECRET, { token: TOKEN, scope: 'a', version: 3, expires: later() });
  assert.equal((await get(`/b/${edit}/ws`, upgrade)).status, 101);
  assert.equal((await get(`/b/${watch}/ws`, { ...upgrade, 'cf-connecting-ip': '203.0.113.9' })).status, 101);
  assert.deepEqual(reached.map(({ name, path, role, client, link }) => [name, path, role, client, link]), [
    [TOKEN, '/socket', 'editor', '2001:db8:1:2', '3'],
    [TOKEN, '/socket', 'watcher', '203.0.113.9', '3'],
  ]);
  assert.equal((await get(`/b/${TOKEN}/bot/${await botKey(SECRET, TOKEN)}`, { ...upgrade, 'sec-websocket-protocol': 'hermes-bot' })).status, 101);
  assert.equal(reached.at(-1).role, 'bot');
  // The page itself is the same for every call: its link's key stays after the #.
  const page = await get('/b/');
  assert.equal(page.status, 200);
  assert.match(page.headers.get('content-security-policy'), /default-src 'none'/);
});

test("the API opens a call's room before its bot starts, and gives the bot only that room's links", async () => {
  const { reached, started, kept, env } = rig();
  const answer = await worker.fetch(new Request('https://bots.example/bots', { method: 'POST',
    headers: { authorization: `Bearer ${SECRET}` }, body: JSON.stringify({ meeting_url: 'https://meet.google.com/abc-defg-hij' }) }), env);
  assert.equal(answer.status, 201);
  const made = await answer.json();
  assert.match(made.board_token, /^[0-9a-f]{32}$/);
  assert.equal(reached[0].path, '/open');
  assert.equal(reached[0].name, made.board_token);
  assert.ok(JSON.parse(reached[0].body).expires > Date.now() / 1000 + 11 * 3600);
  const [, editKey] = made.board_url.match(/^https:\/\/bots\.example\/b\/#([0-9a-f]{77})$/);
  const board = started[0].board;
  const [, screenKey] = board.page.match(/^https:\/\/bots\.example\/b\/\?screen=1#([0-9a-f]{77})$/);
  assert.equal(editKey[32], 'e');
  assert.equal(screenKey[32], 'c');
  assert.equal(board.socket, `wss://bots.example/b/${made.board_token}/bot/${await botKey(SECRET, made.board_token)}`);
  assert.ok(!JSON.stringify(started[0]).includes(SECRET), 'the bot never gets the API key');
  assert.deepEqual(kept, [made.board_token], 'the bot knows its room, to turn its link off when it stops');
  const refused = await worker.fetch(new Request('https://bots.example/bots', { method: 'POST', body: '{}' }), env);
  assert.equal(refused.status, 401);
});

test('an IPv6 address counts as its /64 however it is written, so shortening it gives no fresh limits', () => {
  for (const written of ['2001:db8::1', '2001:0db8:0:0::2', '2001:DB8:0:0:ffff:1:2:3', '2001:db8:0::']) {
    assert.equal(address(written), '2001:db8:0:0', written);
  }
  assert.equal(address('2001:db8:1:2:3:4:5:6'), '2001:db8:1:2');
  assert.equal(address('::1'), '0:0:0:0');
  assert.equal(address('::ffff:203.0.113.9'), '203.0.113.9');
  assert.equal(address('203.0.113.9'), '203.0.113.9');
});

test("the API hands the bot the call's notice, and refuses one the chat could not take", async () => {
  const { started, env } = rig();
  const start = (body) => worker.fetch(new Request('https://bots.example/bots', { method: 'POST',
    headers: { authorization: `Bearer ${SECRET}` }, body: JSON.stringify({ meeting_url: 'https://meet.google.com/abc-defg-hij', ...body }) }), env);
  assert.equal((await start({ notice: "Hi, I'm Sam's AI notetaker." })).status, 201);
  assert.equal(started[0].notice, "Hi, I'm Sam's AI notetaker.");
  assert.equal((await start({})).status, 201);
  assert.equal('notice' in started[1], false, 'without one the bot posts its own neutral notice');
  assert.equal((await start({ notice: 'x'.repeat(501) })).status, 400);
  assert.equal((await start({ notice: 7 })).status, 400);
  assert.equal(started.length, 2, 'a refused start starts no bot');
});

test("the bot's Google account and Deepgram key go only in its start request, never in its container's environment", async () => {
  const { started, env } = rig();
  Object.assign(env, { GOOGLE_EMAIL: 'bot@example.com', GOOGLE_PASSWORD: 'pw-for-the-test', DEEPGRAM_API_KEY: 'dg-for-the-test' });
  const answer = await worker.fetch(new Request('https://bots.example/bots', { method: 'POST',
    headers: { authorization: `Bearer ${SECRET}` }, body: JSON.stringify({ meeting_url: 'https://meet.google.com/abc-defg-hij' }) }), env);
  assert.equal(answer.status, 201);
  assert.deepEqual(started[0].secrets,
    { google_email: 'bot@example.com', google_password: 'pw-for-the-test', deepgram_api_key: 'dg-for-the-test' });
  const box = new MeetBot({}, env);
  assert.ok(!JSON.stringify(box.envVars ?? {}).includes('for-the-test'), 'no secret in the container environment');
  const bare = rig();
  await worker.fetch(new Request('https://bots.example/bots', { method: 'POST',
    headers: { authorization: `Bearer ${SECRET}` }, body: JSON.stringify({ meeting_url: 'https://meet.google.com/abc-defg-hij' }) }), bare.env);
  assert.deepEqual(bare.started[0].secrets, {}, 'a copy with no account or key sends none');
});

test("Hermes turns a call's board link off, makes a new one, or gets a watch-only one, each for the room's version", async () => {
  const expires = later();
  const { reached, env } = rig({ '/link': { body: { version: 3, expires } },
    '/short': { body: { version: 3, expires, ended: false, short: null } } });
  const link = (body, headers = { authorization: `Bearer ${SECRET}` }) => worker.fetch(new Request(
    `https://bots.example/rooms/${TOKEN}/link`, { method: 'POST', headers, body: JSON.stringify(body) }), env);
  assert.deepEqual(await (await link({ mode: 'off' })).json(), { ok: true, board_url: null });
  assert.deepEqual(reached.at(-1), { name: TOKEN, path: '/link', role: 'hermes', client: null, link: null, body: '' });
  const made = await (await link({ mode: 'new' })).json();
  const editor = made.board_url.match(/^https:\/\/bots\.example\/b\/#([0-9a-f]{77})$/)[1];
  assert.deepEqual(await verify(SECRET, editor), { token: TOKEN, role: 'editor', version: 3, expires });
  assert.equal(reached.at(-1).path, '/link', 'a new link moves the version on too');
  const watch = (await (await link({ mode: 'view' })).json()).view_url.match(/#([0-9a-f]{77})$/)[1];
  assert.deepEqual(await verify(SECRET, watch), { token: TOKEN, role: 'watcher', version: 3, expires });
  assert.equal(reached.at(-1).path, '/short', 'a watch-only link leaves the version as it is');
  const count = reached.length;
  assert.equal((await link({ mode: 'everyone' })).status, 400);
  assert.equal((await link({ mode: 'off' }, {})).status, 401);
  assert.equal(reached.length, count, 'a refused request reaches no room');
  const over = rig({ '/link': { status: 409, body: { error: 'the call is over' } },
    '/short': { body: { version: 3, expires, ended: true, short: null } } });
  for (const mode of ['new', 'view']) {
    const answer = await worker.fetch(new Request(`https://bots.example/rooms/${TOKEN}/link`, { method: 'POST',
      headers: { authorization: `Bearer ${SECRET}` }, body: JSON.stringify({ mode }) }), over.env);
    assert.equal(answer.status, 409, mode);
  }
});

test("a bot that stops for any reason turns its call's board link off, once", async () => {
  const answers = { '/link': { status: 503, body: { error: 'the room is restarting' } } };
  const { reached, env } = rig(answers);
  const storage = new Map();
  const ctx = { storage: { get: async (k) => storage.get(k), put: async (k, v) => { storage.set(k, v); },
    delete: async (k) => storage.delete(k) } };
  const bot = new MeetBot(ctx, env);
  bot.linkWaits = [0, 0];
  await bot.onStop();
  assert.deepEqual(reached, [], 'a bot with no room reaches none');
  await bot.keepRoom(TOKEN);
  await bot.onStop();
  assert.equal(reached.length, 3, 'a room that does not answer is asked three times');
  assert.equal(storage.get('room'), TOKEN, 'and again on the next stop');
  answers['/link'] = { body: { version: 2, expires: later() } };
  await bot.onStop();
  assert.deepEqual(reached.map((r) => [r.name, r.path, r.role]).at(-1), [TOKEN, '/link', 'hermes']);
  assert.equal(reached.length, 4);
  await bot.onStop();
  assert.equal(reached.length, 4, 'once the link is off, never again');
});
