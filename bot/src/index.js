import { Container, getContainer } from '@cloudflare/containers';
import { address, botKey, checkShort, hex, same, sign, TOKEN, verify } from './links.js';

export { BoardRoom } from './room.js';
export { ShortLink } from './short.js';

// One Chrome per meeting. Each bot is its own container, named by the id this Worker hands out.
export class MeetBot extends Container {
  defaultPort = 8080;
  // Activity is any request; the mini polls status every minute while a call runs.
  sleepAfter = '20m';

  // The call's board room, so that a bot that stops for any reason (removed, done, or its Chrome gone) turns the
  // board link off, even when the mini never says the call is over.
  async keepRoom(token) {
    await this.ctx.storage.put('room', token);
  }

  // A room that does not answer is asked again, after each wait in `linkWaits`; the token is kept until the room has
  // the link off (or the call is over), so a later stop asks again too.
  linkWaits = [1000, 4000];

  async onStop() {
    const token = await this.ctx.storage.get('room');
    if (!token) return;
    for (const wait of [0, ...this.linkWaits]) {
      if (wait) await new Promise((done) => setTimeout(done, wait));
      const answer = await roomRequest(this.env, token, '/link', 'hermes', { method: 'POST' }).catch(() => null);
      if (answer?.ok || answer?.status === 409) return this.ctx.storage.delete('room');
    }
  }

  // The mini's polls count as activity, but a bot still in its call stays up even when the mini goes quiet.
  async onActivityExpired() {
    const status = await this.containerFetch('http://bot/status').then((r) => r.json()).catch(() => null);
    if (['signing_in', 'joining', 'waiting_room', 'in_call'].includes(status?.state)) return this.renewActivityTimeout();
    await this.stop();
  }

  async end() {
    await this.destroy();
  }
}

const json = (value, status = 200) =>
  new Response(JSON.stringify(value), { status, headers: { 'content-type': 'application/json' } });

// The calls a bot can join: Google Meet, and Zoom on zoom.us or a company subdomain of it.
const JOINABLE = [/^https:\/\/meet\.google\.com\/[a-z]{3}-[a-z]{4}-[a-z]{3}/,
  /^https:\/\/([a-z0-9-]+\.)*zoom\.us\/[jw]\/\d{9,12}/i];

// Requests the Worker passes to a bot's container, by method and path after /bots/<id>.
const PASS = new Set(['GET /status', 'POST /chat', 'POST /leave', 'GET /audio', 'GET /debug/shot', 'GET /board/export',
  'GET /board/final']);

// What the mini may ask of a call's board room.
const ROOM = new Set(['GET events', 'POST send', 'GET state', 'POST close']);
// The board page's own code, served to anyone (it holds no data).
const PAGE_FILES = new Set(['board.mjs', 'model.mjs', 'kinds.mjs', 'view.mjs', 'views.mjs', 'arrange.mjs', 'sizes.mjs',
  'blocks.mjs', 'blocks.css', 'scene.mjs', 'canvas.mjs', 'env.js']);
const VENDOR = 'https://cdn.jsdelivr.net';
// A call's board links stop working this long after the call's bot started, when its room empties itself too.
const ROOM_SECONDS = 12 * 3600;
// Meet's chat takes 500 characters.
const NOTICE_CHARS = 500;

const authorized = (request, env) => Boolean(env.API_TOKEN)
  && same(request.headers.get('authorization') || '', `Bearer ${env.API_TOKEN}`);

const room = (env, token) => env.BOARD_ROOM.get(env.BOARD_ROOM.idFromName(token));

function roomRequest(env, token, path, role, init = {}) {
  return room(env, token).fetch(new Request(`https://room${path}`,
    { ...init, headers: { ...init.headers, 'x-room-role': role, 'x-room-token': token } }));
}

// /j/<code>: the short link on the shared screen. A code this Worker did not make is refused by its HMAC before any
// Durable Object is reached; a real one leads to an editor's link to its room, signed now for the room's current link
// version, so a link turned off ends its short link too.
async function shortLink(env, given) {
  const headers = { 'cache-control': 'no-store', 'referrer-policy': 'no-referrer', 'x-robots-tag': 'noindex' };
  const gone = () => new Response('This board link has ended or is not right.',
    { status: 404, headers: { ...headers, 'content-type': 'text/plain; charset=utf-8' } });
  const code = await checkShort(env.API_TOKEN, given);
  if (!code || !env.SHORT_LINKS) return gone();
  const { token } = await env.SHORT_LINKS.get(env.SHORT_LINKS.idFromName(code)).fetch('https://short/')
    .then((r) => r.json()).catch(() => ({}));
  if (!TOKEN.test(token || '')) return gone();
  const info = await roomRequest(env, token, '/short', 'hermes').then((r) => (r.ok ? r.json() : null)).catch(() => null);
  if (!info || info.ended || info.short !== code || info.expires * 1000 <= Date.now()) return gone();
  const key = await sign(env.API_TOKEN, { token, scope: 'e', version: info.version, expires: info.expires });
  return new Response(null, { status: 302, headers: { ...headers, location: `/b/#${key}` } });
}

// The board page: anyone with the link may watch; scripts only from here and the pinned libraries on jsDelivr.
async function page(request, env) {
  const asset = await env.ASSETS.fetch(new Request(new URL('/board/index.html', request.url)));
  const headers = new Headers(asset.headers);
  const host = new URL(request.url).host;
  headers.set('content-security-policy', [`default-src 'none'`, `script-src 'self' ${VENDOR}`,
    `style-src 'self' 'unsafe-inline' ${VENDOR}`, `font-src ${VENDOR} data:`, `img-src 'self' data: blob:`,
    `connect-src 'self' wss://${host} ${VENDOR}`, `base-uri 'none'`, `form-action 'none'`, `frame-ancestors 'none'`].join('; '));
  headers.set('referrer-policy', 'no-referrer');
  headers.set('cache-control', 'no-store');
  headers.set('x-robots-tag', 'noindex');
  return new Response(asset.body, { status: asset.status, headers });
}

// Every public way into a board room shows a key this Worker signed (src/links.js); one that does not is turned away
// here, before any room is reached, so nobody can make a room by inventing a link.
async function publicRequest(request, env, parts) {
  if (parts[0] === 'board' && parts.length === 2 && PAGE_FILES.has(parts[1]) && request.method === 'GET') {
    return env.ASSETS.fetch(request);
  }
  if (parts[0] === 'j' && parts.length === 2 && request.method === 'GET') return shortLink(env, parts[1]);
  if (parts[0] !== 'b') return null;
  // The page itself holds nothing: its link's key is after the #, which a browser never sends.
  if (parts.length === 1 && request.method === 'GET') return page(request, env);
  const upgrade = request.headers.get('upgrade')?.toLowerCase() === 'websocket';
  const refused = () => json({ error: 'not found' }, 404);
  if (parts.length === 3 && parts[2] === 'ws' && upgrade) {
    const link = await verify(env.API_TOKEN, parts[1]);
    if (!link) return refused();
    const who = address(request.headers.get('cf-connecting-ip'));
    return roomRequest(env, link.token, '/socket', link.role,
      { headers: { upgrade: 'websocket', 'x-room-client': who, 'x-room-link': String(link.version) } });
  }
  // The bot's driver: the room's token, then its key (from API_TOKEN and the token), both in the path so no header
  // carries a key.
  if (parts.length === 4 && parts[2] === 'bot' && upgrade) {
    if (!env.API_TOKEN || !TOKEN.test(parts[1]) || !same(parts[3], await botKey(env.API_TOKEN, parts[1]))) return refused();
    const answer = await roomRequest(env, parts[1], '/socket', 'bot', { headers: { upgrade: 'websocket' } });
    if (answer.status !== 101) return answer;
    const offered = (request.headers.get('sec-websocket-protocol') || '').split(',').map((p) => p.trim());
    return new Response(null, { status: 101, webSocket: answer.webSocket,
      headers: offered.includes('hermes-bot') ? { 'sec-websocket-protocol': 'hermes-bot' } : {} });
  }
  return refused();
}

// Hermes turns a call's board link off, makes a new one (every older link stops), or asks for a watch-only one. The
// room moves its link version on for `off` and `new`; the links handed out here are signed for the version it has.
async function boardLink(env, origin, token, body) {
  const mode = body?.mode;
  if (!['off', 'new', 'view'].includes(mode)) return json({ error: 'mode must be off, new or view' }, 400);
  const answer = mode === 'view' ? await roomRequest(env, token, '/short', 'hermes')
    : await roomRequest(env, token, '/link', 'hermes', { method: 'POST' });
  if (!answer.ok) return json({ error: answer.status === 409 ? 'the call is over' : 'no such board room' }, answer.status);
  const { version, expires, ended } = await answer.json();
  if (ended || expires * 1000 <= Date.now()) return json({ error: 'the call is over' }, 409);
  if (mode === 'off') return json({ ok: true, board_url: null });
  const key = await sign(env.API_TOKEN, { token, scope: mode === 'new' ? 'e' : 'a', version, expires });
  return json({ ok: true, [mode === 'new' ? 'board_url' : 'view_url']: `${origin}/b/#${key}` });
}

// A new call's board room, opened before the bot starts so its board tab can join it: { token, edit, screen } (the
// keys of its links), or null when the room did not open.
async function openRoom(env) {
  const token = hex(crypto.getRandomValues(new Uint8Array(16)));
  const expires = Math.floor(Date.now() / 1000) + ROOM_SECONDS;
  const opened = await roomRequest(env, token, '/open', 'hermes', { method: 'POST', body: JSON.stringify({ expires }) });
  if (!opened.ok) return null;
  const link = (scope) => sign(env.API_TOKEN, { token, scope, version: 1, expires });
  return { token, edit: await link('e'), screen: await link('c') };
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const parts = url.pathname.split('/').filter(Boolean);
    const open = await publicRequest(request, env, parts);
    if (open) return open;
    if (!authorized(request, env)) return json({ error: 'unauthorized' }, 401);

    if (parts[0] === 'rooms' && parts.length === 3 && TOKEN.test(parts[1]) && parts[2] === 'link' && request.method === 'POST') {
      return boardLink(env, url.origin, parts[1], await request.json().catch(() => null));
    }
    if (parts[0] === 'rooms' && parts.length === 3 && TOKEN.test(parts[1]) && ROOM.has(`${request.method} ${parts[2]}`)) {
      return roomRequest(env, parts[1], `/${parts[2]}${url.search}`, 'hermes',
        { method: request.method, body: request.method === 'POST' ? request.body : undefined });
    }
    if (parts[0] !== 'bots') return json({ error: 'not found' }, 404);

    if (parts.length === 1 && request.method === 'POST') {
      const body = await request.json().catch(() => null);
      if (!body || !JOINABLE.some((link) => link.test(body.meeting_url || ''))) {
        return json({ error: 'meeting_url must be a Google Meet or Zoom link' }, 400);
      }
      // What the bot posts in the call's chat as it gets in, before it records (container/notice.mjs has the default).
      if (body.notice !== undefined && (typeof body.notice !== 'string' || body.notice.length > NOTICE_CHARS)) {
        return json({ error: `notice must be text of at most ${NOTICE_CHARS} characters` }, 400);
      }
      const id = crypto.randomUUID();
      const made = await openRoom(env);
      if (!made) return json({ error: 'the board room did not open' }, 502);
      const boardUrl = `${url.origin}/b/#${made.edit}`;
      const bot = getContainer(env.MEET_BOT, id);
      // The bot's Google account and Deepgram key ride in the start request, never in the container's environment, so
      // nothing the container starts inherits them (container/driver.mjs). Only settings that are set: the test copy
      // has no Google account, so it never signs in, and no Deepgram key, so it never listens.
      const secrets = Object.fromEntries(Object.entries({ google_email: env.GOOGLE_EMAIL,
        google_password: env.GOOGLE_PASSWORD, deepgram_api_key: env.DEEPGRAM_API_KEY })
        .filter(([, value]) => typeof value === 'string' && value !== ''));
      const started = await bot.fetch(new Request('http://bot/start', {
        method: 'POST',
        body: JSON.stringify({ secrets, meeting_url: body.meeting_url, bot_name: body.bot_name || "Notetaker",
          chat: body.chat === true, voice: body.voice === true, notice: body.notice,
          board: { page: `${url.origin}/b/?screen=1#${made.screen}`,
            socket: `wss://${url.host}/b/${made.token}/bot/${await botKey(env.API_TOKEN, made.token)}` } }),
      }));
      if (!started.ok) {
        await roomRequest(env, made.token, '/close', 'hermes', { method: 'POST' }).catch(() => {});
        return json({ error: `bot did not start: ${started.status}` }, 502);
      }
      await bot.keepRoom(made.token);
      return json({ id, board_token: made.token, board_url: boardUrl }, 201);
    }

    const id = parts[1];
    if (!id || !/^[0-9a-f-]{36}$/.test(id)) return json({ error: 'not found' }, 404);
    const bot = getContainer(env.MEET_BOT, id);
    if (parts.length === 2 && request.method === 'DELETE') {
      await bot.end();
      return json({ ok: true });
    }
    const rest = `/${parts.slice(2).join('/')}`;
    if (!PASS.has(`${request.method} ${rest}`)) return json({ error: 'not found' }, 404);
    return bot.fetch(new Request(`http://bot${rest}${url.search}`, { method: request.method, body: request.body }));
  },
};
