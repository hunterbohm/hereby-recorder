import http from 'node:http';
import fs from 'node:fs';
import { spawn } from 'node:child_process';
import { chromium } from 'playwright-core';

const AUDIO = '/tmp/call.ogg';
const WAITING_ROOM_MS = Number(process.env.WAITING_ROOM_MS || 600000);
// The bot leaves a call it is alone in: soon after the others have gone, later when nobody has come yet.
const ALONE_MS = Number(process.env.ALONE_MS || 120000);
const NOBODY_MS = Number(process.env.NOBODY_MS || 900000);
const MAX_CALL_MS = Number(process.env.MAX_CALL_MS || 4 * 3600000);
const STUCK_MS = Number(process.env.STUCK_MS || 180000);

const bot = { state: 'idle', error: null, changes: [], chat: [], people: null, options: null };
let browser, page, recorder, ticker, waitingSince, aloneSince, inCallSince, othersSeen = false;

function setState(state, error = null) {
  if (bot.state === state) return;
  bot.state = state;
  bot.error = error;
  bot.changes.push({ state, error, at: new Date().toISOString() });
  console.log('state', state, error || '');
}

const visible = (locator) => locator.isVisible().catch(() => false);

async function start(options) {
  bot.options = options;
  setState('joining');
  browser = await chromium.launch({
    executablePath: '/usr/bin/google-chrome',
    headless: false,
    ignoreDefaultArgs: ['--mute-audio', '--enable-automation'],
    args: ['--use-fake-ui-for-media-stream', '--disable-blink-features=AutomationControlled', '--no-first-run',
      '--no-default-browser-check', '--disable-dev-shm-usage', '--autoplay-policy=no-user-gesture-required',
      '--window-size=1280,720', '--window-position=0,0'],
  });
  const context = await browser.newContext({ viewport: { width: 1280, height: 720 }, permissions: ['microphone', 'camera'] });
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
  await page.goto(options.meeting_url, { waitUntil: 'domcontentloaded' });
  const name = page.getByRole('textbox', { name: /your name/i });
  await name.waitFor({ timeout: 30000 }).catch(() => {});
  if (await visible(name)) await name.fill(options.bot_name);
  const mute = options.speaker ? [/turn off camera/i] : [/turn off microphone/i, /turn off camera/i];
  for (const label of mute) {
    const button = page.getByRole('button', { name: label }).first();
    if (await visible(button)) await button.click().catch(() => {});
  }
  const gotIt = page.getByRole('button', { name: /^got it$/i }).first();
  if (await visible(gotIt)) await gotIt.click().catch(() => {});
  await clickJoin();
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

// Signs the bot's own Google account in, so Meet lets it in as a named user (Meet turns away anonymous guests
// from this browser). A new Workspace user first gets a welcome page to accept.
async function signIn() {
  const email = process.env.GOOGLE_EMAIL;
  const password = process.env.GOOGLE_PASSWORD;
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

async function clickJoin() {
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
}

async function tick() {
  if (!page || page.isClosed()) return;
  // In the call first: the page text then includes the chat, where anyone can type the words below.
  if (await visible(page.getByRole('button', { name: /leave call/i }).first())) {
    if (bot.state !== 'in_call') {
      setState('in_call');
      inCallSince = Date.now();
      record();
    }
    if (bot.options.chat) await readChat();
    return checkAlone();
  }
  const text = await page.evaluate(() => document.body.innerText).catch(() => '');
  if (/denied your request|can.t join this call|been removed from the meeting|removed you from the meeting/i.test(text)) {
    return finish('failed', 'denied');
  }
  if (await visible(page.getByRole('button', { name: /^(rejoin|return to home screen)$/i }).first())) {
    return finish('ended');
  }
  if (bot.state === 'joining' && /asking to be let in|wait until a meeting host|when someone lets you in/i.test(text)) {
    setState('waiting_room');
  }
  if (Date.now() - waitingSince > WAITING_ROOM_MS) await finish('failed', 'waiting_room_timeout');
}

// The number on Meet's People button counts everyone in the call, the bot included.
async function peopleCount() {
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
}

async function checkAlone() {
  const now = Date.now();
  if (now - inCallSince > MAX_CALL_MS) return leave('max_duration');
  const count = await peopleCount();
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

function record() {
  recorder = spawn('ffmpeg', ['-nostdin', '-hide_banner', '-loglevel', 'error', '-y', '-f', 'pulse', '-i', 'meet.monitor',
    '-ac', '1', '-ar', '16000', '-c:a', 'libopus', '-b:a', '24k', '-flush_packets', '1', AUDIO], { stdio: ['ignore', 'inherit', 'inherit'] });
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
  if (recorder && recorder.exitCode === null && recorder.signalCode === null) {
    const exited = new Promise((done) => recorder.once('exit', done));
    recorder.kill('SIGINT');
    await within(10000, exited).catch(() => recorder.kill('SIGKILL'));
  }
  // A stuck page can hang any call into it, so these get a time limit.
  bot.last_text = await within(5000, page?.evaluate(() => document.body.innerText)).catch(() => null);
  setState(state, error);
  if (!process.env.KEEP_BROWSER) await within(10000, browser?.close()).catch(() => {});
}

async function openChat() {
  const box = page.getByRole('textbox', { name: /send a message/i });
  if (await visible(box)) return box;
  await page.getByRole('button', { name: /chat with everyone/i }).first().click();
  await box.waitFor({ timeout: 10000 });
  return box;
}

// Meet adds chat messages to the page only while the chat panel is open. Each message is a div with a
// data-message-id; two levels up, its group starts with the sender's name, or with the time for the bot's own.
async function readChat() {
  await openChat();
  const found = await page.evaluate(() => [...document.querySelectorAll('div[data-message-id]')].map((el) => {
    const group = el.parentElement?.parentElement;
    const first = (group?.innerText || '').split('\n')[0].trim();
    const body = (el.firstElementChild || el).innerText || '';
    return { id: el.getAttribute('data-message-id'), first, body };
  }));
  const seen = new Set(bot.chat.map((m) => m.id));
  for (const { id, first, body } of found) {
    if (seen.has(id)) continue;
    seen.add(id);
    const own = /^\d{1,2}:\d{2}/.test(first);
    const text = body.split('\n').filter((line) => !CHAT_CHROME.test(line.trim())).join('\n').trim();
    if (!own && text) bot.chat.push({ id, sender: first, text, at: new Date().toISOString() });
  }
}

const CHAT_CHROME = /^(hover over a message to pin it|pin message|unpin message|keep|keep_off)$/i;

async function say(message) {
  const box = await openChat();
  await box.fill(message);
  await box.press('Enter');
}

async function leave(reason = null) {
  await page?.getByRole('button', { name: /leave call/i }).first().click().catch(() => {});
  await finish('ended', reason);
}

const routes = {
  'POST /start': (body) => { start(body).catch((e) => finish('failed', `join: ${e.message}`)); return { ok: true }; },
  'GET /status': () => ({ ...bot, options: undefined, audio_bytes: fs.existsSync(AUDIO) ? fs.statSync(AUDIO).size : 0 }),
  'POST /chat': async (body) => { await say(body.message); return { ok: true }; },
  'POST /leave': async () => { await leave(); return { ok: true }; },
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
    await page?.getByRole('button', { name: /leave call/i }).first().click().catch(() => {});
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
      res.writeHead(200, { 'content-type': 'audio/ogg' });
      return fs.createReadStream(AUDIO).on('error', () => res.destroy()).pipe(res);
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
    const value = await route(body);
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end(JSON.stringify(value));
  } catch (error) {
    if (!res.headersSent) res.writeHead(500, { 'content-type': 'application/json' });
    res.end(JSON.stringify({ error: error.message }));
  }
}).listen(8080, () => console.log('listening 8080'));

// Node exits on an unhandled rejection, which would drop the call and its recording. Log it instead.
process.on('unhandledRejection', (error) => console.log('unhandled', error?.message || error));
