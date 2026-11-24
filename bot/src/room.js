// A call's board room: one Durable Object per call, named by the call's board token. It holds the call's whiteboards
// and sends every change, the moment it happens, to everyone looking: the bot's tab that is shared in the call, people
// who open the board link, and Hermes on the mini (over a server-sent event stream, which needs no WebSocket library).
//
// Who may do what is decided by the Worker before a request gets here (src/index.js, src/links.js): `bot` is the bot's
// own browser driver (captions, spoken and typed commands, whether it is presenting), `hermes` is the mini (edits,
// captions, which board is on screen), `screen` is the bot's shared tab and `watcher` anyone with a watch-only link, who
// both only watch, and `editor` is anyone with the board link, who may also edit the boards (through the same checks as
// Hermes) and show the others where their pointer is.
//
// A room exists only once the Worker's authenticated API opens it for a call (`/open`); until then it answers nothing and
// writes nothing. People are counted by their address (the Worker passes it), not by their socket, so opening another
// socket or reconnecting never gives anyone a fresh allowance.
//
// Undo: before a change, the room keeps what it changes, one step per command (a command's edits all carry its id) and
// one per change from the link, so "Hermes, undo" or the link's Undo button puts back everything the last one did. Which
// boards were on screen, and how, is kept with each step too, so undoing "show the pricing board" or "side by side"
// puts the screen back as it was.
import { DurableObject } from 'cloudflare:workers';
import { newShort } from './links.js';
import { boardName, fitView, isBoard } from '../public/board/model.mjs';
import { apply, clean, emptyBoard, HERMES_ONLY, LIMITS, recap, recapText } from './ops.js';

// Commands kept so a Hermes that reconnects can pick up what it missed.
const KEPT_EVENTS = 50;
const MAX_MESSAGE = 16 * 1024;
const KEEPALIVE_MS = 15000;
// A room nobody closed (the mini closes it when the call is filed) is emptied this long after it opened.
const LIFETIME_MS = 12 * 3600 * 1000;
// A closed room says so for a day, then is gone.
const ENDED_MS = 24 * 3600 * 1000;
const CAPTION_STATES = new Set(['hearing', 'heard', 'drawing', 'done', 'failed', 'idle']);
// Each budget: a burst of this many, then this many a second.
// Edits from one address, and from everyone in the room together.
const EDITS = [20, 5];
const ROOM_EDITS = [60, 10];
// Pointer moves from one address (a moving pointer sends about 20 a second), and every message from one address.
const POINTERS = [25, 25];
const MESSAGES = [80, 40];
// Sockets opened from one address, and in the room from anywhere.
const CONNECTS = [12, 0.2];
const ROOM_CONNECTS = [60, 1];
// Sockets open at once: from one address, people in the room, and the bot's own (which reconnect after a drop).
const ADDRESS_SOCKETS = 8;
const PEOPLE = 50;
const OWN_SOCKETS = { bot: 4, screen: 4 };
// An address that keeps sending after its messages are refused is cut off for a while.
const BLOCK_MS = 60000;
// The mini's batches of edits.
const MAX_BATCH = 50;
const MAX_BODY = 256 * 1024;
// Addresses remembered at most; ones with no socket open are forgotten first.
const ADDRESSES = 500;
const FAR = 1e6;
// Undo steps kept, and lines of the change log the pages show.
const HISTORY = 10;
const LOG = 30;
// Boards on screen lately, the latest first, for "split view" with no board named.
const RECENT = 9;

// `current` is the board on screen (null when none is); `last` is the board last on screen, which the next change goes to.
// `view` is how the boards are on screen (model.mjs fitView): one board, two side by side, or all of them small. With two
// side by side `current` is the one of them the next change goes to: the one changed last. `recent` lists the boards on
// screen lately, the latest first.
// `link` is the version a link's key must carry (src/links.js); `expires` is when the links stop working (unix seconds).
// `short` is the call's short link code once Hermes has shared the board link with the room (in the meeting chat), made
// for link version `shortFor`; only then does the shared screen show it, with its QR code.
// `made` pairs each command with the board it made (a command makes at most one).
const fresh = () => ({ boards: [], current: null, last: null, view: { mode: 'one' }, recent: [], seq: 0, events: [],
  presenting: false, present_error: null, ended: false, opened: false, expires: 0, link: 1, ownerLink: false, history: [],
  log: [], short: null, shortFor: 0, made: [] });
const encoder = new TextEncoder();
const str = (value, limit) => String(value ?? '').slice(0, limit);
const isObject = (value) => Boolean(value) && typeof value === 'object' && !Array.isArray(value);

// A budget that fills back up over time. Every try costs one, refused or not (down to minus the burst), so a client that
// keeps sending past its budget stays refused until it slows down.
class Budget {
  constructor([size, rate], now) {
    Object.assign(this, { size, rate, left: size, at: now });
  }

  take(now) {
    this.left = Math.max(-this.size, Math.min(this.size, this.left + (Math.max(0, now - this.at) / 1000) * this.rate) - 1);
    this.at = Math.max(this.at, now);
    return this.left >= 0;
  }

  // Spent past its burst: someone sending as fast as they can.
  flooded() {
    return this.left <= -this.size;
  }
}

// A room kept from before blocks: its boards, and those its undo steps keep, become lists, every section and note kept.
function upgraded(state) {
  const keep = (board) => (isBoard(board) ? board : clean(board));
  state.boards = (state.boards || []).map(keep);
  for (const step of state.history || []) {
    for (const n of Object.keys(step?.boards || {})) step.boards[n] = keep(step.boards[n]);
  }
  return state;
}

export class BoardRoom extends DurableObject {
  constructor(ctx, env) {
    super(ctx, env);
    this.sockets = new Map();
    this.streams = new Set();
    this.caption = null;
    // Per address: { sockets, connects, edits, pointers, messages, blockedUntil }.
    this.clients = new Map();
    this.now = () => Date.now();
    this.roomEdits = new Budget(ROOM_EDITS, this.now());
    this.roomConnects = new Budget(ROOM_CONNECTS, this.now());
    this.steps = 0;
    ctx.blockConcurrencyWhile(async () => {
      this.state = upgraded({ ...fresh(), ...((await ctx.storage.get('state')) || {}) });
    });
  }

  async fetch(request) {
    const url = new URL(request.url);
    const role = request.headers.get('x-room-role');
    // The Worker names the room's token, which its short link stands for.
    this.token ??= request.headers.get('x-room-token');
    if (url.pathname === '/open' && request.method === 'POST' && role === 'hermes') return this.open(request);
    // Not a room the Worker opened for a call: nothing here, and nothing kept.
    if (!this.state.opened) return new Response('not found', { status: 404 });
    if (url.pathname === '/socket') {
      return this.socket(role, request.headers.get('x-room-client') || '', Number(request.headers.get('x-room-link') || 0));
    }
    if (role !== 'hermes') return new Response('not found', { status: 404 });
    if (url.pathname === '/events') return this.events(Number(url.searchParams.get('after') || 0));
    if (url.pathname === '/send' && request.method === 'POST') {
      const text = await request.text().catch(() => '');
      if (text.length > MAX_BODY) return Response.json({ error: 'too much at once' }, { status: 413 });
      let body = null;
      try {
        body = JSON.parse(text);
      } catch {
        // Answered as no messages.
      }
      const msgs = Array.isArray(body?.msgs) ? body.msgs : [];
      if (msgs.length > MAX_BATCH) return Response.json({ error: `at most ${MAX_BATCH} messages at once` }, { status: 413 });
      const results = [];
      for (const msg of msgs) results.push(msg?.t === 'link' ? await this.share() : this.fromHermes(msg));
      return Response.json({ results, seq: this.state.seq, current: this.state.current, boards: this.state.boards.length });
    }
    if (url.pathname === '/state') return Response.json(this.snapshot());
    // For the Worker's /j/<code>: what an editor's link to this room carries now, and the short code it stands for.
    if (url.pathname === '/short') {
      const { link, expires, ended } = this.state;
      return Response.json({ version: link, expires, ended, short: this.short() });
    }
    if (url.pathname === '/link' && request.method === 'POST') return this.relink();
    if (url.pathname === '/close' && request.method === 'POST') return Response.json(await this.close());
    return new Response('not found', { status: 404 });
  }

  // Hermes turned the people's board link off (the Worker may then sign a new one for the version this gives): every
  // older link, its short link and everyone on one stop at once. The shared screen and the bot keep their sockets.
  async relink() {
    const state = this.state;
    if (state.ended) return Response.json({ error: 'the call is over' }, { status: 409 });
    state.link += 1;
    // From now on the owner hands the link out, so the room never puts it on the shared screen again, even for a share
    // that was already on its way.
    state.ownerLink = true;
    state.seq += 1;
    await this.save();
    this.broadcast({ t: 'short', seq: state.seq, short: null }, { hermes: false });
    for (const [ws, who] of [...this.sockets]) {
      if (!who.client) continue;
      this.drop(ws);
      try {
        ws.close(4403, 'this link was turned off');
      } catch {
        // Already closed.
      }
    }
    return Response.json({ version: state.link, expires: state.expires });
  }

  snapshot() {
    const { boards, current, last, seq, presenting, present_error: presentError, ended, log } = this.state;
    return { boards, current, last, view: this.view(), recent: this.state.recent || [], seq, presenting,
      present_error: presentError, ended, caption: this.caption, log, short: this.short(),
      listening: this.state.listening !== false };
  }

  // How the boards are on screen, as the boards there now allow.
  view() {
    return fitView(this.state.view, this.state.boards.length);
  }

  // Board n is on screen now: first in the list of boards on screen lately.
  seen(n) {
    if (n) this.state.recent = [n, ...(this.state.recent || []).filter((m) => m !== n)].slice(0, RECENT);
  }

  // The short code, while the link it was made for still works: a new or turned-off link ends it too.
  short() {
    return this.state.short && this.state.shortFor === this.state.link && !this.state.ended ? this.state.short : null;
  }

  // Hermes shared the board link with the room: from now on the shared screen shows a short link and a QR code. The
  // code is kept by its own object (src/short.js) and forgotten after a day and a half, longer than any call.
  async share() {
    const state = this.state;
    // Asked again after the code is kept, since the call can end, or the owner turn the link off, in the meantime.
    const refused = () => (this.state !== state || state.ended ? 'the call is over'
      : state.ownerLink ? 'the owner hands out this link' : null);
    if (refused()) return { ok: false, error: refused() };
    if (!this.short()) {
      if (!this.token || !this.env.SHORT_LINKS || !this.env.API_TOKEN) return { ok: false, error: 'no short link here' };
      let code = null;
      for (let i = 0; i < 3 && !code; i++) {
        const tried = await newShort(this.env.API_TOKEN);
        const kept = await this.env.SHORT_LINKS.get(this.env.SHORT_LINKS.idFromName(tried))
          .fetch('https://short/', { method: 'PUT', body: JSON.stringify({ token: this.token }) });
        if (kept.ok) code = tried;
      }
      if (!code) return { ok: false, error: 'no short link was free' };
      if (refused()) return { ok: false, error: refused() };
      Object.assign(state, { short: code, shortFor: state.link });
      state.seq += 1;
      await this.save();
      this.broadcast({ t: 'short', seq: state.seq, short: code }, { hermes: false });
    }
    return { ok: true, short: this.short() };
  }

  // The Worker's API opens the room for a new call, before its bot starts. It is emptied LIFETIME_MS later at the latest.
  async open(request) {
    if (this.state.opened) return Response.json({ error: 'this room is already open' }, { status: 409 });
    const body = await request.json().catch(() => null);
    const expires = Number(body?.expires);
    if (!Number.isFinite(expires) || expires <= 0) return Response.json({ error: 'expires is needed' }, { status: 400 });
    this.state = { ...fresh(), opened: true, expires };
    await this.save();
    await this.ctx.storage.setAlarm(this.now() + LIFETIME_MS);
    return Response.json({ ok: true });
  }

  // A socket for one page or the bot. People (`editor`, `watcher`) are let in only with the room's current link version,
  // and within the limits for their address and the room; a refusal costs no socket.
  socket(role, address, version) {
    if (!['bot', 'screen', 'editor', 'watcher'].includes(role)) return new Response('not found', { status: 404 });
    const now = this.now();
    // The bot's own sockets outlast a change of the people's link; nothing outlasts the links' end.
    if (role !== 'bot' && ((!OWN_SOCKETS[role] && version !== this.state.link) || now >= this.state.expires * 1000)) {
      return new Response('this link no longer works', { status: 410 });
    }
    const open = [...this.sockets.values()];
    let client = null;
    if (OWN_SOCKETS[role]) {
      if (open.filter((w) => w.role === role).length >= OWN_SOCKETS[role]) return this.tooMany();
    } else {
      client = this.client(address, now);
      if (!client || now < client.blockedUntil || !client.connects.take(now) || client.sockets >= ADDRESS_SOCKETS) {
        return this.tooMany();
      }
      // Only a try its address allows spends the room's allowance, so one address cannot use it up for everyone.
      if (open.filter((w) => w.client).length >= PEOPLE || !this.roomConnects.take(now)) return this.tooMany();
    }
    const [page, server] = Object.values(new WebSocketPair());
    server.accept();
    const who = { role, id: crypto.randomUUID().slice(0, 8), client };
    if (client) client.sockets += 1;
    this.sockets.set(server, who);
    server.addEventListener('message', (event) => this.message(server, who, event.data));
    const gone = () => this.drop(server);
    server.addEventListener('close', gone);
    server.addEventListener('error', gone);
    server.send(JSON.stringify({ t: 'hello', role, you: who.id, ...this.snapshot() }));
    return this.accepted(page);
  }

  accepted(page) {
    return new Response(null, { status: 101, webSocket: page });
  }

  tooMany() {
    return new Response('too many connections; try again in a minute', { status: 429 });
  }

  client(address, now) {
    let client = this.clients.get(address);
    if (client) return client;
    // A full table forgets the addresses with no socket and no block; one still full of those turns new ones away.
    if (this.clients.size >= ADDRESSES) {
      for (const [key, old] of this.clients) if (!old.sockets && old.blockedUntil <= now) this.clients.delete(key);
      if (this.clients.size >= ADDRESSES) return null;
    }
    client = { sockets: 0, connects: new Budget(CONNECTS, now), edits: new Budget(EDITS, now),
      pointers: new Budget(POINTERS, now), messages: new Budget(MESSAGES, now), blockedUntil: 0 };
    this.clients.set(address, client);
    return client;
  }

  // One message on a socket. A person's every message costs from their address's budget before it is read; an address
  // that floods the room has its sockets closed and is kept out for BLOCK_MS.
  message(ws, who, data) {
    if (who.client) {
      const now = this.now();
      const client = who.client;
      if (!client.messages.take(now)) {
        if (client.messages.flooded()) this.block(client, now);
        return;
      }
    }
    if (typeof data !== 'string' || data.length > MAX_MESSAGE) return;
    let msg;
    try {
      msg = JSON.parse(data);
    } catch {
      return;
    }
    if (!isObject(msg)) return;
    if (who.role === 'bot') this.fromBot(msg, ws);
    else if (who.role === 'editor') this.fromPerson(ws, who, msg);
  }

  // Forgets a socket that closed or failed, once.
  drop(ws) {
    const who = this.sockets.get(ws);
    if (!who) return;
    this.sockets.delete(ws);
    if (who.client) who.client.sockets -= 1;
  }

  block(client, now) {
    client.blockedUntil = now + BLOCK_MS;
    for (const [ws, who] of [...this.sockets]) {
      if (who.client !== client) continue;
      this.drop(ws);
      try {
        ws.close(1008, 'too many messages');
      } catch {
        // Already closed.
      }
    }
  }

  // Hermes's stream: the room as it is now, then the commands it missed, then everything as it happens.
  events(after) {
    const { readable, writable } = new TransformStream();
    const writer = writable.getWriter();
    const stream = { writer, alive: true };
    const write = (text) => writer.write(encoder.encode(text)).catch(() => {
      stream.alive = false;
      this.streams.delete(stream);
    });
    stream.write = write;
    write(`data: ${JSON.stringify({ t: 'hello', ...this.snapshot() })}\n\n`);
    for (const event of this.state.events) if (event.seq > after) write(`id: ${event.seq}\ndata: ${JSON.stringify(event)}\n\n`);
    this.streams.add(stream);
    this.keepAlive();
    return new Response(readable, { headers: { 'content-type': 'text/event-stream', 'cache-control': 'no-store' } });
  }

  keepAlive() {
    if (this.pinger) return;
    this.pinger = setInterval(() => {
      if (!this.streams.size) {
        clearInterval(this.pinger);
        this.pinger = null;
        return;
      }
      for (const stream of this.streams) stream.write(': ping\n\n');
    }, KEEPALIVE_MS);
  }

  // To the pages (and the bot), and to Hermes unless it is only a caption or for pages alone.
  broadcast(msg, { hermes = true, except = null } = {}) {
    const text = JSON.stringify(msg);
    for (const ws of this.sockets.keys()) {
      if (ws === except) continue;
      try {
        ws.send(text);
      } catch {
        this.drop(ws);
      }
    }
    if (hermes) for (const stream of this.streams) stream.write(`${msg.seq ? `id: ${msg.seq}\n` : ''}data: ${text}\n\n`);
  }

  save() {
    return this.ctx.storage.put('state', this.state);
  }

  fromBot(msg, ws = null) {
    if (this.state.ended) return;
    // The bot is leaving the call: the recap goes on screen and into the notes, and Hermes may say it in the chat.
    if (msg.t === 'recap') {
      const result = this.recap({ key: 'bot:recap', by: 'hermes', auto: true });
      try {
        ws?.send(JSON.stringify({ t: 'recapped', ...result }));
      } catch {
        this.drop(ws);
      }
      return;
    }
    if (msg.t === 'hearing') {
      this.caption = { state: 'hearing', text: str(msg.text, 600), id: str(msg.id, 40) };
      return this.broadcast({ t: 'caption', ...this.caption }, { hermes: false });
    }
    if (msg.t === 'command') {
      const id = str(msg.id, 40);
      const text = str(msg.text, 600);
      // The bot sends a command again until it hears `got` (container/board-link.mjs): one the room has is taken once.
      // An id is the command's own for the whole call (a spoken one carries the bot process's start time, a typed one
      // its chat message's id), and Hermes names the command by it: its board, its undo step, and that it is finished.
      const got = () => {
        try {
          ws?.send(JSON.stringify({ t: 'got', id }));
        } catch {
          this.drop(ws);
        }
      };
      if (this.state.events.some((e) => e.id === id)) return got();
      const event = { t: 'command', seq: ++this.state.seq, id, text,
        source: msg.source === 'chat' ? 'chat' : 'voice', sender: str(msg.sender, 120), direct: Boolean(msg.direct),
        ...(msg.continues ? { continues: str(msg.continues, 40) } : {}), at: new Date().toISOString() };
      this.state.events = [...this.state.events, event].slice(-KEPT_EVENTS);
      this.save();
      // Sent after the save: Cloudflare holds a Durable Object's messages until its writes are stored.
      got();
      if (event.source === 'voice') {
        this.caption = { state: 'heard', text: event.text, id: event.id };
        this.broadcast({ t: 'caption', ...this.caption }, { hermes: false });
      }
      // Hermes gets the boards with the command, so it can start on it without asking for them.
      for (const stream of this.streams) {
        const { boards, current, last, recent } = this.state;
        stream.write(`id: ${event.seq}\ndata: ${JSON.stringify({ ...event, boards, current, last, view: this.view(), recent })}\n\n`);
      }
      return;
    }
    // Whether the bot can hear spoken commands now (container/voice.mjs listening()): while it cannot, the status bar says
    // "Not listening, type in chat". Kept, so a page that opens later is told too.
    if (msg.t === 'listening') {
      const on = msg.on !== false;
      if (on === (this.state.listening !== false)) return;
      this.state.listening = on;
      // Words heard before the stream dropped are never finished (voice.mjs reset()): a page that opens later is not
      // shown them as still being heard.
      if (!on && this.caption?.state === 'hearing') this.caption = null;
      this.save();
      return this.broadcast({ t: 'listening', on }, { hermes: false });
    }
    if (msg.t === 'presenting') {
      this.state.presenting = Boolean(msg.on);
      this.state.present_error = msg.error ? str(msg.error, 200) : null;
      this.save();
      this.broadcast({ t: 'presenting', on: this.state.presenting, error: this.state.present_error });
    }
  }

  // One message from Hermes: { ok, ... } or { ok: false, error }.
  fromHermes(msg) {
    const state = this.state;
    if (state.ended) return { ok: false, error: 'the call is over' };
    const cmd = msg?.cmd ? str(msg.cmd, 40) : null;
    // Each command's changes are one undo step; a message with no command is a step of its own.
    const key = `h:${cmd || `-${++this.steps}`}`;
    if (msg?.t === 'caption') {
      if (!CAPTION_STATES.has(msg.state)) return { ok: false, error: 'unknown caption state' };
      this.caption = { state: msg.state, text: str(msg.text, 600), detail: str(msg.detail, 200), id: cmd };
      this.broadcast({ t: 'caption', ...this.caption }, { hermes: false });
      // What a command did names its undo step, and is a line in the change log.
      const step = state.history.at(-1);
      if (msg.state === 'done' && cmd && this.caption.detail) {
        if (step?.key === key) step.what = this.caption.detail;
        this.logged(this.caption.detail, 'Hermes');
        // Kept, so the log line and the undo step's words outlive the room being moved or woken again.
        this.save();
      }
      if (msg.state === 'done' || msg.state === 'failed') this.finished(cmd);
      return { ok: true };
    }
    if (msg?.t === 'op') return this.edit(msg.n, msg.op, { by: 'hermes', cmd, key });
    if (msg?.t === 'undo') {
      // An undo says it is done on the board itself, with no caption from Hermes; it is finished as it happens, so a
      // Hermes that restarts never undoes a second change for it.
      const result = this.undo({ by: 'hermes', cmd });
      if (result.ok) this.finished(cmd);
      return result;
    }
    if (msg?.t === 'recap') return this.recap({ key, by: 'hermes', cmd });
    if (msg?.t === 'new') {
      // A command makes at most one board. Asked again for the same command (an answer lost on the way, or a Hermes
      // that restarted mid-command), the room gives the board it already made instead of a second one.
      const made = cmd && (state.made || []).find(([c, n]) => c === cmd && state.boards[n - 1]);
      if (made) return { ok: true, n: made[1] };
      if (state.boards.length >= LIMITS.boards) return { ok: false, error: `a call holds at most ${LIMITS.boards} whiteboards` };
      this.remember(key);
      // A template comes as the whole board.
      state.boards.push(msg.board ? clean(msg.board) : emptyBoard(msg.title));
      // A new board opens on its own, as a new tab does.
      state.current = state.last = state.boards.length;
      state.view = { mode: 'one' };
      this.seen(state.current);
      if (cmd) state.made = [...(state.made || []), [cmd, state.current]].slice(-KEPT_EVENTS);
      state.seq += 1;
      this.save();
      this.broadcast({ t: 'board', seq: state.seq, n: state.current, board: state.boards[state.current - 1], changed: [],
        by: 'hermes', cmd, current: state.current, view: this.view() });
      return { ok: true, n: state.current };
    }
    if (msg?.t === 'set') {
      const n = Number(msg.n);
      if (!state.boards[n - 1]) return { ok: false, error: `there is no board ${msg.n}` };
      this.remember(key, n);
      state.boards[n - 1] = clean(msg.board);
      state.seq += 1;
      this.save();
      this.broadcast({ t: 'board', seq: state.seq, n, board: state.boards[n - 1], changed: [], by: 'hermes', cmd,
        current: state.current, view: this.view() });
      return { ok: true, n };
    }
    if (msg?.t === 'show' || msg?.t === 'stop') {
      // { t: 'show', n } puts board n on screen alone; with `split: [a, b]`, boards a and b side by side (n one of them,
      // the one the next change goes to); with `all: true`, every board small, the next change still going to n.
      const n = msg.t === 'stop' ? null : Number(msg.n);
      if (n !== null && !state.boards[n - 1]) return { ok: false, error: `there is no board ${msg.n}` };
      const asked = msg.t === 'stop' ? { mode: 'one' } : msg.all ? { mode: 'all' } : msg.split ? { mode: 'split', boards: msg.split }
        : { mode: 'one' };
      const view = fitView(asked, state.boards.length);
      if (view.mode !== asked.mode) {
        return { ok: false, error: asked.mode === 'all' ? 'there is only one board' : 'side by side takes two boards the call has' };
      }
      if (view.mode === 'split' && !view.boards.includes(n)) return { ok: false, error: `board ${n} is not one of the two` };
      this.remember(key);
      state.current = n;
      state.view = view;
      if (n !== null) state.last = n;
      this.seen(n);
      state.seq += 1;
      this.save();
      this.broadcast({ t: 'current', seq: state.seq, n, view, cmd });
      return { ok: true, n, view };
    }
    return { ok: false, error: 'unknown message' };
  }

  // A command Hermes has finished is marked, so a Hermes that restarts and is sent it again skips it.
  finished(cmd) {
    const heard = cmd && this.state.events.find((e) => e.t === 'command' && e.id === cmd);
    if (!heard || heard.finished) return;
    heard.finished = true;
    this.save();
  }

  // One edit to board n, from Hermes or from someone with the link; everyone gets the board that results.
  edit(number, op, { by, key, cmd = null, name = null, person = null }) {
    const state = this.state;
    const n = Number(number);
    const board = state.boards[n - 1];
    if (!board) return { ok: false, error: `there is no board ${number}` };
    if (by !== 'hermes' && HERMES_ONLY(op)) return { ok: false, error: 'only Hermes draws custom pictures' };
    const result = apply(board, op);
    if (result.error) return { ok: false, error: result.error };
    if (op.op === 'sketch') return this.drawn(n, op, result, { cmd });
    if (result.same) return { ok: true, changed: [], what: '', same: true };
    const step = this.remember(key, n);
    if (person) {
      step.what = result.what;
      this.logged(result.what, name);
    }
    state.boards[n - 1] = result.board;
    // With two boards side by side, the next change goes to the one changed last, whoever changed it.
    const view = this.view();
    if (view.mode === 'split' && view.boards.includes(n) && state.current !== n) {
      state.current = state.last = n;
      this.seen(n);
    }
    state.seq += 1;
    this.save();
    this.broadcast({ t: 'board', seq: state.seq, n, board: result.board, changed: result.changed, what: result.what, by, cmd,
      ...(person ? { name, person } : {}), current: state.current, view });
    return { ok: true, changed: result.changed, what: result.what, ...(result.added ? { added: result.added } : {}),
      ...(result.block ? { block: result.block } : {}), ...(result.joined ? { joined: result.joined } : {}) };
  }

  // A custom picture filled in as Hermes's model draws it. It finishes the change that asked for it rather than being a
  // change of its own: no undo step, and every undo step that kept the board while the picture was being drawn gets it
  // too, so undoing a later change never takes the picture back to its placeholder, and undoing the change that asked
  // for it takes the picture away whole.
  drawn(n, op, result, { cmd }) {
    const state = this.state;
    const now = result.board.blocks.find((b) => b.id === op.id);
    for (const step of state.history) {
      const kept = step.boards[n]?.blocks?.find((b) => b.id === now.id && b.type === 'sketch' && b.drawing === op.drawing);
      if (!kept) continue;
      for (const key of ['svg', 'drawing', 'failed']) {
        if (now[key] === undefined) delete kept[key];
        else kept[key] = now[key];
      }
    }
    state.boards[n - 1] = result.board;
    state.seq += 1;
    this.save();
    this.broadcast({ t: 'board', seq: state.seq, n, board: result.board, changed: result.changed, what: result.what, by: 'hermes',
      cmd, current: state.current, sketch: true });
    return { ok: true, changed: result.changed, what: result.what };
  }

  // Keeps what a change is about to change, in the undo step `key` (a new one unless it is the last step's): board n
  // as it is, the number of boards, and which is on screen.
  remember(key, n = null) {
    const state = this.state;
    let step = state.history.at(-1);
    if (!step || step.key !== key) {
      step = { key, count: state.boards.length, current: state.current, last: state.last, view: this.view(),
        recent: [...(state.recent || [])], boards: {}, what: '' };
      state.history = [...state.history, step].slice(-HISTORY);
    }
    if (n !== null && n <= step.count && !(n in step.boards)) step.boards[n] = structuredClone(state.boards[n - 1]);
    return step;
  }

  // What the shared screen shows, in words: a board's name, two names side by side, or every board.
  onScreen() {
    const view = this.view();
    const name = (n) => boardName(this.state.boards[n - 1]);
    if (view.mode === 'split') return `${name(view.boards[0])} and ${name(view.boards[1])} side by side`;
    if (view.mode === 'all') return `all ${this.state.boards.length} boards`;
    return name(this.state.current);
  }

  // Puts back everything the last step changed. Everyone gets the boards as they are again.
  undo({ by, cmd = null, name = null }) {
    const state = this.state;
    const step = state.history.pop();
    if (!step) return { ok: false, error: 'there is nothing to undo' };
    // A step that changed no board only moved the screen; its undo says what is back on it.
    const moved = !Object.keys(step.boards).length && step.count === state.boards.length;
    for (const [n, board] of Object.entries(step.boards)) state.boards[Number(n) - 1] = board;
    state.boards = state.boards.slice(0, step.count);
    // A board the undo took away is no longer the board its command made.
    state.made = (state.made || []).filter(([, n]) => n <= state.boards.length);
    const there = (n) => (n && n <= state.boards.length ? n : null);
    state.current = there(step.current);
    state.last = there(step.last) ?? there(state.boards.length);
    // The screen as it was: one board, two side by side, or all of them (a step from before views is one board).
    state.view = fitView(step.view, state.boards.length);
    if (state.view.mode === 'split' && !state.view.boards.includes(state.current)) state.current = state.view.boards[0];
    if (Array.isArray(step.recent)) state.recent = step.recent.filter((n) => n <= state.boards.length);
    state.seq += 1;
    const what = moved && state.current ? `Undone: back to ${this.onScreen()}`
      : `Undone: ${step.what ? step.what[0].toLowerCase() + step.what.slice(1) : 'the last change'}`;
    this.logged(what, by === 'person' ? name : 'Hermes');
    this.save();
    const changed = Object.keys(step.boards).map(Number);
    this.broadcast({ t: 'undone', seq: state.seq, boards: state.boards, current: state.current, last: state.last,
      view: this.view(), changed, what, by, cmd, ...(name ? { name } : {}) });
    this.caption = { state: 'done', text: '', detail: what, id: cmd };
    this.broadcast({ t: 'caption', ...this.caption }, { hermes: false });
    return { ok: true, what, changed, boards: state.boards.length, current: state.current };
  }

  // The recap board (ops.js recap()) on screen: made new, or the call's earlier recap brought up to date.
  recap({ key, by, cmd = null, auto = false }) {
    const state = this.state;
    const at = state.boards.findIndex((b) => b.recap);
    const board = recap(state.boards, state.boards[at]);
    if (!board) return { ok: false, error: 'there is nothing to recap yet: no action items, decisions or risks' };
    if (at < 0 && state.boards.length >= LIMITS.boards) return { ok: false, error: `a call holds at most ${LIMITS.boards} whiteboards` };
    this.remember(key, at >= 0 ? at + 1 : null);
    if (at >= 0) state.boards[at] = board;
    else state.boards.push(board);
    const n = at >= 0 ? at + 1 : state.boards.length;
    state.current = state.last = n;
    state.view = { mode: 'one' };
    this.seen(n);
    state.seq += 1;
    const text = recapText(board);
    this.save();
    this.broadcast({ t: 'board', seq: state.seq, n, board, changed: [], by, cmd, current: n, view: this.view(), recap: true, auto,
      text });
    return { ok: true, n, text };
  }

  logged(what, who) {
    const entry = { what: str(what, 200), who: str(who, 40) || 'Guest', at: new Date().toISOString() };
    this.state.log = [...this.state.log, entry].slice(-LOG);
    this.broadcast({ t: 'log', entry }, { hermes: false });
  }

  // Someone with the board link: an edit (answered only when refused), or where their pointer is on the board, which
  // only the other pages get.
  fromPerson(ws, who, msg) {
    if (this.state.ended) return;
    const name = str(msg.name, 40).trim() || 'Guest';
    const now = this.now();
    if (msg.t === 'pointer') {
      if (!who.client.pointers.take(now)) return;
      if (msg.gone) return this.broadcast({ t: 'pointer', id: who.id, gone: true }, { hermes: false, except: ws });
      // On the lists a pointer is the item it is on, and its board (ids are only unique on one board, and two boards can
      // be on screen), which every page can find whatever its layout.
      if (typeof msg.at === 'string') {
        const at = msg.at.replace(/[^\w:-]/g, '').slice(0, 40);
        const n = Number(msg.n);
        return at && this.broadcast({ t: 'pointer', id: who.id, name, at, ...(Number.isInteger(n) && n > 0 && n <= LIMITS.boards ? { n } : {}) },
          { hermes: false, except: ws });
      }
      const [x, y] = [Number(msg.x), Number(msg.y)];
      if (!(Math.abs(x) < FAR && Math.abs(y) < FAR)) return;
      return this.broadcast({ t: 'pointer', id: who.id, name, x, y }, { hermes: false, except: ws });
    }
    if (msg.t !== 'op' && msg.t !== 'undo') return;
    let result;
    // The room's budget is charged only for an edit the address's allows, so one address cannot spend the room's, and
    // many addresses cannot flood it together.
    const allowed = who.client.edits.take(now) && this.roomEdits.take(now);
    if (!allowed) result = { ok: false, error: 'too many changes at once; try again in a moment' };
    else {
      result = msg.t === 'undo' ? this.undo({ by: 'person', name })
        : this.edit(msg.n, msg.op, { by: 'person', name, person: who.id, key: `p:${who.id}:${++this.steps}` });
    }
    if (!result.ok) {
      try {
        ws.send(JSON.stringify({ t: 'refused', ref: str(msg.ref, 40), error: result.error }));
      } catch {
        this.drop(ws);
      }
    }
  }

  async close() {
    const boards = this.state.boards.length;
    this.state = { ...fresh(), opened: true, expires: this.state.expires, link: this.state.link, ended: true };
    this.caption = null;
    await this.ctx.storage.deleteAll();
    await this.save();
    await this.ctx.storage.setAlarm(this.now() + ENDED_MS);
    this.broadcast({ t: 'ended' });
    for (const ws of this.sockets.keys()) {
      try {
        ws.close(1000, 'the call is over');
      } catch {
        // Already closed.
      }
    }
    this.sockets.clear();
    this.clients.clear();
    for (const stream of this.streams) stream.writer.close().catch(() => {});
    this.streams.clear();
    return { ok: true, boards };
  }

  // A room that was never closed is emptied once it is old; a closed one is removed a day later.
  async alarm() {
    if (this.state.opened && !this.state.ended) {
      await this.close();
      return;
    }
    await this.ctx.storage.deleteAll();
  }
}
