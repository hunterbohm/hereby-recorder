// The bot's own line to its call's board room (the Worker's BoardRoom). Captions and commands go out as they are heard;
// the room's word on which board is on screen comes back, so the bot shares or stops sharing the board. A dropped line
// is opened again, and what was said meanwhile waits (up to a limit). Each command is kept until the room says it has
// it (`got`, sent once it is stored), and sent again on every new line until then; the room takes a command it already
// has only once, so none is lost to a line that drops with it on the way and none is carried out twice.
const WAITS = [500, 1000, 2000, 5000, 10000];
const HELD = 50;

export class BoardLink {
  // `socket` is the room's address for the bot, which carries the bot's key in its path (src/index.js). `current` gives
  // the messages that say how the bot is now (whether it can hear spoken commands), sent on every new line, so a change
  // lost with a line that dropped is put right on the next.
  constructor({ socket, onRoom = () => {}, current = () => [], log = console.log,
    connect = (url, protocols) => new WebSocket(url, protocols), later = setTimeout }) {
    Object.assign(this, { url: socket, onRoom, current, log, open: connect, later });
    this.ws = null;
    this.held = [];
    // Commands the room has not said it has yet, oldest first.
    this.unconfirmed = [];
    this.failures = 0;
    this.closed = false;
    this.room = { current: null, boards: 0 };
  }

  connect() {
    if (this.closed || this.ws) return;
    // The key is in the address's path, never in a header: Cloudflare's logs keep headers as sent, and hide keys in paths.
    const ws = this.ws = this.open(this.url, ['hermes-bot']);
    ws.onopen = () => {
      this.failures = 0;
      for (const msg of [...this.held.splice(0), ...this.unconfirmed, ...this.current()]) ws.send(JSON.stringify(msg));
    };
    ws.onmessage = (event) => {
      let msg;
      try {
        msg = JSON.parse(String(event.data));
      } catch {
        return;
      }
      this.receive(msg);
    };
    ws.onerror = () => {};
    ws.onclose = () => {
      if (this.ws !== ws) return;
      this.ws = null;
      if (this.closed) return;
      const wait = WAITS[Math.min(this.failures, WAITS.length - 1)];
      this.failures += 1;
      this.log('board link closed, again in', wait, 'ms');
      this.later(() => this.connect(), wait);
    };
  }

  receive(msg) {
    if (msg.t === 'got') {
      this.unconfirmed = this.unconfirmed.filter((held) => held.id !== msg.id);
      return;
    }
    if (msg.t === 'recapped') {
      this.recapped?.(msg);
      return;
    }
    if (msg.t === 'hello') this.room = { current: msg.current ?? null, boards: (msg.boards || []).length };
    else if (msg.t === 'board') this.room = { current: msg.current ?? this.room.current, boards: Math.max(this.room.boards, msg.n) };
    else if (msg.t === 'current') this.room = { ...this.room, current: msg.n };
    // An undo can bring a board back on screen (or take one off), and changes how many there are.
    else if (msg.t === 'undone') this.room = { current: msg.current ?? null, boards: (msg.boards || []).length };
    else if (msg.t === 'ended') this.room = { current: null, boards: this.room.boards };
    else return;
    this.onRoom(this.room);
  }

  send(msg) {
    if (this.closed) return;
    if (msg.t === 'command') {
      this.unconfirmed.push(msg);
      if (this.unconfirmed.length > HELD) this.log('board link: gave up on command', this.unconfirmed.shift().id);
    }
    if (this.ws?.readyState === 1) {
      this.ws.send(JSON.stringify(msg));
      return;
    }
    // A caption is only worth showing live; a command waits with the unconfirmed ones; how the bot is now goes on the
    // next line anyway (`current`); anything else waits here.
    if (!['hearing', 'command', 'listening'].includes(msg.t)) this.held = [...this.held, msg].slice(-HELD);
    this.connect();
  }

  // Commands sent but not yet confirmed by the room (for /status).
  pending() {
    return this.unconfirmed.length;
  }

  // The recap board, asked for as the bot leaves the call: the room's answer ({ ok, n, text } or { ok: false, error }),
  // or null when there is no board to recap or no answer in time.
  recap(ms = 3000) {
    if (this.closed || this.room.boards < 1) return Promise.resolve(null);
    return new Promise((resolve) => {
      let over = false;
      const done = (value) => {
        if (over) return;
        over = true;
        this.recapped = null;
        resolve(value);
      };
      this.recapped = done;
      this.later(() => done(null), ms);
      this.send({ t: 'recap' });
    });
  }

  close() {
    this.closed = true;
    this.recapped?.(null);
    const { ws } = this;
    this.ws = null;
    try {
      ws?.close();
    } catch {
      // Already closed.
    }
  }
}
