import http from 'node:http';
import fs from 'node:fs';
import { spawn } from 'node:child_process';
import { chromium } from 'playwright-core';
import { Voice } from './voice.mjs';
import { BoardLink } from './board-link.mjs';
import { Notice } from './notice.mjs';
import { Tile, tileScript } from './tile.mjs';
import { HOST_ONLY, pressPopups, SHARE_DISABLED, ShareFollow, ZOOM_POPUPS } from './zoom-ui.mjs';

const AUDIO = '/tmp/call.ogg';
const WAITING_ROOM_MS = Number(process.env.WAITING_ROOM_MS || 600000);
// The bot leaves a call it is alone in: soon after the others have gone, later when nobody has come yet.
const ALONE_MS = Number(process.env.ALONE_MS || 120000);
const NOBODY_MS = Number(process.env.NOBODY_MS || 900000);
const MAX_CALL_MS = Number(process.env.MAX_CALL_MS || 4 * 3600000);
const STUCK_MS = Number(process.env.STUCK_MS || 180000);

// `heard` holds the spoken commands, each "Hermes, <command>", which the mini reads for spoken questions. Board
// commands, spoken or typed, go straight to the call's board room (board-link.mjs), where Hermes picks them up at once.
// `near_misses` holds phrases that sounded like a board command with no name heard, and unnamed requests to start a
// board that were taken (voice.mjs), for the mini to keep with the call's record so the name rules can be tuned from real
// calls. They go nowhere else: never to the logs.
const bot = { state: 'idle', error: null, changes: [], chat: [], heard: [], near_misses: [], people: null, options: null,
  presenting: false, dismissed: {},
  sandbox: null, sandbox_error: null,
  recording: 'off', recording_since: null, recording_error: null, recording_stopped_at: null };
let voice = null;
let board = null;
let joinNotice = null;
let tile = null;
let browser, context, page, boardContext, boardPage, platform, recorder, ticker, waitingSince, aloneSince, inCallSince, lostSince, othersSeen = false;
// The whiteboard's window title. Chrome shares the window or tab with this title when the call asks what to present.
const BOARD_TITLE = 'Hermes whiteboard';
// A request to start a board, while it is still being said: the board goes on screen while Hermes works on it.
// A board by its template's name counts too ("start an agenda", "open a decision log"), as in the mini's NAMED.
const STARTING_BOARD = /\b(?:start|new|open|make|create|begin|bring up|pull up)\b.{0,30}\b(?:white\s*board|board|agenda|decision\s+log|action\s+items|to-?do\s+list|pros\s+and\s+cons|timeline|retro(?:spective)?)\b/i;
// A board shared on such a request with no board made after all is taken down after this long.
const UNUSED_SHARE_MS = 25000;
const LOST_MS = Number(process.env.LOST_MS || 120000);

function setState(state, error = null) {
  if (bot.state === state) return;
  // A call that has ended stays ended: a tick still running as the bot left must not put it back in the call.
  if (bot.state === 'ended' || bot.state === 'failed') return;
  bot.state = state;
  bot.error = error;
  bot.changes.push({ state, error, at: new Date().toISOString() });
  console.log('state', state, error || '');
}

const visible = (locator) => locator.isVisible().catch(() => false);

// The bot's Google account and Deepgram key come in the start request (`secrets`) and live only in this process's
// memory: no environment variable holds them, so Chrome, ffmpeg and the start script never inherit them, and the
// password is dropped as soon as the bot has signed in.
let secrets = {};

async function start({ secrets: given, ...options }) {
  secrets = { ...given };
  bot.options = options;
  platform = isZoom(options.meeting_url) ? zoom : meet;
  // Whether spoken commands can be heard goes to the board room as it changes and on every new line, and its status bar
  // says "Not listening, type in chat" while they cannot (also in a call started without them).
  // In Meet, the bot's camera is a tile that says Hermes is listening and shows what it hears (tile.mjs).
  if (options.voice && platform === meet && options.tile !== false) {
    tile = new Tile((view) => page?.evaluate((shown) => window.hermesTile?.(shown), view).catch(() => {}));
  }
  if (options.voice) {
    voice = new Voice({ key: secrets.deepgram_api_key, onCommand: hear, onHearing: hearing,
      onListening: (on) => {
        board?.send({ t: 'listening', on });
        tile?.listening(on);
      },
      onWords: (text) => tile?.words(text), onNearMiss: nearMiss,
      // An unnamed request to start a board counts only while none is up. Not while the share is starting: hearing the
      // request starts it (hearing, below), before the request has finished.
      canStart: () => Boolean(board) && !board.room.current });
  }
  if (options.board?.socket) {
    board = new BoardLink({ ...options.board, onRoom: followRoom,
      current: () => [{ t: 'listening', on: voice ? voice.listening() : false }] });
  }
  joinNotice = new Notice({ text: options.notice, say: (text) => platform.say(text), shown: () => platform.chatWords(),
    pin: platform.pin });
  setState('joining');
  browser = await launch({
    executablePath: '/usr/bin/google-chrome',
    headless: false,
    ignoreDefaultArgs: ['--mute-audio', '--enable-automation'],
    // No --use-fake-ui-for-media-stream: the context grants the microphone and camera, and that flag makes Chrome
    // share the whole screen (which fails here) instead of the whiteboard tab picked by its title.
    args: ['--disable-blink-features=AutomationControlled', '--no-first-run',
      '--no-default-browser-check', '--disable-dev-shm-usage', '--autoplay-policy=no-user-gesture-required',
      '--window-size=1280,720', '--window-position=0,0',
      `--auto-select-desktop-capture-source=${BOARD_TITLE}`, `--auto-select-tab-capture-source-by-title=${BOARD_TITLE}`],
  });
  context = await browser.newContext({ viewport: { width: 1280, height: 720 }, permissions: ['microphone', 'camera'] });
  if (tile) await context.addInitScript(tileScript, { fonts: await tileFonts() });
  if (options.cookies_file) {
    const sameSite = { Strict: 'Strict', Lax: 'Lax', None: 'None' };
    const cookies = JSON.parse(fs.readFileSync(options.cookies_file, 'utf8')).map((c) => ({
      name: c.name, value: c.value, domain: c.domain, path: c.path, expires: c.expires > 0 ? c.expires : -1,
      httpOnly: c.httpOnly, secure: c.secure, sameSite: sameSite[c.sameSite] || 'Lax',
    }));
    await context.addCookies(cookies);
  }
  page = await context.newPage();
  await signIn();
  await platform.join(options);
  waitingSince = Date.now();
  // One tick at a time: a slow one (leaving, reading chat) must not overlap the next. A page that has not
  // answered a tick for STUCK_MS is stuck (page calls have no timeout), so end the call and keep what was recorded.
  let ticking = false;
  let goodTick = Date.now();
  ticker = setInterval(async () => {
    if (Date.now() - goodTick > STUCK_MS) return finish('failed', 'browser_stuck');
    if (ticking) return;
    ticking = true;
    try {
      await tick();
      goodTick = Date.now();
      bot.tick_at = new Date(goodTick).toISOString();
    } catch (e) {
      console.log('tick', e.message);
    }
    ticking = false;
  }, 1000);
}

// Chrome with its own sandbox where the machine allows one, so a page that breaks into Chrome is still kept from the
// rest of the container. Only Chrome saying the sandbox cannot run makes it run without (and `/status` says so:
// `sandbox`, `sandbox_error`); any other failure to start is tried again with the sandbox.
async function launch(settings, tries = 2) {
  for (let tried = 1; ; tried += 1) {
    try {
      const launched = await chromium.launch({ ...settings, chromiumSandbox: true });
      bot.sandbox = true;
      return launched;
    } catch (error) {
      const refused = error.message.split('\n').find((line) => /sandbox/i.test(line));
      if (refused) {
        bot.sandbox = false;
        bot.sandbox_error = refused.trim().slice(0, 300);
        return chromium.launch(settings);
      }
      if (tried >= tries) throw error;
      await new Promise((done) => setTimeout(done, 2000));
    }
  }
}

// Signs the bot's own Google account in, so Meet lets it in as a named user (Meet turns away anonymous guests
// from this browser). A new Workspace user first gets a welcome page to accept.
async function signIn() {
  const { google_email: email, google_password: password } = secrets;
  delete secrets.google_password;
  if (!email || !password) return;
  setState('signing_in');
  await page.goto('https://accounts.google.com/ServiceLogin?hl=en&continue=https://meet.google.com/', { waitUntil: 'domcontentloaded' });
  await page.getByRole('textbox', { name: /email or phone/i }).fill(email);
  await page.keyboard.press('Enter');
  const field = page.locator('input[type=password]:visible');
  await field.waitFor({ timeout: 30000 });
  await field.fill(password);
  await page.keyboard.press('Enter');
  const deadline = Date.now() + 60000;
  while (Date.now() < deadline) {
    if (page.url().startsWith('https://meet.google.com')) return setState('joining');
    const accept = page.getByRole('button', { name: /^(i understand|accept|not now|skip)$/i }).first();
    if (await visible(accept)) await accept.click().catch(() => {});
    await page.waitForTimeout(1000);
  }
  throw new Error(`sign-in stuck at ${page.url().split('?')[0]}`);
}

async function tick() {
  if (!page || page.isClosed()) return;
  // Zoom shows its "ended by host" notice over a call whose controls are still on the page, so this comes first.
  const over = await platform.over();
  if (over) return over === 'ended' ? finish('ended') : finish('failed', over);
  await platform.dismiss?.();
  // In the call before reading the page text: that text then includes the chat, where anyone can type anything.
  if (await platform.inCall()) {
    lostSince = null;
    if (bot.state !== 'in_call') {
      setState('in_call');
      inCallSince = Date.now();
      board?.connect();
    }
    // Everyone is told in the chat that the call is recorded before the bot records, listens or keeps the chat; until
    // the notice shows in the chat it does none of those (notice.mjs).
    if (!joinNotice.posted && await joinNotice.step()) {
      console.log('notice posted');
      record();
      tile?.ready();
      // The board tab loads now, unseen, so the first request for a board is shown at once. Not before the notice:
      // nobody can ask for a board until the bot listens, and the notice is what the bot's one CPU needs first.
      if (board) openBoard().catch((e) => console.log('board tab', e.message));
    }
    await joinNotice.pinStep();
    if (tile && joinNotice.posted) await sharpenTile();
    const told = joinNotice.posted;
    // A host can turn chat off, which must not stop the call: only a tick that fails counts toward being stuck.
    if (bot.options.chat && told) await platform.readChat().catch((e) => console.log('chat', e.message.split('\n')[0]));
    await checkAlone();
    await takeDownUnusedShare();
    tile?.update();
    return voice?.update({ inCall: told, alone: bot.people === 1 });
  }
  // A call whose controls stay gone with no notice saying why was lost (the waiting room limit is for joining).
  if (bot.state === 'in_call') {
    voice?.update({ inCall: false });
    lostSince ??= Date.now();
    if (Date.now() - lostSince > LOST_MS) await finish('failed', 'lost_call');
    return;
  }
  const text = await platform.text().catch(() => '');
  const refused = platform.refused(text);
  if (refused) return finish('failed', refused);
  if (bot.state === 'joining' && platform.waiting.test(text)) setState('waiting_room');
  if (Date.now() - waitingSince > WAITING_ROOM_MS) await finish('failed', 'waiting_room_timeout');
}

// Meet sends the camera of a machine with one CPU (the bot's) at a third of its size and at most 256 kbit/s, so the
// tile reached the others at 320 by 320 pixels and blurred; with Meet's own "Send resolution" set to the highest it
// offers, the whole 960 by 960 went through (test calls, 2026-11-21). Meet keeps that choice in the browser, which is
// new each call, so the bot picks it before it asks to join, and the call gets the sharp tile from its first frame. A
// miss there is tried again in the call once the notice is up: Meet's offers and tips can cover its menu for the first
// moments of a call (a test call, 2026-11-21), so 5 s apart, six tries in all; after that the tile stays as Meet sends
// it. `/status` shows the choice as `tile_resolution`.
let sharpenTries = 0;
let sharpenAt = 0;
async function sharpenTile() {
  if (bot.tile_resolution || sharpenTries >= 6 || Date.now() < sharpenAt || !platform.sendResolution) return;
  sharpenTries += 1;
  try {
    bot.tile_resolution = await within(20000, platform.sendResolution());
    console.log('tile sends', bot.tile_resolution);
  } catch (error) {
    sharpenAt = Date.now() + 5000;
    console.log('tile resolution', error.message.split('\n')[0]);
  }
}

async function checkAlone() {
  const now = Date.now();
  if (now - inCallSince > MAX_CALL_MS) return leave('max_duration');
  const count = await platform.peopleCount();
  bot.people = count;
  if (count === null) return;
  if (count > 1) {
    othersSeen = true;
    aloneSince = null;
    return;
  }
  aloneSince ??= now;
  if (now - aloneSince > (othersSeen ? ALONE_MS : NOBODY_MS)) {
    console.log('alone, leaving');
    await leave(othersSeen ? 'everyone_left' : 'nobody_came');
  }
}

// A spoken command, kept for the mini to read and sent to the board room. Only commands are kept, never the rest of
// what was said.
function hear({ id, command, direct, continues }) {
  const text = `Hermes, ${command}`;
  // `continues`: the id of the command this phrase carries on (voice.mjs), which the board room passes to Hermes.
  const carried = continues ? { continues } : {};
  bot.heard.push({ id, text, direct, ...carried, at: new Date().toISOString() });
  bot.heard.splice(0, bot.heard.length - 50);
  board?.send({ t: 'command', id, text, source: 'voice', direct, ...carried });
  console.log('voice command heard', command.length, 'chars');
}

// Near misses for the mini (`near_misses`), kept for the call only: the last NEAR_KEPT, each cut to NEAR_CHARS.
const NEAR_KEPT = 50;
const NEAR_CHARS = 200;
const nearPrefix = `n${Date.now().toString(36)}.`;
let nearCount = 0;
function nearMiss(miss) {
  nearCount += 1;
  bot.near_misses.push({ id: `${nearPrefix}${nearCount}`, text: miss.text.slice(0, NEAR_CHARS),
    ...(miss.started ? { started: true } : {}), at: new Date().toISOString() });
  bot.near_misses.splice(0, bot.near_misses.length - NEAR_KEPT);
  tile?.nearMiss(miss);
}

// The board's font for the tile, read once from the same place the board page loads it; the tile uses the system font
// if it cannot be had in a few seconds.
const TILE_FONT = 'https://cdn.jsdelivr.net/npm/@fontsource/atkinson-hyperlegible-next@5.2.7/files/atkinson-hyperlegible-next-latin';
async function tileFonts() {
  const weights = [400, 700, 800];
  const fonts = await Promise.all(weights.map(async (weight) => {
    try {
      const answer = await fetch(`${TILE_FONT}-${weight}-normal.woff2`, { signal: AbortSignal.timeout(5000) });
      return answer.ok ? { weight, data: Buffer.from(await answer.arrayBuffer()).toString('base64') } : null;
    } catch {
      return null;
    }
  }));
  return fonts.filter(Boolean);
}

// A typed command's id is its chat message's id, which the board room takes as the command's own for the call. Meet's
// are 45 characters and differ only at the end ("spaces/…/messages/1795251496033983", a time in microseconds), and the
// room keeps 40: the end is kept, so two commands typed seconds apart never share one.
const chatId = (id) => `c:${String(id).slice(-38)}`;

// A command while it is still being said: its words go on the board's caption strip, and a request to start a board
// puts the board on screen before the speaker has finished.
function hearing({ id, command }) {
  if (!board) return;
  board.send({ t: 'hearing', id, text: command });
  if (STARTING_BOARD.test(command) && !bot.presenting && !board.room.current) {
    shareUnasked = Date.now();
    presentBoard().catch(() => {});
  }
}

// The call's audio, written as it is heard; the mini copies what is new every few seconds (GET /audio?from=). A recorder
// that stops while the bot is still in the call is not started again (it would start a new file): `/status` says so
// (`recording`, `recording_error`), and the mini tells the owner.
function record() {
  recorder = spawn('ffmpeg', ['-nostdin', '-hide_banner', '-loglevel', 'error', '-y', '-f', 'pulse', '-i', 'meet.monitor',
    '-ac', '1', '-ar', '16000', '-c:a', 'libopus', '-b:a', '24k', '-flush_packets', '1', AUDIO], { stdio: ['ignore', 'inherit', 'inherit'] });
  bot.recording = 'on';
  bot.recording_since = new Date().toISOString();
  const stopped = (why) => {
    if (finishing || bot.recording !== 'on') return;
    bot.recording = 'stopped';
    bot.recording_error = why;
    bot.recording_stopped_at = new Date().toISOString();
    console.log('recorder', why);
  };
  recorder.once('exit', (code, signal) => stopped(signal ? `the recorder was stopped (${signal})` : `the recorder exited (${code})`));
  recorder.once('error', (error) => stopped(`the recorder failed: ${error.message}`));
}

// Ending can be asked for from a tick and from a request at the same time; it runs once.
let finishing;
function finish(state, error = null) {
  finishing ??= wrapUp(state, error);
  return finishing;
}

const within = (ms, promise) => Promise.race([promise, new Promise((_, fail) => setTimeout(() => fail(new Error('timeout')), ms))]);

async function wrapUp(state, error) {
  clearInterval(ticker);
  // Before the state changes, so the mini's last look at the call sees every second streamed.
  voice?.stop();
  board?.close();
  if (recorder && recorder.exitCode === null && recorder.signalCode === null) {
    const exited = new Promise((done) => recorder.once('exit', done));
    recorder.kill('SIGINT');
    await within(10000, exited).catch(() => recorder.kill('SIGKILL'));
  }
  // A stuck page can hang any call into it, so these get a time limit.
  bot.last_text = await within(5000, Promise.resolve(platform?.text())).catch(() => null);
  await within(20000, drawChanged()).catch(() => {});
  setState(state, error);
  if (!process.env.KEEP_BROWSER) await within(10000, browser?.close()).catch(() => {});
}

// How long the recap stays on screen before the bot hangs up, while people are still in the call.
const RECAP_SHOWN_MS = 4000;

async function leave(reason = null) {
  // The recap board (action items, decisions, open risks) goes up as the bot leaves, and into the notes; with people
  // still there, it stays on screen a moment, and Hermes says it in the chat when chat replies are on.
  if (board && bot.state === 'in_call') {
    const made = await board.recap().catch(() => null);
    if (made?.ok && reason !== 'everyone_left' && reason !== 'nobody_came') {
      await new Promise((done) => setTimeout(done, RECAP_SHOWN_MS));
    }
  }
  await Promise.resolve(platform?.hangUp()).catch(() => {});
  await finish('ended', reason);
}

// Google Meet. The bot signs in with its Google account and asks to join like any named guest.
const meet = {
  waiting: /asking to be let in|wait until a meeting host|when someone lets you in|brings you into the call/i,

  async join(options) {
    await page.goto(options.meeting_url, { waitUntil: 'domcontentloaded' });
    const name = page.getByRole('textbox', { name: /your name/i });
    await name.waitFor({ timeout: 30000 }).catch(() => {});
    if (await visible(name)) await name.fill(options.bot_name);
    // With the tile the camera stays on (and is turned on if Meet remembered it off); without it, it goes off.
    const camera = tile ? [] : [/turn off camera/i];
    const press = [...(options.speaker ? [] : [/turn off microphone/i]), ...camera, ...(tile ? [/turn on camera/i] : [])];
    for (const label of press) {
      const button = page.getByRole('button', { name: label }).first();
      if (await visible(button)) await button.click().catch(() => {});
    }
    const gotIt = page.getByRole('button', { name: /^got it$/i }).first();
    if (await visible(gotIt)) await gotIt.click().catch(() => {});
    if (tile) await sharpenTile();
    const deadline = Date.now() + 30000;
    while (Date.now() < deadline) {
      const direct = page.getByRole('button', { name: /ask to join|join now|join anyway/i }).first();
      if (await visible(direct)) return direct.click();
      const other = page.getByRole('button', { name: /other ways to join/i }).first();
      if (await visible(page.getByText(/^switch here$/i).first()) && await visible(other)) {
        await other.click();
        return page.getByText(/join here too/i).first().click({ timeout: 5000 });
      }
      await page.waitForTimeout(500);
    }
    throw new Error('no join button');
  },

  // Meet's tips cover the call and hide its controls from the page's buttons until closed: with the bot's camera on
  // (the tile), "Others may see your video differently" comes up as the board goes on screen, and a bot that left it
  // took the call for lost and left 2 minutes later (a test call, 2026-11-21).
  async dismiss() {
    const button = page.getByRole('button', { name: /^got it$/i }).first();
    if (await visible(button)) await button.click({ timeout: 5000 }).catch(() => {});
  },

  // Settings > Video > Send resolution (maximum), set to the most pixels on offer (1080p, or 720p on an account without
  // it). The settings cover the call's controls while open, which would read as a lost call, so they are always closed.
  async sendResolution() {
    try {
      await page.getByRole('button', { name: /^more options$/i }).last().click({ timeout: 5000 });
      await page.getByRole('menuitem', { name: /^settings$/i }).click({ timeout: 5000 });
      await page.getByRole('tab', { name: /video/i }).click({ timeout: 5000 });
      const box = page.getByRole('combobox', { name: /send resolution/i });
      await box.click({ timeout: 5000 });
      const options = page.getByRole('listbox', { name: /send resolution/i }).getByRole('option');
      const names = await options.allInnerTexts();
      const lines = (name) => Number(name.match(/\((\d+)p\)/)?.[1] || 0);
      const best = names.reduce((a, b) => (lines(b) > lines(a) ? b : a), '');
      if (!lines(best)) throw new Error(`no resolution offered (${names.join(', ')})`);
      await options.filter({ hasText: best.trim() }).first().click({ timeout: 5000 });
      return (await box.innerText()).trim();
    } finally {
      const close = page.getByRole('button', { name: /^close dialog$/i }).first();
      if (await visible(close)) await close.click({ timeout: 5000 }).catch(() => {});
      else await page.keyboard.press('Escape').catch(() => {});
    }
  },

  // Meet shows Leave call in its waiting room too, under a notice that the bot is waiting to be let in. The
  // notice is looked for outside the chat, where anyone could type the same words.
  async inCall() {
    if (!await visible(page.getByRole('button', { name: /leave call/i }).first())) return false;
    return !await page.evaluate((source) => {
      const waiting = new RegExp(source, 'i');
      // The innermost element holding the words, which can also hold an icon.
      return [...document.querySelectorAll('div, span')].some((el) => waiting.test(el.textContent)
        && ![...el.children].some((child) => waiting.test(child.textContent))
        && !el.closest('[data-message-id]') && el.offsetParent !== null);
    }, meet.waiting.source);
  },

  text: () => page.evaluate(() => document.body.innerText),

  async over() {
    return await visible(page.getByRole('button', { name: /^(rejoin|return to home screen)$/i }).first()) ? 'ended' : null;
  },

  refused(text) {
    return /denied your request|can.t join this call|been removed from the meeting|removed you from the meeting/i.test(text) ? 'denied' : null;
  },

  // The number on Meet's People button counts everyone in the call, the bot included.
  peopleCount() {
    return page.evaluate(() => {
      for (const el of document.querySelectorAll('[role=button][aria-labelledby]')) {
        const label = el.getAttribute('aria-labelledby').split(' ')
          .map((id) => document.getElementById(id)?.textContent || '').join(' ').trim();
        if (/^people$/i.test(label)) {
          const count = parseInt(el.innerText, 10);
          return Number.isFinite(count) ? count : null;
        }
      }
      return null;
    });
  },

  async openChat() {
    const box = page.getByRole('textbox', { name: /send a message/i });
    if (await visible(box)) return box;
    await page.getByRole('button', { name: /chat with everyone/i }).first().click();
    await box.waitFor({ timeout: 10000 });
    return box;
  },

  // Meet adds chat messages to the page only while the chat panel is open. Each message is a div with a
  // data-message-id; two levels up, its group starts with the sender's name, or with the time for the bot's own.
  async messages() {
    await meet.openChat();
    return page.evaluate(() => [...document.querySelectorAll('div[data-message-id]')].map((el) => {
      const group = el.parentElement?.parentElement;
      const first = (group?.innerText || '').split('\n')[0].trim();
      const body = (el.firstElementChild || el).innerText || '';
      return { id: el.getAttribute('data-message-id'), sender: first, own: /^\d{1,2}:\d{2}/.test(first), body };
    }));
  },

  readChat: async () => keepChat(await meet.messages(),
    /^(hover over a message to pin it|pin message|unpin message|pinned|keep|keep_off)$/i),

  chatWords: async () => (await meet.messages()).map((m) => m.body),

  async say(message) {
    const box = await meet.openChat();
    await box.fill(message);
    await box.press('Enter');
  },

  // A message's pin button shows while the pointer is over it, and Meet asks once more before it pins. A panel Meet
  // opens by itself (it offers its own note taker) can cover the chat, and a click beside the call closes it. A try
  // that pinned but missed seeing it leaves the message pinned, which the next try sees.
  async pin(text) {
    await page.mouse.click(4, 360);
    await meet.openChat();
    const message = page.locator('div[data-message-id]').filter({ hasText: text.slice(0, 40) }).last();
    // "Pinned" shows under the message, after its pin icon (whose text, "keep", runs into it).
    const pinned = message.getByText('Pinned').first();
    if (await visible(pinned)) return;
    await message.hover({ timeout: 5000 });
    await message.getByRole('button', { name: /^pin message$/i }).click({ timeout: 5000 });
    const sure = page.getByRole('button', { name: /^pin this message$/i }).first();
    if (await sure.waitFor({ timeout: 3000 }).then(() => true, () => false)) await sure.click();
    await pinned.waitFor({ timeout: 5000 });
  },

  hangUp: () => page.getByRole('button', { name: /leave call/i }).first().click(),

  // Meet's share button asks Chrome what to share, and Chrome picks the whiteboard by its title (see BOARD_TITLE).
  async present() {
    if (await meet.presenting()) return;
    await page.getByRole('button', { name: /^(share screen|present now)$/i }).first().click({ timeout: 10000 });
    const deadline = Date.now() + 20000;
    while (Date.now() < deadline) {
      if (await meet.presenting()) return;
      // A host can keep sharing to hosts only.
      if (await visible(page.getByText(/host.{0,40}(turned off|doesn.t allow|not allowed).{0,40}(shar|present)/i).first())) {
        throw new Error('the host does not let guests present');
      }
      await page.waitForTimeout(500);
    }
    throw new Error('Meet did not start presenting');
  },

  // Meet's tip "Others may see your video differently" comes up as the share starts and marks the whole call aria-hidden,
  // which hides Stop presenting from a plain getByRole while it is still on screen and the board is already shared behind
  // the tip. On the bot's one CPU the tip stayed up past the 20 s a share may take, so a share that worked was taken for
  // failed and the owner was texted that the board could not be shown (test calls, 2026-11-21). So the button is looked
  // for among hidden ones too, by its whole name (its icon's word, then its own), which no other button can pass for.
  presenting: () => visible(meet.stopButton()),

  stopButton: () => page.getByRole('button', { name: /^(cancel_presentation\s+)?stop presenting$/i, includeHidden: true }).first(),

  async stopPresenting() {
    await meet.dismiss();
    const stop = meet.stopButton();
    if (await visible(stop)) await stop.click();
  },
};

const isZoom = (url) => /^https:\/\/([a-z0-9-]+\.)*zoom\.us\//i.test(url || '');

// Zoom's web client on app.zoom.us, from a link's meeting number and passcode. A personal link or a company
// subdomain carries the same number after /j/.
function zoomWebUrl(link) {
  const url = new URL(link);
  const id = url.pathname.match(/\/(?:j|w|wc(?:\/join)?)\/(\d{9,12})(?:\/|$)/)?.[1];
  if (!id) throw new Error('no Zoom meeting number in the link');
  const pwd = url.searchParams.get('pwd');
  return `https://app.zoom.us/wc/${id}/join?fromPWA=1${pwd ? `&pwd=${encodeURIComponent(pwd)}` : ''}`;
}

// Zoom's web client draws the meeting in an iframe, which comes and goes as the page moves between steps.
async function zoomFrame() {
  const element = await page.$('iframe#webclient').catch(() => null);
  return (element && await element.contentFrame().catch(() => null)) || page.mainFrame();
}

// Zoom's toolbar hides itself and its popovers cover other controls, so the bot presses Zoom's buttons through
// the page instead of with the mouse. Matches a button's label or its text.
async function zoomPress(pattern) {
  const frame = await zoomFrame();
  return frame.evaluate((source) => {
    const match = new RegExp(source, 'i');
    const button = [...document.querySelectorAll('button')]
      .find((b) => match.test((b.getAttribute('aria-label') || '').trim()) || match.test(b.innerText.trim()));
    button?.click();
    return Boolean(button);
  }, pattern.source);
}

// Zoom's chat panel and its Share button fight for the toolbar, so reading or writing the chat and starting a share
// take turns: each starts only once the one before has finished. Each bounds its own steps; a page that stops
// answering altogether is the stuck-browser check's to end.
let zoomTurn = Promise.resolve();
function zoomInTurn(work) {
  const run = zoomTurn.then(work);
  zoomTurn = run.catch(() => {});
  return run;
}

// Like zoomPress, but only a button on screen counts: Zoom keeps hidden copies of some buttons on the page.
async function zoomPressShown(pattern) {
  const frame = await zoomFrame();
  return frame.evaluate((source) => {
    const match = new RegExp(source, 'i');
    const button = [...document.querySelectorAll('button')].find((b) => b.getClientRects().length > 0
      && (match.test((b.getAttribute('aria-label') || '').trim()) || match.test(b.innerText.trim())));
    button?.click();
    return Boolean(button);
  }, pattern.source);
}

// Zoom turns away a scripted browser as a bot unless it is signed in, so the bot also signs in to Zoom, with
// "Sign in with Google" for the Google account it is already signed in to.
async function zoomSignIn() {
  // The Google account comes in the start request with the rest of `secrets`, not in the environment (since #57); reading
  // the environment here left Zoom unsigned, and Zoom turned the bot away as a bot ("bot_blocked", seen in a rehearsal
  // call on 2026-11-21).
  const email = secrets.google_email;
  if (!email) return;
  setState('signing_in');
  await page.goto('https://zoom.us/google_oauth_signin', { waitUntil: 'domcontentloaded' });
  const deadline = Date.now() + 90000;
  while (Date.now() < deadline) {
    const url = new URL(page.url());
    if (/(^|\.)zoom\.us$/.test(url.hostname) && !/signin|oauth/i.test(url.pathname)) return setState('joining');
    const account = page.getByText(email, { exact: true }).first();
    if (await visible(account)) await account.click().catch(() => {});
    const allow = page.getByRole('button', { name: /^(continue|allow)$/i }).first();
    if (await visible(allow)) await allow.click().catch(() => {});
    await page.waitForTimeout(1000);
  }
  throw new Error(`zoom sign-in stuck at ${page.url().split('?')[0]}`);
}

// Zoom's popups are looked for this often: each look reads the buttons of the whole page, on the bot's one CPU.
const POPUPS_MS = 3000;
let popupsAt = 0;
// Words as Zoom's chat box holds them: spaces and line breaks run together, and either kind of apostrophe.
const squash = (text) => String(text || '').replace(/[’‘]/g, "'").replace(/\s+/g, ' ').trim();

const zoom = {
  waiting: /waiting for the host|let you in soon|waiting room|host has joined|meeting has not started/i,

  async join(options) {
    await zoomSignIn();
    await page.goto(zoomWebUrl(options.meeting_url), { waitUntil: 'domcontentloaded' });
    // The web client loads slowly on the bot service's one CPU; 30 seconds is common there.
    const deadline = Date.now() + 120000;
    while (Date.now() < deadline) {
      if (await zoom.inCall()) return;
      // Zoom can refuse before its join form appears (a bad link, or the bot check); say why instead of timing out.
      const refused = zoom.refused(await zoom.text().catch(() => ''));
      if (refused) throw Object.assign(new Error(refused), { reason: refused });
      const frame = await zoomFrame();
      const name = frame.locator('#input-for-name');
      if (await visible(name)) {
        // Signed in, Zoom fills in the account's own name; a guest's empty field gets the bot's.
        if (!await name.inputValue().catch(() => '')) await name.fill(options.bot_name || 'Notetaker');
        if (!options.speaker) await zoomPress(/^mute$/);
        if (await zoomPress(/^join$/)) return;
      }
      await page.waitForTimeout(500);
    }
    throw new Error('no join button');
  },

  // A guest's button says Leave; the host's says End. Zoom makes the bot host when the host leaves first.
  async inCall() {
    const frame = await zoomFrame();
    const inCall = await frame.evaluate(() => Boolean(document.querySelector('button[aria-label="Leave"], button[aria-label="End"]')))
      .catch(() => false);
    // Zoom normally joins computer audio by itself; when it asks instead, the bot accepts so it can hear the call.
    if (inCall) await zoomPress(/^join audio by computer$/).catch(() => {});
    return inCall;
  },

  text: async () => (await zoomFrame()).evaluate(() => document.body.innerText),

  async over() {
    const frame = await zoomFrame();
    const notice = await frame.evaluate(() => [...document.querySelectorAll('.zm-modal-body-title')]
      .map((el) => el.innerText).join(' ')).catch(() => '');
    if (/removed/i.test(notice)) return 'denied';
    if (/ended/i.test(notice)) return 'ended';
    // Leaving without a notice sends the page back to the web client's home.
    if (bot.state === 'in_call' && !/\/wc\/\d+\//.test(page.url())) return 'ended';
    return null;
  },

  refused(text) {
    if (/automated bots aren.t allowed/i.test(text)) return 'bot_blocked';
    if (/passcode wrong|incorrect passcode|invalid meeting id|meeting id is not valid|link is invalid|meeting does not exist/i.test(text)) return 'bad_link';
    if (/authorized attendees only|not allowed to join|removed you|been removed|denied/i.test(text)) return 'denied';
    return null;
  },

  // The Participants button reads "2 Participants" and counts everyone, the bot included.
  async peopleCount() {
    const frame = await zoomFrame();
    return frame.evaluate(() => {
      const button = [...document.querySelectorAll('button')]
        .find((b) => /participants list pane/i.test(b.getAttribute('aria-label') || ''));
      const count = parseInt(button?.innerText || '', 10);
      return Number.isFinite(count) ? count : null;
    });
  },

  async openChat() {
    const frame = await zoomFrame();
    const editor = frame.locator('div.tiptap.ProseMirror').first();
    if (!await visible(editor)) {
      await zoomPress(/^open the chat panel$/);
      await editor.waitFor({ timeout: 10000 });
    }
    return editor;
  },

  // Zoom keeps chat messages on the page only while the chat panel is open. Each message's container is labeled
  // "<sender> to Everyone, <time>, <text>", with "You" for the bot's own; its text box has an id unique to the message.
  messages: () => zoomInTurn(async () => {
    await zoom.openChat();
    const frame = await zoomFrame();
    return frame.evaluate(() => [...document.querySelectorAll('div.new-chat-message__container')].map((el) => {
      const box = el.querySelector('.new-chat-message__text-box');
      const sender = (el.getAttribute('aria-label') || '').split(' to ')[0].trim();
      return { id: box?.id || el.id, sender, own: sender === 'You', body: box?.innerText || '' };
    }));
  }),

  readChat: async () => keepChat(await zoom.messages()),

  chatWords: async () => (await zoom.messages()).map((m) => m.body),

  // The words go in at once: typed key by key, the notice took 20 s and more on the bot's one CPU, and the bot listens
  // only once the notice is in the chat (a test call, 2026-11-22). The box is focused, not clicked, so a popup over the
  // chat cannot hold the click until it times out. A box that did not take the words gets them typed, as before.
  say: (message) => zoomInTurn(async () => {
    const editor = await zoom.openChat();
    await editor.focus();
    await page.keyboard.insertText(message);
    if (squash(await editor.innerText().catch(() => '')) !== squash(message)) {
      await editor.click();
      await page.keyboard.press('Control+A');
      await page.keyboard.press('Backspace');
      await page.keyboard.type(message);
    }
    await page.keyboard.press('Enter');
  }),

  // As host the bot ends the meeting when nobody else is left, and otherwise hands the host role to someone
  // still there, which Zoom asks for before it lets a host leave.
  async hangUp() {
    await zoomPress(/^(leave|end)$/);
    await page.waitForTimeout(1000);
    if (bot.people !== null && bot.people <= 1 && await zoomPress(/^end meeting for all$/)) return;
    await zoomPress(/^leave meeting$/);
    await page.waitForTimeout(1000);
    const frame = await zoomFrame();
    const someone = frame.locator('.assign-new-host-participant-item').first();
    if (await visible(someone)) {
      await someone.click().catch(() => {});
      await zoomPress(/^assign and leave$/);
    }
  },

  // Takes its turn with the chat, so reading the chat cannot open the panel again and hide Share meanwhile. The time
  // spent waiting for its turn counts toward its 25 s, so it gives up before the caller's 30 s and never starts a
  // share after the caller has been told it failed.
  present() {
    const deadline = Date.now() + 25000;
    return zoomInTurn(() => zoom.startShare(deadline));
  },

  async startShare(deadline) {
    const late = () => Date.now() > deadline;
    if (late()) throw new Error('Zoom was busy');
    if (await zoom.presenting()) return;
    // With the chat panel open, Zoom's toolbar is too narrow for Share and tucks it into its More menu (and can hide
    // a running share's Stop Share the same way), so the bot closes the chat first; reading the chat opens it again.
    if (!await zoomPressShown(/^share( screen)?$/)) {
      await zoomPress(/^close the chat panel$/);
      await page.waitForTimeout(500);
      if (await zoom.presenting()) return;
      if (late()) throw new Error('Zoom was busy');
      if (!await zoomPressShown(/^share( screen)?$/)) throw new Error('Zoom has no share button');
    }
    // From here a share can still start after the bot stops waiting for it (presentBoard).
    sharePressed = true;
    do {
      if (await zoom.presenting()) return;
      // A host who lets only the host share: Zoom says so in a dialog, which the bot closes at once (left open, it
      // stayed over the call after the host let everyone share, a real call on 2026-11-22).
      if ((await zoom.press(SHARE_DISABLED)).length) throw Object.assign(new Error(HOST_ONLY), { refused: true });
      await page.waitForTimeout(500);
    } while (!late());
    // Share was pressed: one last look, so a share that started at the deadline is reported as started (the caller
    // waits 5 s longer than the deadline).
    if (await zoom.presenting()) return;
    throw new Error('Zoom did not start sharing');
  },

  // Presses the closing button of each of `popups` on screen (zoom-ui.mjs); returns the names of those it closed, and
  // counts each in `/status` as `dismissed`.
  async press(popups) {
    const frame = await zoomFrame();
    const pressed = await frame.evaluate(pressPopups, popups).catch(() => []);
    for (const name of pressed) bot.dismissed[name] = (bot.dismissed[name] || 0) + 1;
    return pressed;
  },

  // Zoom's tips and notices over the call (zoom-ui.mjs), looked for every few seconds. The host's refusal of a share is
  // the share's own to close and report (startShare), then the share check's (followShare); one left over after that
  // is closed here.
  async dismiss() {
    if (Date.now() - popupsAt < POPUPS_MS) return;
    popupsAt = Date.now();
    const settled = !presentAsked && shareFollow.pending === null;
    await zoom.press(settled ? [...ZOOM_POPUPS, ...SHARE_DISABLED] : ZOOM_POPUPS);
  },

  // A host's refusal of a share the bot stopped waiting for, closed: true when there was one.
  shareRefused: async () => (await zoom.press(SHARE_DISABLED)).length > 0,

  // Someone else's share on screen: the bot never tries again to share over it.
  async othersSharing() {
    const frame = await zoomFrame();
    return frame.evaluate(() => [...document.querySelectorAll('#sharee-container, .sharee-container')]
      .some((el) => el.getClientRects().length > 0)).catch(() => true);
  },

  // Zoom keeps a hidden Stop Share button on the page even when nobody shares, so only a shown one counts.
  async presenting() {
    const frame = await zoomFrame();
    return frame.evaluate(() => [...document.querySelectorAll('button')]
      .some((b) => b.getClientRects().length > 0
        && /^stop shar(e|ing)$/i.test((b.getAttribute('aria-label') || b.innerText || '').trim()))).catch(() => false);
  },

  // Presses the shown Stop Share button, not one of Zoom's hidden copies.
  stopPresenting: () => zoomPressShown(/^stop shar(e|ing)$/),
};

// Adds the messages not seen before to the chat log, leaving out the bot's own and the page's own words. One that
// names Hermes also goes to the board room, where Hermes takes it at once if it asks for something on the board.
// The ids of the chat messages from before the notice, which the bot never keeps (null until it has read the chat with
// the notice in it).
let beforeNotice = null;

function keepChat(found, chrome = null) {
  if (!beforeNotice) {
    const earlier = joinNotice.upTo(found);
    if (!earlier) return;
    beforeNotice = new Set(earlier.map((m) => m.id));
  }
  const seen = new Set(bot.chat.map((m) => m.id));
  for (const { id, sender, own, body } of found) {
    if (!id || seen.has(id) || beforeNotice.has(id)) continue;
    seen.add(id);
    const text = body.split('\n').filter((line) => !chrome?.test(line.trim())).join('\n').trim();
    if (own || !text) continue;
    bot.chat.push({ id, sender, text, at: new Date().toISOString() });
    if (/\b(?:hermes|notetaker)\b/i.test(text)) board?.send({ t: 'command', id: chatId(id), text, source: 'chat', sender });
  }
}

// The whiteboard: the call's board page (served by the Worker) in a window of its own in the bot's browser, which the
// bot presents in the call. Every change reaches that page over its own WebSocket, so the bot shares it once and never
// again for an update.
let boardOpening = null;
function openBoard() {
  if (boardPage && !boardPage.isClosed() && boardOpening) return boardOpening;
  boardOpening = (async () => {
    // Its own context with no emulated viewport, so the page has the window's real size: once shared, Chrome's "sharing
    // this tab" bar makes the page shorter, and the page fits the board again to what the call actually sees.
    boardContext ??= await browser.newContext({ viewport: null });
    boardPage = await boardContext.newPage();
    await boardPage.goto(bot.options.board.page, { waitUntil: 'load' });
    await within(30000, boardPage.evaluate(() => window.hermesBoard.ready()));
    return boardPage;
  })();
  boardOpening.catch(() => { boardOpening = null; });
  return boardOpening;
}

// One share or unshare at a time, and each tells the room how it went.
let sharing = Promise.resolve();
let shareUnasked = 0;
// Every change to the board asks for the share while it is starting; one start is enough.
let presentAsked = false;
// Whether this share try pressed Zoom's Share button, after which the share can still start on its own (zoom.startShare).
let sharePressed = false;
// A share pressed but not seen yet, and one the host refused, followed between tries (zoom-ui.mjs).
const shareFollow = new ShareFollow();

function presentBoard() {
  if (presentAsked || bot.presenting) return sharing;
  presentAsked = true;
  sharing = sharing.then(async () => {
    if (bot.state !== 'in_call') {
      presentAsked = false;
      return;
    }
    sharePressed = false;
    try {
      await openBoard();
      await within(30000, platform.present());
      bot.presenting = true;
      bot.board_error = null;
      shareFollow.settled();
    } catch (error) {
      bot.presenting = false;
      if (error.refused) {
        // Tried again by itself while the board is up (followShare); the mini tells the owner what the host can do.
        bot.board_error = error.message;
        shareFollow.refused();
      } else if (sharePressed) {
        // Zoom was pressed and may still start it: counted when it shows, failed only if it never does (followShare).
        // In a real call (2026-11-22) a share reported failed here showed up after all, and the owner was told wrongly.
        bot.board_error = null;
        shareFollow.unconfirmed();
      } else {
        bot.board_error = error.message;
      }
    } finally {
      presentAsked = false;
    }
    board?.send({ t: 'presenting', on: bot.presenting, error: bot.board_error });
  });
  return sharing;
}

function stopBoard() {
  shareFollow.settled();
  sharing = sharing.then(async () => {
    if (bot.presenting) await within(15000, platform.stopPresenting()).catch(() => {});
    bot.presenting = false;
    board?.send({ t: 'presenting', on: false, error: null });
  });
  return sharing;
}

// The room says which board is on screen: none takes the share down, any other puts it up (once).
function followRoom(room) {
  tile?.board(Boolean(room.current));
  if (bot.state !== 'in_call') return;
  if (room.current && !bot.presenting) {
    shareUnasked = 0;
    presentBoard().catch(() => {});
  } else if (room.current) {
    shareUnasked = 0;
  } else if (!room.current && (bot.presenting || presentAsked) && !shareUnasked) {
    // A share still starting is taken down once it is up.
    stopBoard().catch(() => {});
  }
}

// A board shared early on a request to start one comes down again if no board was made.
async function takeDownUnusedShare() {
  if (shareUnasked && Date.now() - shareUnasked >= UNUSED_SHARE_MS) {
    shareUnasked = 0;
    if (!board?.room.current && bot.presenting) await stopBoard();
  }
  if (presentAsked || Date.now() - shareCheckedAt <= 5000) return;
  shareCheckedAt = Date.now();
  const up = await platform.presenting();
  // Someone (the host) can stop the bot's share; the next change to the board shares it again, as before.
  if (bot.presenting && !up) {
    bot.presenting = false;
    board?.send({ t: 'presenting', on: false, error: null });
  }
  // A share the call started only after the bot stopped waiting for it is counted after all, and taken down when no
  // board is up.
  if (!bot.presenting && up) {
    bot.presenting = true;
    bot.board_error = null;
    shareFollow.settled();
    board?.send({ t: 'presenting', on: true, error: null });
    if (!board?.room.current) await stopBoard();
  }
  if (!up) await followShare();
}
let shareCheckedAt = 0;

// With no share up and none starting: a share pressed but not seen yet is refused (the host's dialog came late),
// failed once it has waited long enough, or still waited for; after a refusal, the share is tried again while a
// board is up and nobody else is sharing (zoom-ui.mjs). With no board up, neither matters any more.
async function followShare() {
  if (!board?.room.current) return shareFollow.settled();
  if (shareFollow.pending !== null && await platform.shareRefused?.()) {
    shareFollow.refused();
    bot.board_error = HOST_ONLY;
    board?.send({ t: 'presenting', on: false, error: bot.board_error });
  } else if (shareFollow.failed()) {
    bot.board_error = 'Zoom did not start sharing';
    board?.send({ t: 'presenting', on: false, error: bot.board_error });
  }
  if (shareFollow.retry() && !await platform.othersSharing?.()) {
    console.log('share tried again');
    presentBoard().catch(() => {});
  }
}

// Each board's last picture and file. As the call ends, every board changed since it was last drawn is drawn once more
// before the browser closes, so a change made in the call's last seconds (from the board link) can still be kept.
const drawn = new Map();
const drawnAtEnd = [];

// A board is pictured on a page of its own, 1280 wide at twice the pixels, with every block as tall as it needs and
// nothing of the call's: no status bar, tabs or link.
let printContext = null;
let printPage = null;
async function picture(board) {
  if (!printPage || printPage.isClosed()) {
    printContext ??= await browser.newContext({ viewport: { width: 1280, height: 720 }, deviceScaleFactor: 2 });
    printPage = await printContext.newPage();
    // The screen's own address with ?print=1 added before its # (its key, which this page does not use).
    const address = new URL(bot.options.board.page);
    address.searchParams.set('print', '1');
    await printPage.goto(address.href, { waitUntil: 'load' });
    await within(30000, printPage.evaluate(() => window.hermesBoard.ready()));
  }
  await printPage.evaluate((value) => window.hermesBoard.print(value), board);
  return (await printPage.screenshot({ fullPage: true, type: 'png' })).toString('base64');
}

async function drawBoard(n) {
  const shown = await within(30000, boardPage.evaluate((value) => window.hermesBoard.export(value), n));
  if (shown.print) {
    delete shown.print;
    shown.png = await within(30000, picture(shown.board));
  }
  return shown;
}

async function exportBoard(query) {
  const n = Number(new URLSearchParams(query).get('n'));
  if (!boardPage || boardPage.isClosed()) {
    if (drawn.has(n)) return drawn.get(n);
    throw new Error('the board is not open');
  }
  const shown = await drawBoard(n);
  drawn.set(n, shown);
  return shown;
}

async function drawChanged() {
  if (!boardPage || boardPage.isClosed()) return;
  const boards = await boardPage.evaluate(() => window.hermesBoard.boards());
  for (const [i, board] of boards.entries()) {
    if (JSON.stringify(drawn.get(i + 1)?.board) === JSON.stringify(board)) continue;
    drawn.set(i + 1, await drawBoard(i + 1));
    drawnAtEnd.push(i + 1);
  }
}

const routes = {
  'POST /start': (body) => { start(body).catch((e) => finish('failed', e.reason || `join: ${e.message}`)); return { ok: true }; },
  'GET /status': () => ({ ...bot, options: undefined, audio_bytes: fs.existsSync(AUDIO) ? fs.statSync(AUDIO).size : 0,
    voice: voice?.status() || { state: 'off', error: null, streamed_seconds: 0 }, notice: joinNotice?.status() || null,
    // Commands sent to the board room that it has not said it has yet (container/board-link.mjs).
    board_unconfirmed: board?.pending() ?? 0 }),
  'POST /chat': async (body) => { await platform.say(body.message); return { ok: true }; },
  'POST /leave': async () => { await leave(); return { ok: true }; },
  'GET /board/export': (body, query) => exportBoard(query),
  'GET /board/final': () => ({ boards: drawnAtEnd.map((n) => drawn.get(n)) }),
};

// Local testing only: a second test participant plays speech into its microphone, and page probes.
if (process.env.TEST_TOOLS) {
  routes['POST /debug/eval'] = async (body) => ({ value: await page.evaluate(body.js) });
  routes['POST /speak'] = (body) => new Promise((done, fail) => {
    const play = spawn('paplay', ['-d', 'mic', body.file], { stdio: 'inherit' });
    play.once('exit', (code) => (code ? fail(new Error(`paplay exited ${code}`)) : done({ ok: true })));
  });
}

// Cloudflare stops a container with SIGTERM (a host restart, or a deploy reaching an older call) and kills it
// 15 minutes later; its disk goes with it. So end the call now and keep answering for a while, letting the
// mini fetch what was recorded and file it.
process.once('SIGTERM', async () => {
  console.log('SIGTERM');
  if (bot.state === 'idle') process.exit(0);
  if (['joining', 'signing_in', 'waiting_room', 'in_call'].includes(bot.state)) {
    await Promise.resolve(platform?.hangUp()).catch(() => {});
    await finish('failed', 'service_restart');
  }
  setTimeout(() => process.exit(0), 13 * 60000);
});

http.createServer(async (req, res) => {
  const chunks = [];
  for await (const chunk of req) chunks.push(chunk);
  const key = `${req.method} ${req.url.split('?')[0]}`;
  try {
    if (key === 'GET /audio') {
      if (!fs.existsSync(AUDIO)) {
        res.writeHead(404);
        return res.end();
      }
      // From byte `from` on, as far as it is written now. `x-audio-from` says where the answer starts, so the mini
      // appends only what follows the audio it already has.
      const size = fs.statSync(AUDIO).size;
      const from = Math.min(size, Math.max(0, Math.floor(Number(new URL(req.url, 'http://bot').searchParams.get('from'))) || 0));
      res.writeHead(200, { 'content-type': 'audio/ogg', 'x-audio-from': String(from) });
      if (from >= size) return res.end();
      return fs.createReadStream(AUDIO, { start: from }).on('error', () => res.destroy()).pipe(res);
    }
    if (key === 'GET /debug/shot') {
      const shot = await page.screenshot();
      res.writeHead(200, { 'content-type': 'image/png' });
      return res.end(shot);
    }
    const route = routes[key];
    if (!route) {
      res.writeHead(404);
      return res.end();
    }
    const body = chunks.length ? JSON.parse(Buffer.concat(chunks)) : {};
    const value = await route(body, req.url.split('?')[1] || '');
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end(JSON.stringify(value));
  } catch (error) {
    if (!res.headersSent) res.writeHead(500, { 'content-type': 'application/json' });
    res.end(JSON.stringify({ error: error.message }));
  }
}).listen(8080, () => console.log('listening 8080'));

// Node exits on an unhandled rejection, which would drop the call and its recording. Log it instead.
process.on('unhandledRejection', (error) => console.log('unhandled', error?.message || error));
