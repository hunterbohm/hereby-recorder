import { Container, getContainer } from '@cloudflare/containers';

// One Chrome per meeting. Each bot is its own container, named by the id this Worker hands out.
export class MeetBot extends Container {
  defaultPort = 8080;
  // Activity is any request; the mini polls status every minute while a call runs.
  sleepAfter = '20m';

  constructor(ctx, env) {
    super(ctx, env);
    this.envVars = { GOOGLE_EMAIL: env.GOOGLE_EMAIL, GOOGLE_PASSWORD: env.GOOGLE_PASSWORD };
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

// Requests the Worker passes to a bot's container, by method and path after /bots/<id>.
const PASS = new Set(['GET /status', 'POST /chat', 'POST /leave', 'GET /audio', 'GET /debug/shot']);

function authorized(request, env) {
  const given = request.headers.get('authorization') || '';
  const want = `Bearer ${env.API_TOKEN}`;
  if (!env.API_TOKEN || given.length !== want.length) return false;
  let diff = 0;
  for (let i = 0; i < want.length; i++) diff |= given.charCodeAt(i) ^ want.charCodeAt(i);
  return diff === 0;
}

export default {
  async fetch(request, env) {
    if (!authorized(request, env)) return json({ error: 'unauthorized' }, 401);
    const url = new URL(request.url);
    const parts = url.pathname.split('/').filter(Boolean);
    if (parts[0] !== 'bots') return json({ error: 'not found' }, 404);

    if (parts.length === 1 && request.method === 'POST') {
      const body = await request.json().catch(() => null);
      if (!body || !/^https:\/\/meet\.google\.com\/[a-z]{3}-[a-z]{4}-[a-z]{3}/.test(body.meeting_url || '')) {
        return json({ error: 'meeting_url must be a Google Meet link' }, 400);
      }
      const id = crypto.randomUUID();
      const bot = getContainer(env.MEET_BOT, id);
      const started = await bot.fetch(new Request('http://bot/start', {
        method: 'POST',
        body: JSON.stringify({ meeting_url: body.meeting_url, bot_name: body.bot_name || "Notetaker",
          chat: body.chat === true }),
      }));
      if (!started.ok) return json({ error: `bot did not start: ${started.status}` }, 502);
      return json({ id }, 201);
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
    return bot.fetch(new Request(`http://bot${rest}`, { method: request.method, body: request.body }));
  },
};
