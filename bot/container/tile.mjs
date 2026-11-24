// The bot's own camera tile in a Meet call, which says from the moment it is let in that Hermes is listening, how to
// talk to it, and the words it hears, before any board is up. A person in the call who said "Hermes, start a whiteboard"
// and got nothing could not tell whether the bot heard them, heard something else, or was listening at all (a real
// call, 2026-11-21). The tile is drawn on a canvas in the Meet page and given to Meet as the bot's camera
// (tileScript); `Tile` decides what it says and sends that to the page. What it shows is only drawn, never kept.

// What the bot heard stays on the tile this long after the words stop, and a near miss's hint this long.
export const CAPTION_MS = 6000;
export const HINT_MS = 12000;
const CAPTION_CHARS = 140;

// What the tile says: { tone, title, lead, say, caption, board }. One thing at a time, big: the state, then what to say
// (`lead` and `say`), or instead the words just heard. With a board on screen Meet shows the tile small beside it, and
// the board has the commands and the words heard, so the tile only says that Hermes is listening and the name to say.
export class Tile {
  constructor(push, now = Date.now) {
    Object.assign(this, { push, now });
    this.on = true;
    this.started = false;
    this.shown = false;
    this.heard = '';
    this.heardAt = 0;
    this.missAt = null;
    this.startedAt = null;
    this.last = null;
  }

  // The notice is up in the chat, so the bot listens from now on (driver.mjs); until then the tile says it is getting
  // ready.
  ready() {
    this.started = true;
    this.update();
  }

  listening(on) {
    this.on = on;
    this.update();
  }

  board(shown) {
    this.shown = shown;
    this.update();
  }

  // Every phrase's words as they come, command or not.
  words(text) {
    this.heard = String(text || '').trim();
    this.heardAt = this.now();
    this.update();
  }

  // A phrase that sounded like a board command with no name (voice.mjs nearMiss), or an unnamed request to start a
  // board that was taken (`started`).
  nearMiss({ hint, started }) {
    if (started) this.startedAt = this.now();
    else if (hint) this.missAt = this.now();
    this.update();
  }

  view() {
    const now = this.now();
    const recent = (at, ms) => at !== null && now - at < ms;
    const board = this.shown;
    const caption = !board && this.heard && now - this.heardAt < CAPTION_MS
      ? (this.heard.length > CAPTION_CHARS ? `…${this.heard.slice(-CAPTION_CHARS)}` : this.heard) : '';
    if (!this.started) {
      return { tone: 'working', title: 'Getting ready', lead: 'In a moment, say', say: 'Hey Hermes, start a whiteboard',
        caption: '', board };
    }
    if (!this.on) {
      return { tone: 'off', title: 'Not listening', lead: 'Type in the chat',
        say: board ? 'Hermes, add a goal …' : 'Hermes, start a whiteboard', caption: '', board };
    }
    const missed = recent(this.missAt, HINT_MS);
    if (board) return { tone: 'listening', title: 'Listening', lead: missed ? 'Start with' : 'Say', say: 'Hey Hermes', caption, board };
    if (recent(this.startedAt, HINT_MS)) {
      return { tone: 'working', title: 'Starting a board', lead: 'Next time, start with', say: 'Hey Hermes', caption, board };
    }
    return { tone: 'listening', title: 'Listening', lead: missed ? 'Start with' : 'Say',
      say: missed ? 'Hey Hermes' : 'Hey Hermes, start a whiteboard', caption, board };
  }

  // Sends the view when it changed; the driver also calls this every second, so a caption goes when it is old.
  update() {
    const view = this.view();
    const json = JSON.stringify(view);
    if (json === this.last) return;
    this.last = json;
    this.push(view);
  }
}

// Runs in the Meet page before Meet does (Playwright's addInitScript), with the board's own font as base64 data, since
// the page's rules would not let it load one. It draws the tile in the board's colors (mockup A's status bar, Hermes's
// violet for what to say) on a canvas, and gives Meet the canvas as the camera: the container has none, so a camera is
// listed for Meet to pick, and a request for video gets the canvas while sound still comes from the real microphone.
// `window.hermesTile(view)` sets what it says.
export function tileScript({ fonts = [] } = {}) {
  if (!location.host.endsWith('meet.google.com') || !navigator.mediaDevices) return;
  // Square, with every word inside the middle 700 wide and 440 high: Meet fills each tile by cutting the picture to the
  // tile's shape, wide (about 2 to 1) on a big tile and square or tall beside a shared board (a 16:9 picture lost the
  // ends of "Board on screen" there, a test call, 2026-11-21). Beside a board Meet shows the whole square about 280
  // pixels wide, so the tile then says less in bigger type, and nothing anywhere is drawn smaller than 44 pixels here;
  // only flat shapes and bold type, which the video's compression keeps sharp.
  const W = 960;
  const H = 960;
  const SAFE_W = 700;
  const SAFE_H = 440;
  const canvas = document.createElement('canvas');
  canvas.width = W;
  canvas.height = H;
  const g = canvas.getContext('2d');
  const stream = canvas.captureStream(8);
  let view = { tone: 'working', title: 'Getting ready', lead: 'In a moment, say', say: 'Hey Hermes, start a whiteboard',
    caption: '', board: false };
  let family = 'sans-serif';
  for (const font of fonts) {
    try {
      const face = new FontFace('Atkinson Next', Uint8Array.from(atob(font.data), (c) => c.charCodeAt(0)),
        { weight: String(font.weight) });
      document.fonts.add(face);
      face.load().then(() => { family = '"Atkinson Next", sans-serif'; draw(); }).catch(() => {});
    } catch {
      // The tile falls back to the system font.
    }
  }
  const color = { field: '#1b1f27', ink: '#f3f4f6', muted: '#b7bcc7', hermes: '#6a45dc', ok: '#37b26c', bad: '#e5533d' };
  const font = (px, weight) => `${weight} ${px}px ${family}`;
  const width = (text, f) => { g.font = f; return g.measureText(text).width; };
  // The text in at most `lines` lines of at most `max` wide, at the largest size from `px` down that fits: [size, lines].
  // Two lines break after a comma where there is one ("Hey Hermes," / "start a whiteboard").
  const wrap = (text, px, weight, max, lines = 2) => {
    for (let size = px; ; size -= 2) {
      const f = font(size, weight);
      const comma = text.indexOf(', ');
      if (lines > 1 && comma > 0 && width(text, f) > max) {
        const parts = [text.slice(0, comma + 1), text.slice(comma + 2)];
        if (parts.every((l) => width(l, f) <= max)) return [size, parts];
      }
      const out = [];
      for (const word of text.split(' ')) {
        const joined = out.length ? `${out.at(-1)} ${word}` : word;
        if (out.length && width(joined, f) <= max) out[out.length - 1] = joined;
        else out.push(word);
      }
      if ((out.length <= lines && out.every((l) => width(l, f) <= max)) || size <= 30) return [size, out];
    }
  };
  // The end of what was heard, as much as fits in two lines, cut at the front.
  const tail = (text, px, max) => {
    const f = font(px, 400);
    const words = text.replace(/^…/, '').split(' ');
    const out = [''];
    for (let i = words.length - 1; i >= 0; i -= 1) {
      const joined = out[0] ? `${words[i]} ${out[0]}` : words[i];
      if (width(`“${joined}”`, f) <= max) out[0] = joined;
      else if (out.length < 2) out.unshift(words[i]);
      else { out[0] = `…${out[0]}`; break; }
    }
    out[0] = `“${out[0]}`;
    out[out.length - 1] = `${out.at(-1)}”`;
    return out;
  };
  // The pieces from top to bottom at these sizes, each [height, draw at its top, space after].
  const layout = (big) => {
    const rows = [];
    const [titleSize] = wrap(view.title, big.title, 800, SAFE_W - big.title, 1);
    const dot = Math.round(titleSize * 0.22);
    rows.push([titleSize * 1.1, (top) => {
      const y = top + titleSize * 0.55;
      const text = width(view.title, font(titleSize, 800));
      const x = (W - text - dot * 3) / 2;
      g.beginPath();
      g.arc(x + dot, y + titleSize * 0.04, dot, 0, Math.PI * 2);
      if (view.tone === 'off') {
        g.strokeStyle = color.bad;
        g.lineWidth = Math.round(dot * 0.45);
        g.stroke();
      } else {
        g.fillStyle = view.tone === 'listening' ? color.ok : color.hermes;
        g.fill();
      }
      g.fillStyle = color.ink;
      g.font = font(titleSize, 800);
      g.textAlign = 'left';
      g.fillText(view.title, x + dot * 3, y);
      g.textAlign = 'center';
    }, big.gap]);
    if (view.caption) {
      const lines = tail(view.caption, 54, SAFE_W);
      rows.push([lines.length * 66, (top) => {
        g.fillStyle = color.ink;
        g.font = font(54, 400);
        lines.forEach((l, i) => g.fillText(l, W / 2, top + 33 + i * 66));
      }, 0]);
    } else {
      if (view.lead) {
        const [leadSize, lines] = wrap(view.lead, big.lead, 400, SAFE_W);
        rows.push([lines.length * leadSize * 1.2, (top) => {
          g.fillStyle = color.muted;
          g.font = font(leadSize, 400);
          lines.forEach((l, i) => g.fillText(l, W / 2, top + leadSize * (0.6 + i * 1.2)));
        }, big.near]);
      }
      const pad = Math.round(big.say * 0.42);
      const [saySize, lines] = wrap(view.say, big.say, 700, SAFE_W - pad * 2);
      const line = saySize * 1.18;
      rows.push([lines.length * line + pad * 1.3, (top, boxH) => {
        const boxW = Math.max(...lines.map((l) => width(l, font(saySize, 700)))) + pad * 2;
        g.fillStyle = color.hermes;
        g.beginPath();
        g.roundRect((W - boxW) / 2, top, boxW, boxH, Math.round(saySize * 0.32));
        g.fill();
        g.fillStyle = '#ffffff';
        g.font = font(saySize, 700);
        lines.forEach((l, i) => g.fillText(l, W / 2, top + pad * 0.65 + line * (i + 0.5) + saySize * 0.04));
      }, 0]);
    }
    return rows;
  };
  const height = (rows) => rows.reduce((sum, [h, , after], i) => sum + h + (i < rows.length - 1 ? after : 0), 0);
  const draw = () => {
    g.fillStyle = color.field;
    g.fillRect(0, 0, W, H);
    g.textBaseline = 'middle';
    g.textAlign = 'center';
    // Beside a board the tile is small, so it says less, bigger. `gap` follows the title; what to say keeps close to
    // the words that lead into it. All of it shrinks to fit the middle band when it would not.
    const big = view.board ? { title: 128, lead: 60, say: 104, gap: 44, near: 18 } : { title: 84, lead: 44, say: 60, gap: 36, near: 14 };
    let rows = layout(big);
    const over = SAFE_H / height(rows);
    if (over < 1) rows = layout(Object.fromEntries(Object.entries(big).map(([k, v]) => [k, Math.floor(v * over)])));
    const total = height(rows);
    let top = (H - total) / 2;
    for (const [h, paint, after] of rows) {
      paint(top, h);
      top += h + after;
    }
  };
  draw();
  // The picture is redrawn as it is (8 a second, the camera's rate), so Meet always has a frame to send to someone who
  // joins later.
  setInterval(draw, 125);
  window.hermesTile = (next) => { view = next; draw(); };

  const devices = navigator.mediaDevices;
  const getUserMedia = devices.getUserMedia.bind(devices);
  const enumerate = devices.enumerateDevices.bind(devices);
  const camera = { deviceId: 'hermes-tile', groupId: 'hermes-tile', kind: 'videoinput', label: 'Hermes',
    getCapabilities: () => ({ width: { max: W }, height: { max: H }, frameRate: { max: 8 } }),
    toJSON() { return { deviceId: this.deviceId, groupId: this.groupId, kind: this.kind, label: this.label }; } };
  devices.enumerateDevices = async () => {
    const found = await enumerate();
    return found.some((d) => d.kind === 'videoinput') ? found : [...found, camera];
  };
  devices.getUserMedia = async (asked = {}) => {
    if (!asked?.video) return getUserMedia(asked);
    const out = new MediaStream();
    if (asked.audio) for (const track of (await getUserMedia({ audio: asked.audio })).getAudioTracks()) out.addTrack(track);
    out.addTrack(stream.getVideoTracks()[0].clone());
    return out;
  };
}
