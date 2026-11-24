// The short link on the shared screen (src/short.js, the codes in src/links.js, and /j/<code> in src/index.js) without
// Cloudflare: stand-ins for the Durable Object base classes and their storage. Run: node --test bot/test/
import test from 'node:test';
import assert from 'node:assert/strict';
import { register } from 'node:module';

register(`data:text/javascript,${encodeURIComponent(`
const stubs = {
  'cloudflare:workers': 'export class DurableObject { constructor(ctx, env) { this.ctx = ctx; this.env = env; } }',
  '@cloudflare/containers': 'export class Container { constructor(ctx, env) {} } export const getContainer = (ns, id) => ns.get(id);',
};
export async function resolve(specifier, context, next) {
  if (!(specifier in stubs)) return next(specifier, context);
  return { shortCircuit: true, url: 'data:text/javascript,' + encodeURIComponent(stubs[specifier]) };
}`)}`);
const { ShortLink } = await import('../src/short.js');
const { checkShort, newShort, verify } = await import('../src/links.js');
const { default: worker } = await import('../src/index.js');

const SECRET = 'test-api-token';
const TOKEN = 'ab'.repeat(16);
const LATER = Math.floor(Date.now() / 1000) + 3600;

class Storage {
  constructor() { this.data = new Map(); this.alarm = null; }
  async get(key) { return this.data.get(key); }
  async put(key, value) { this.data.set(key, value); }
  async deleteAll() { this.data.clear(); }
  async setAlarm(at) { this.alarm = at; }
}

// SHORT_LINKS as the Worker sees it: one ShortLink object per name, and which names were asked for.
function namespace() {
  const objects = new Map();
  const asked = [];
  return {
    objects, asked,
    idFromName: (name) => { asked.push(name); return name; },
    get: (name) => {
      if (!objects.has(name)) objects.set(name, new ShortLink({ storage: new Storage() }, {}));
      const object = objects.get(name);
      return { fetch: (url, init) => object.fetch(new Request(url, init)) };
    },
  };
}

const put = (links, code, token) => links.get(code).fetch('https://short/', { method: 'PUT', body: JSON.stringify({ token }) });

test('a short link holds one board token, refuses another, and forgets it after a day and a half', async () => {
  const links = namespace();
  assert.equal((await put(links, 'abcdefghjk', TOKEN)).status, 200);
  assert.equal((await put(links, 'abcdefghjk', TOKEN)).status, 200, 'the same room may ask again');
  assert.equal((await put(links, 'abcdefghjk', 'cd'.repeat(16))).status, 409);
  assert.equal((await put(links, 'mnpqrstuvw', 'not a token')).status, 400);
  const object = links.objects.get('abcdefghjk');
  assert.ok(object.ctx.storage.alarm - Date.now() > 35 * 3600 * 1000);
  await object.alarm();
  assert.equal((await (await links.get('abcdefghjk').fetch('https://short/')).json()).token, null);
});

test('a short code is signed: typed with or without its dash it checks, and a changed one does not', async () => {
  const code = await newShort(SECRET);
  assert.match(code, /^[a-hj-km-np-z2-9]{10}$/);
  assert.equal(await checkShort(SECRET, `${code.slice(0, 5)}-${code.slice(5).toUpperCase()}`), code);
  const changed = code.slice(0, 9) + (code[9] === 'a' ? 'b' : 'a');
  assert.equal(await checkShort(SECRET, changed), null);
  assert.equal(await checkShort('another-secret', code), null);
  assert.equal(await checkShort(SECRET, 'abc'), null);
});

// The Worker with a room that says what its links carry now.
function rig(info) {
  const reached = [];
  const env = {
    API_TOKEN: SECRET,
    SHORT_LINKS: namespace(),
    BOARD_ROOM: { idFromName: (name) => name, get: (name) => ({ fetch: async (request) => {
      reached.push([name, new URL(request.url).pathname, request.headers.get('x-room-role')]);
      return Response.json(info);
    } }) },
  };
  return { env, reached, get: (path) => worker.fetch(new Request(`https://bots.example${path}`), env) };
}

test('/j/<code> leads to an editor link signed now, and a made-up code reaches no Durable Object', async () => {
  const code = await newShort(SECRET);
  const { env, reached, get } = rig({ version: 2, expires: LATER, ended: false, short: code });
  await put(env.SHORT_LINKS, code, TOKEN);
  env.SHORT_LINKS.asked.length = 0;
  const answer = await get(`/j/${code.slice(0, 5)}-${code.slice(5)}`);
  assert.equal(answer.status, 302);
  assert.equal(answer.headers.get('cache-control'), 'no-store');
  const key = answer.headers.get('location').replace('/b/#', '');
  assert.deepEqual(await verify(SECRET, key), { token: TOKEN, role: 'editor', version: 2, expires: LATER });
  assert.deepEqual(reached, [[TOKEN, '/short', 'hermes']]);
  reached.length = 0;
  env.SHORT_LINKS.asked.length = 0;
  const madeUp = await get(`/j/${code.slice(0, 9)}${code[9] === 'a' ? 'b' : 'a'}`);
  assert.equal(madeUp.status, 404);
  assert.match(await madeUp.text(), /ended or is not right/);
  assert.deepEqual([reached, env.SHORT_LINKS.asked], [[], []], 'turned away by its HMAC');
});

test('/j/<code> ends with its call, and with the link it was made for', async () => {
  const code = await newShort(SECRET);
  for (const info of [{ version: 1, expires: LATER, ended: true, short: null }, { version: 3, expires: LATER, ended: false, short: null },
    { version: 1, expires: Math.floor(Date.now() / 1000) - 1, ended: false, short: code }]) {
    const { env, get } = rig(info);
    await put(env.SHORT_LINKS, code, TOKEN);
    assert.equal((await get(`/j/${code}`)).status, 404, JSON.stringify(info));
  }
});
